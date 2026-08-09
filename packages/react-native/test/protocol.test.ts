// Tests for the parts that can be wrong without a device — which, measured
// against the web widget's own history, is where the expensive bugs lived.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  TRACE_HEAD_EVENTS,
  TRACE_MAX_EVENTS,
  TRACE_TAIL_EVENTS,
  applyRetention,
  clampStack,
  kindForFilename,
  normalizeElement,
  type TraceEvent,
} from '../src/protocol.ts';
import { TraceRecorder, stripQuery } from '../src/recorder.ts';
import { CrashReporter, crashSignature, type CrashStore } from '../src/crash.ts';
import { AlgoWidgetClient } from '../src/client.ts';
import { elementFromProps, looksMinified } from '../src/element.ts';

test('retention keeps the head AND the tail, and says what it dropped', () => {
  const events: TraceEvent[] = Array.from({ length: 700 }, (_, i) => ({
    type: 'click',
    t: i,
  }));
  const { events: kept, dropped } = applyRetention(events);
  assert.equal(dropped, 700 - TRACE_HEAD_EVENTS - TRACE_TAIL_EVENTS);
  assert.equal(kept.length, TRACE_HEAD_EVENTS + TRACE_TAIL_EVENTS + 1);
  // The setup a reproduction needs survives...
  assert.equal(kept[0]?.t, 0);
  // ...and so does the failure at the end, which a ring buffer would have kept
  // while throwing the setup away.
  assert.equal(kept[kept.length - 1]?.t, 699);
  assert.equal(kept[TRACE_HEAD_EVENTS]?.type, 'mark');
});

test('retention leaves an under-cap trace alone', () => {
  const events: TraceEvent[] = Array.from({ length: TRACE_MAX_EVENTS }, (_, i) => ({
    type: 'click',
    t: i,
  }));
  const { events: kept, dropped } = applyRetention(events);
  assert.equal(dropped, 0);
  assert.equal(kept.length, TRACE_MAX_EVENTS);
});

test('a request path never carries a query string', () => {
  assert.equal(stripQuery('/orders?token=secret&id=4'), '/orders');
  assert.equal(stripQuery('/orders#frag'), '/orders');
  // Cross-origin contributes its HOST only — another service's URL structure is
  // not this app's business.
  assert.equal(stripQuery('https://pay.example.com/charge?cvv=123'), 'pay.example.com');
});

test('a stack loses its query strings and its tail', () => {
  const stack = Array.from({ length: 50 }, (_, i) => `#${i} at foo (app.js?token=abc:1:2)`).join('\n');
  const out = clampStack(stack)!;
  assert.equal(out.split('\n').length, 30);
  assert.ok(!out.includes('token=abc'));
});

test('the recorder never exposes a way to record a value', () => {
  const rec = new TraceRecorder({ platform: 'android', framework: 'react_native', maxSeconds: 60 });
  rec.start('/orders');
  rec.input({ testid: 'order_note' });
  const doc = rec.build();
  const inputEvent = doc.events.find((e) => e.type === 'input');
  assert.ok(inputEvent);
  // The whole privacy posture in one assertion: the event names the field and
  // carries nothing else.
  assert.deepEqual(Object.keys(inputEvent!).sort(), ['el', 't', 'type']);
  assert.ok(!JSON.stringify(doc).includes('value'));
});

test('the recorder stops itself at the cap rather than letting a trace be refused', () => {
  let now = 1_000;
  let autoStopped = false;
  const rec = new TraceRecorder({
    platform: 'android',
    framework: 'react_native',
    maxSeconds: 10,
    now: () => now,
    onAutoStop: () => {
      autoStopped = true;
    },
  });
  rec.start('/orders');
  rec.tap({ testid: 'a' });
  now += 11_000;
  rec.tap({ testid: 'b' });
  assert.equal(autoStopped, true);
  assert.equal(rec.isRecording, false);
  // The event past the cap is not recorded at all — a trace whose timeline
  // exceeds the format ceiling would be refused wholesale at staging.
  assert.equal(rec.build().events.filter((e) => e.type === 'click').length, 1);
});

test('a paused recording does not accumulate a gap the video does not have', () => {
  let now = 0;
  const rec = new TraceRecorder({
    platform: 'ios',
    framework: 'flutter',
    maxSeconds: 600,
    now: () => now,
  });
  rec.start('/a');
  now = 1_000;
  rec.tap({ testid: 'before' });
  rec.pause();
  now = 60_000; // a minute goes by, paused
  rec.resume();
  rec.tap({ testid: 'after' });
  const clicks = rec.build().events.filter((e) => e.type === 'click');
  // Media time, not wall clock: the second tap sits ~1s after the first, which
  // is where it is on the recording the narration shares.
  assert.equal(clicks[1]!.t, 1_000);
});

test('nav records where it came from, and who caused it', () => {
  const rec = new TraceRecorder({ platform: 'android', framework: 'flutter', maxSeconds: 60 });
  rec.start('/orders');
  rec.navigate('/orders/42', 'user');
  rec.navigate('/login', 'app');
  const navs = rec.build().events.filter((e) => e.type === 'nav');
  assert.deepEqual(
    navs.map((n) => [n.from, n.to, n.cause]),
    [
      ['/orders', '/orders/42', 'user'],
      ['/orders/42', '/login', 'app'],
    ],
  );
});

test('only FAILED requests are recorded', () => {
  const rec = new TraceRecorder({ platform: 'android', framework: 'flutter', maxSeconds: 60 });
  rec.start('/a');
  rec.request('GET', '/api/ok', 200);
  rec.request('POST', '/api/bad?secret=1', 500, 12);
  const reqs = rec.build().events.filter((e) => e.type === 'request');
  assert.equal(reqs.length, 1);
  assert.equal(reqs[0]!.path, '/api/bad');
});

test('cancel guarantees nothing recorded survives', () => {
  const rec = new TraceRecorder({ platform: 'android', framework: 'react_native', maxSeconds: 60 });
  rec.start('/a');
  rec.tap({ testid: 'x' });
  rec.cancel();
  assert.equal(rec.build().events.length, 0);
});

test('crash signature separates the same error on two screens', () => {
  const a = crashSignature('error', 'TypeError', 'Cannot read x of undefined', '/orders');
  const b = crashSignature('error', 'TypeError', 'Cannot read x of undefined', '/devices');
  assert.notEqual(a, b);
});

test('crash signature groups one bug with its own repeats', () => {
  const a = crashSignature('error', 'StateError', 'order 4821 not found', '/orders');
  const b = crashSignature('error', 'StateError', 'order 9137 not found', '/orders');
  assert.equal(a, b);
});

function memoryStore(): CrashStore & { items: unknown[] } {
  let items: unknown[] = [];
  return {
    get items() {
      return items;
    },
    async save(r) {
      items = r;
    },
    async load() {
      return items as never;
    },
    async clear() {
      items = [];
    },
  };
}

test('one burst per launch — forty throws in a second are one crash', async () => {
  const store = memoryStore();
  const rep = new CrashReporter({ store, currentRoute: () => '/orders' });
  const results = [];
  for (let i = 0; i < 40; i++) {
    results.push(await rep.capture('error', { name: 'TypeError', message: 'boom' }));
  }
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(store.items.length, 1);
});

test('the route is read AT CRASH TIME, not at launch', async () => {
  const store = memoryStore();
  let route = '/orders';
  // A per-launch budget would make this impossible to observe; the point of
  // reading the route per crash is that an SPA-style app navigates for the
  // whole life of its process.
  const rep = new CrashReporter({ store, currentRoute: () => route });
  await rep.capture('error', { name: 'E', message: 'one' });
  route = '/devices';
  const saved = (await store.load()) as { page: { route: string } }[];
  assert.equal(saved[0]!.page.route, '/orders');
});

test('flush clears on success and retains on failure', async () => {
  const store = memoryStore();
  const rep = new CrashReporter({ store, currentRoute: () => '/a' });
  await rep.capture('error', { name: 'E', message: 'x' });

  let sent = await rep.flush(async () => false);
  assert.equal(sent, 0);
  assert.equal((await store.load()).length, 1, 'a failed send is retried next launch');

  sent = await rep.flush(async () => true);
  assert.equal(sent, 1);
  assert.equal((await store.load()).length, 0);
});

test('the session exchange treats 401+challenge as step one, not an error', async () => {
  const calls: unknown[] = [];
  const client = new AlgoWidgetClient({
    host: 'https://os.example.com',
    portalKey: 'pk_abc',
    platform: 'android',
    appId: 'com.acme.orders',
    attest: async (challenge) => `token-for-${challenge}`,
    fetch: (async (_url: string, init: RequestInit) => {
      const body = JSON.parse(String(init.body));
      calls.push(body);
      if (!body.client.attestation) {
        return new Response(JSON.stringify({ challenge: 'nonce-1', exp: Date.now() + 120_000 }), {
          status: 401,
        });
      }
      return new Response(
        JSON.stringify({ token: 'tk', exp: Date.now() + 1_800_000, portal: { title: 'x' } }),
        { status: 200 },
      );
    }) as unknown as typeof fetch,
  });

  const ticket = await client.session();
  assert.ok(ticket, 'a challenge must not be surfaced as a failure');
  assert.equal(ticket!.token, 'tk');
  assert.equal(calls.length, 2);
  // The attestation was minted against the challenge the server issued — the
  // binding that stops a captured token being replayed forever.
  assert.equal((calls[1] as never as { client: { attestation: string } }).client.attestation, 'token-for-nonce-1');
});

test('a refusal is not retried, and never becomes a ticket', async () => {
  let hits = 0;
  const client = new AlgoWidgetClient({
    host: 'https://os.example.com',
    portalKey: 'pk_abc',
    platform: 'ios',
    appId: 'com.acme.orders',
    attest: async () => 'irrelevant',
    fetch: (async () => {
      hits += 1;
      return new Response(JSON.stringify({ error: 'unknown portal' }), { status: 404 });
    }) as unknown as typeof fetch,
  });
  assert.equal(await client.session(), null);
  assert.equal(hits, 1, 'a 404 is configuration; retrying it is noise');
});

test('a session with no attestation provider cannot invent one', async () => {
  const client = new AlgoWidgetClient({
    host: 'https://os.example.com',
    portalKey: 'pk_abc',
    platform: 'android',
    appId: 'com.acme.orders',
    fetch: (async () =>
      new Response(JSON.stringify({ challenge: 'n', exp: Date.now() + 1000 }), {
        status: 401,
      })) as unknown as typeof fetch,
  });
  assert.equal(await client.session(), null);
});

test('concurrent callers share one session exchange', async () => {
  let mints = 0;
  const client = new AlgoWidgetClient({
    host: 'https://os.example.com',
    portalKey: 'pk_abc',
    platform: 'android',
    appId: 'com.acme.orders',
    fetch: (async () => {
      mints += 1;
      return new Response(
        JSON.stringify({ token: 'tk', exp: Date.now() + 1_800_000, portal: {} }),
        { status: 200 },
      );
    }) as unknown as typeof fetch,
  });
  await Promise.all([client.session(), client.session(), client.session()]);
  assert.equal(mints, 1, 'a crash flush and a reporter must not race two exchanges');
});

test('staging refuses an unknown extension rather than uploading it', async () => {
  const client = new AlgoWidgetClient({
    host: 'https://os.example.com',
    portalKey: 'pk_abc',
    platform: 'android',
    appId: 'com.acme.orders',
    fetch: (async () =>
      new Response(JSON.stringify({ token: 'tk', exp: Date.now() + 1e6, portal: {} }), {
        status: 200,
      })) as unknown as typeof fetch,
  });
  assert.equal(await client.stage(new Uint8Array(10), 'thing.exe', 'application/octet-stream'), null);
});

test('kindForFilename knows the mobile containers', () => {
  assert.equal(kindForFilename('voice.m4a'), 'audio');
  assert.equal(kindForFilename('voice.aac'), 'audio');
  assert.equal(kindForFilename('screen.3gp'), 'video');
  assert.equal(kindForFilename('screen.mov'), 'video');
  assert.equal(kindForFilename('trace.json'), 'trace');
  assert.equal(kindForFilename('thing.exe'), undefined);
});

test('the element ladder prefers testID, and drops minified component names', () => {
  const el = elementFromProps({ testID: 'submit_order', accessibilityLabel: 'Save' }, 'Qk');
  assert.equal(el?.testid, 'submit_order');
  assert.equal(el?.component, undefined);
  assert.equal(looksMinified('QuotationFilters'), false);
  assert.equal(looksMinified('aB'), true);
});

test('visible text is only collected when no stronger rung named the element', () => {
  const withId = elementFromProps({ testID: 'x', children: 'Save order' });
  assert.equal(withId?.text, undefined, 'testID already answers "which control"');
  const without = elementFromProps({ children: 'Save order' });
  assert.equal(without?.text, 'Save order');
});

test('normalizeElement drops an all-empty descriptor', () => {
  assert.equal(normalizeElement({}), undefined);
  assert.equal(normalizeElement(undefined), undefined);
});
