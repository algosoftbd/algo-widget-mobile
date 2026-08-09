// The report panel's message protocol (docs/WIDGET.md, the loader/frame split).
//
// The panel a reporter types into is NOT reimplemented per platform. It is the
// SAME page the web widget already serves — `/widget/frame` on the OS host —
// loaded in a WebView, and this file is the half of that conversation the SDK
// owns. The web loader speaks it over `postMessage`; a mobile SDK speaks the
// identical protocol over the WebView's JS bridge.
//
// That is the whole reason the panel exists at all rather than being rebuilt in
// SwiftUI and Compose and Flutter and JSX: the form, the draft store, the
// annotation UI, the attachment caps, the tier picker and the countdown are one
// implementation, maintained once, and every fix to them reaches four clients.
//
// Kept free of React and of any WebView package so the parsing and the payload
// construction — the parts that can be wrong — are testable on a laptop.
import type { PortalConfig, StagedFile } from './protocol.ts';

/** Messages the FRAME sends to us. Names match the web loader's exactly; the
 *  frame cannot tell which client it is talking to and must not have to. */
export type FrameMessage =
  | { type: 'algo-widget:ready' }
  | { type: 'algo-widget:size'; height: number }
  | { type: 'algo-widget:close' }
  | { type: 'algo-widget:fullscreen'; on: boolean }
  | { type: 'algo-widget:snip-request' }
  | { type: 'algo-widget:record-start'; mode: RecordMode }
  | { type: 'algo-widget:record-stop'; cancel?: boolean }
  | { type: 'algo-widget:submitted'; issueId?: string };

export type RecordMode = 'steps' | 'voice' | 'screen';

/** The init payload — everything the frame needs to render itself and submit.
 *
 *  `token` is the widget ticket. It goes to a page on the OS ORIGIN, which is
 *  the same trust boundary the web widget uses: the frame is ours, the host app
 *  around it is the customer's, and the ticket never enters the customer's own
 *  JavaScript. */
export interface FrameInit {
  type: 'algo-widget:init';
  token: string;
  exp: number;
  /** The screen the reporter was on. Shown to them, and stored on the issue. */
  page: string;
  portal: PortalConfig;
}

/**
 * Prefilled, editable, and never trusted — reporter-supplied identity is display
 * data server-side no matter who typed it.
 *
 * Its OWN message, following init, because that is what the frame listens for.
 * Carried inside init it was silently ignored, and the name and email the host
 * app already knew were never prefilled.
 */
export function identityMessage(identity: { name?: string; email?: string }): object {
  return {
    type: 'algo-widget:identity',
    ...(identity.name ? { name: identity.name } : {}),
    ...(identity.email ? { email: identity.email } : {}),
  };
}

/**
 * Which recording tiers this CLIENT can actually offer. A device with no
 * microphone permission, or an iOS build without a usage description, must not
 * be shown a tier that will fail the moment it is pressed.
 *
 * Also its own message, for the same reason — and the frame ANDs it with the
 * portal's own opt-in, so capability here is not permission. Absent means every
 * tier is off: the frame offers a recorder only for a tier it was explicitly
 * told about.
 */
export function recordCapabilitiesMessage(
  modes: readonly RecordMode[],
  opts: { snip: boolean },
): object {
  return {
    type: 'algo-widget:record-capabilities',
    steps: modes.includes('steps'),
    voice: modes.includes('voice'),
    screen: modes.includes('screen'),
    // Not a recording tier, but the same question — what can THIS host do — and
    // the frame reads it off this message. Its default there is the OPPOSITE of
    // the tiers': absent means SUPPORTED, because every web loader can snip and
    // none of them sends the field, so a client with no native screenshot must
    // say `false` OUT LOUD. Without it the panel offers "Snip this page", the
    // request reaches a host that cannot answer it, and the reporter gets
    // "Screen capture failed" — a button whose only outcome is an error.
    snip: opts.snip,
  };
}

/**
 * The frame's URL.
 *
 * The accent rides in the query so the panel's FIRST paint is already the
 * portal's colour rather than brand red — the same trick the web preview uses.
 * Everything else arrives by message, because it changes after load and a URL
 * change would reload the page and lose a half-typed report.
 */
export function frameUrl(host: string, portal: Pick<PortalConfig, 'accentColor'>): string {
  const base = `${host.replace(/\/+$/, '')}/widget/frame`;
  return portal.accentColor
    ? `${base}?accent=${encodeURIComponent(portal.accentColor)}`
    : base;
}

/**
 * Parse a message from the frame, or null.
 *
 * Returns null for ANYTHING unrecognised rather than throwing. The frame and
 * the SDK version independently: a panel newer than the app will send messages
 * this build has never heard of, and the correct response to one is to ignore
 * it, not to tear down the reporter's session.
 */
export function parseFrameMessage(raw: unknown): FrameMessage | null {
  let data: unknown = raw;
  if (typeof raw === 'string') {
    try {
      data = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!data || typeof data !== 'object') return null;
  const type = (data as { type?: unknown }).type;
  if (typeof type !== 'string' || !type.startsWith('algo-widget:')) return null;

  const d = data as Record<string, unknown>;
  switch (type) {
    case 'algo-widget:ready':
    case 'algo-widget:close':
    case 'algo-widget:snip-request':
      return { type } as FrameMessage;
    case 'algo-widget:size':
      return typeof d.height === 'number'
        ? { type, height: Math.max(0, Math.round(d.height)) }
        : null;
    case 'algo-widget:fullscreen':
      return { type, on: d.on === true };
    case 'algo-widget:record-start':
      return isRecordMode(d.mode) ? { type, mode: d.mode } : null;
    case 'algo-widget:record-stop':
      return { type, cancel: d.cancel === true };
    case 'algo-widget:submitted':
      return typeof d.issueId === 'string'
        ? { type, issueId: d.issueId }
        : { type };
    default:
      // A message from a newer panel. Ignoring it is the whole point.
      return null;
  }
}

function isRecordMode(v: unknown): v is RecordMode {
  return v === 'steps' || v === 'voice' || v === 'screen';
}

/**
 * The bridge the frame needs in order to be heard at all.
 *
 * The frame posts with `window.parent.postMessage(...)` — correct, because on
 * the web it lives in an iframe and is talking to the loader. In a WebView
 * there is no parent: `window.parent === window`, so that call lands on
 * `window.postMessage`, which goes nowhere a native host can see. React
 * Native's `onMessage` only fires for `window.ReactNativeWebView.postMessage`,
 * and Flutter's channels only fire for their own named object. Neither is what
 * the frame calls, so without this shim NOT ONE message arrives — the panel
 * loads, waits for an `init` that is never sent, and its Close button does
 * nothing either.
 *
 * IT MUST RUN BEFORE THE PAGE'S OWN SCRIPTS. The frame announces `ready` as
 * soon as React mounts, which can precede the load event — a shim installed on
 * "page finished" misses it and the panel hangs forever.
 *
 * @param channel a JS expression that takes one string, e.g.
 *   `window.ReactNativeWebView.postMessage` or `AlgoWidgetHost.postMessage`.
 */
export function frameShim(channel: string): string {
  return `(function(){
  if (window.__algoWidgetShim) return; window.__algoWidgetShim = true;
  var native = function (s) { try { ${channel}(s); } catch (e) {} };
  var original = window.postMessage.bind(window);
  // Kept reachable so the HOST can deliver into the page without its own
  // message being echoed straight back out through the patch.
  window.__algoPost = original;
  window.postMessage = function (data, origin, transfer) {
    try { native(typeof data === 'string' ? data : JSON.stringify(data)); } catch (e) {}
    // Still deliver in-page: the frame listens to its own messages for some
    // flows, and swallowing them would break it in ways this shim cannot see.
    try { return original(data, origin, transfer); } catch (e) { return undefined; }
  };
})();`;
}

/**
 * JS to evaluate in the WebView to deliver one message.
 *
 * The payload is a JSON string LITERAL in the generated source, so a reporter's
 * own text — a name with an apostrophe, a description with a newline — stays
 * data rather than breaking out of the expression. But it is parsed back into an
 * OBJECT before it is posted, and that is the load-bearing half: the frame reads
 * `event.data.type` directly, because on the web it is handed a structured
 * clone. Posting the string meant `data.type` was `undefined`, so the frame
 * dropped every message this SDK sent — the panel loaded, waited for an `init`
 * it had already been given, and sat on "Loading…" forever.
 *
 * The frame now parses a string too, so a build shipped before this fix still
 * works. That is the tolerance; this is the contract. Do not go back to sending
 * a string because "it works either way" — the web loader has always posted
 * objects, and one wire shape is what keeps the frame from having to know which
 * client it is talking to.
 */
export function postToFrame(message: object): string {
  const payload = JSON.stringify(JSON.stringify(message));
  // Prefer the un-patched function the shim stashed: going through the patched
  // one would forward our own init straight back to us. Harmless (it parses to
  // nothing the SDK handles) but pointless, and confusing in a log.
  return `(window.__algoPost || window.postMessage)(JSON.parse(${payload}), '*');true;`;
}

/**
 * Tell the frame a staged attachment arrived — a screenshot, a recording,
 * anything the NATIVE side produced and uploaded itself.
 *
 * NOT YET UNDERSTOOD BY THE FRAME. Its attachments are local `File`s it stages
 * itself, and it has no case for one that is already on the server, so this
 * message is currently dropped. It is unreachable in practice — a screenshot
 * needs a `NativeCapture`, and recording needs one plus a portal that enabled
 * it, and no native capture layer ships yet — but a caller that DOES wire one up
 * will see the capture succeed and no card appear. The frame half is the work
 * that has to land alongside the native one; the message name and shape are
 * settled here so both sides are written against the same thing.
 */
export function attachmentMessage(file: StagedFile, kind: string): object {
  return { type: 'algo-widget:attached', file: { ...file, kind } };
}

/**
 * Live recording status, sent on a timer while recording.
 *
 * ELAPSED and CAP, not a remainder: the panel renders `2:31 left` from
 * `maxMs - ms` itself, and it keeps the last `maxMs` it was told so a dropped
 * tick does not freeze the clock. `remainingMs` was a field it has never read.
 */
export function recordTick(opts: { elapsedMs: number; limitMs: number; events: number }): object {
  return {
    type: 'algo-widget:record-tick',
    ms: Math.max(0, Math.round(opts.elapsedMs)),
    maxMs: Math.max(0, Math.round(opts.limitMs)),
    events: opts.events,
  };
}

/** Recording started — the panel swaps its picker for the live card. `maxMs` is
 *  carried here as well as on every tick so the countdown is right on the first
 *  frame instead of a second later. */
export function recordStarted(mode: RecordMode, limitMs: number): object {
  return {
    type: 'algo-widget:record-started',
    mode,
    maxMs: Math.max(0, Math.round(limitMs)),
  };
}

/** Recording ended. `cancel` means the reporter discarded it — the panel must
 *  show no attachment, and the SDK must already have deleted the bytes. */
export function recordResult(opts: { cancel?: boolean; error?: string }): object {
  if (opts.cancel) return { type: 'algo-widget:record-cancelled' };
  if (opts.error) return { type: 'algo-widget:record-error', message: opts.error };
  return { type: 'algo-widget:record-result' };
}
