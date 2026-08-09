// The interaction recorder (docs/PROTOCOL.md §3).
//
// Collects what the reporter did, on one clock shared with the narration and
// the video, so "I tap HERE and THIS breaks" resolves to a string an AI agent
// can grep for in the repository.
//
// THE RULE THAT OUTRANKS EVERYTHING HERE: values are never captured. There is no
// code path in this file that reads a field's value, and there must never be
// one. `input` records THAT a field was typed into. Adding a value field is a
// product decision, not a refactor — and this repository is public partly so a
// customer's security team can check that claim rather than take it.
import {
  TRACE_MAX_DURATION_MS,
  TRACE_MAX_EVENTS,
  TRACE_MAX_KEY_LEN,
  TRACE_MAX_MESSAGE_LEN,
  TRACE_MAX_METHOD_LEN,
  TRACE_MAX_PATH_LEN,
  TRACE_MAX_TITLE_LEN,
  applyRetention,
  clampNum,
  clampText,
  compact,
  normalizeElement,
  type Framework,
  type Gesture,
  type Platform,
  type Trace,
  type TraceElement,
  type TraceEvent,
  type TracePage,
} from './protocol.ts';

export interface RecorderOptions {
  platform: Platform;
  framework: Framework;
  /** Hard stop, from the portal config. The recorder stops ITSELF here — a
   *  reporter must never discover the limit by having a recording refused. */
  maxSeconds: number;
  now?: () => number;
  /** Fired when the cap is reached, so the host can tear down media capture. */
  onAutoStop?: () => void;
}

/** The recorder's whole surface. Nothing observes until `start()`. */
export class TraceRecorder {
  private events: TraceEvent[] = [];
  private startedAt = 0;
  private pausedAt: number | null = null;
  private pausedMs = 0;
  private recording = false;
  private route = '';
  private title: string | undefined;
  private readonly now: () => number;
  private readonly maxMs: number;

  private readonly opts: RecorderOptions;

  constructor(opts: RecorderOptions) {
    this.opts = opts;
    this.now = opts.now ?? Date.now;
    this.maxMs = Math.min(TRACE_MAX_DURATION_MS, Math.max(1, opts.maxSeconds) * 1000);
  }

  get isRecording(): boolean {
    return this.recording;
  }

  /** Milliseconds left, for the countdown the reporter watches. */
  get remainingMs(): number {
    if (!this.recording) return this.maxMs;
    return Math.max(0, this.maxMs - this.elapsed());
  }

  /** Elapsed and cap, which is the pair the PANEL wants: it renders the
   *  countdown itself from `maxMs - ms` (see the frame's record-tick handler),
   *  so handing it a pre-computed remainder left it nothing to fall back on
   *  when a tick was missed. Media time, like everything else here — a paused
   *  recording does not advance. */
  get elapsedMs(): number {
    return this.elapsed();
  }

  get limitMs(): number {
    return this.maxMs;
  }

  get eventCount(): number {
    return this.events.length;
  }

  /** Begin. `route` is where the reporter is standing when they press Record —
   *  the trace has to say where it starts or the first steps float. */
  start(route: string, title?: string): void {
    this.events = [];
    this.startedAt = this.now();
    this.pausedAt = null;
    this.pausedMs = 0;
    this.recording = true;
    this.route = route;
    this.title = title;
  }

  pause(): void {
    if (!this.recording || this.pausedAt !== null) return;
    this.pausedAt = this.now();
  }

  resume(): void {
    if (this.pausedAt === null) return;
    this.pausedMs += this.now() - this.pausedAt;
    this.pausedAt = null;
  }

  /** Media time, not wall clock — a paused recording must not accumulate a gap
   *  that the video does not have, or every later event lands off the clock the
   *  narration shares. */
  private elapsed(): number {
    if (!this.recording) return 0;
    const paused = this.pausedMs + (this.pausedAt !== null ? this.now() - this.pausedAt : 0);
    return this.now() - this.startedAt - paused;
  }

  /** The one entry point. Everything else in this file funnels through it, so
   *  the pause rule, the cap and the auto-stop cannot be bypassed by a new
   *  collector forgetting one of them. */
  private push(e: TraceEvent): void {
    if (!this.recording || this.pausedAt !== null) return;
    const t = this.elapsed();
    if (t >= this.maxMs) {
      this.stopAtCap();
      return;
    }
    this.events.push({ ...e, t: clampNum(t, 0, TRACE_MAX_DURATION_MS) ?? 0 });
    // Soft ceiling: retention runs at build time, but an unbounded array on a
    // phone is a memory problem long before it is a format problem.
    if (this.events.length > TRACE_MAX_EVENTS * 2) {
      this.events = applyRetention(this.events).events;
    }
  }

  private stopAtCap(): void {
    if (!this.recording) return;
    this.recording = false;
    this.opts.onAutoStop?.();
  }

  // ── Collectors ───────────────────────────────────────────────────────────

  tap(el?: TraceElement, x?: number, y?: number): void {
    this.push(
      compact<TraceEvent & { type: 'click' }>({
        type: 'click',
        t: 0,
        el: normalizeElement(el),
        x: clampNum(x, -1e6, 1e6),
        y: clampNum(y, -1e6, 1e6),
      }),
    );
  }

  /** A field was typed into. Callers pass the ELEMENT and nothing else — there
   *  is deliberately no parameter here that could carry a value. */
  input(el?: TraceElement): void {
    this.push(
      compact<TraceEvent & { type: 'input' }>({ type: 'input', t: 0, el: normalizeElement(el) }),
    );
  }

  submit(el?: TraceElement): void {
    this.push(
      compact<TraceEvent & { type: 'submit' }>({ type: 'submit', t: 0, el: normalizeElement(el) }),
    );
  }

  /** A screen transition. `cause` is what stops a router guard's redirect being
   *  written up as a step the reader should perform. */
  navigate(to: string, cause: 'user' | 'app' = 'user'): void {
    const from = this.route;
    this.route = to;
    this.push(
      compact<TraceEvent & { type: 'nav' }>({
        type: 'nav',
        t: 0,
        from: clampText(from, TRACE_MAX_PATH_LEN),
        to: clampText(to, TRACE_MAX_PATH_LEN),
        cause,
      }),
    );
  }

  key(name: string): void {
    this.push(
      compact<TraceEvent & { type: 'key' }>({
        type: 'key',
        t: 0,
        key: clampText(name, TRACE_MAX_KEY_LEN),
      }),
    );
  }

  scroll(dy: number, el?: TraceElement): void {
    this.push(
      compact<TraceEvent & { type: 'scroll' }>({
        type: 'scroll',
        t: 0,
        el: normalizeElement(el),
        dy: clampNum(dy, -1e6, 1e6),
      }),
    );
  }

  resize(w: number, h: number): void {
    this.push(
      compact<TraceEvent & { type: 'resize' }>({
        type: 'resize',
        t: 0,
        w: clampNum(w, 0, 100_000),
        h: clampNum(h, 0, 100_000),
      }),
    );
  }

  console(level: 'error' | 'warn', message: string): void {
    this.push(
      compact<TraceEvent & { type: 'console' }>({
        type: 'console',
        t: 0,
        level,
        message: clampText(message, TRACE_MAX_MESSAGE_LEN),
      }),
    );
  }

  /** A FAILED request only, and never headers, bodies or query strings. */
  request(method: string, path: string, status: number, ms?: number): void {
    if (status > 0 && status < 400) return;
    this.push(
      compact<TraceEvent & { type: 'request' }>({
        type: 'request',
        t: 0,
        method: clampText(method, TRACE_MAX_METHOD_LEN),
        path: clampText(stripQuery(path), TRACE_MAX_PATH_LEN),
        status: clampNum(status, 0, 599),
        ms: clampNum(ms, 0, TRACE_MAX_DURATION_MS),
      }),
    );
  }

  /** The app went to the background or came back. Its whole job is to give a
   *  SILENCE a meaning: thirty seconds in another app looks exactly like thirty
   *  seconds of reading, and they are opposite kinds of evidence. */
  visibility(hidden: boolean): void {
    this.push({ type: 'visibility', t: 0, hidden });
  }

  /** `back` especially — Android's system back is a navigation the app never
   *  sees as a control, so without it a reproduction reads as though the
   *  reporter teleported between screens. */
  gesture(kind: Gesture, el?: TraceElement): void {
    this.push(
      compact<TraceEvent & { type: 'gesture' }>({
        type: 'gesture',
        t: 0,
        gesture: kind,
        el: normalizeElement(el),
      }),
    );
  }

  // ── Output ───────────────────────────────────────────────────────────────

  /** Assemble the document. Safe to call after `stop()`; safe to call twice. */
  build(): Omit<Trace, 'v'> {
    const { events, dropped } = applyRetention(this.events);
    return {
      startedAt: this.startedAt,
      durationMs: Math.min(this.maxMs, Math.max(0, this.elapsedFrozen())),
      page: compact<TracePage>({
        route: this.route,
        title: clampText(this.title, TRACE_MAX_TITLE_LEN),
      }),
      client: { kind: this.opts.platform, framework: this.opts.framework },
      events,
      ...(dropped > 0 ? { dropped } : {}),
    };
  }

  stop(): Omit<Trace, 'v'> {
    const doc = this.build();
    this.recording = false;
    return doc;
  }

  /** Discard everything, client-side. Cancel must guarantee that nothing
   *  recorded ever left the device. */
  cancel(): void {
    this.recording = false;
    this.events = [];
    this.startedAt = 0;
  }

  /** Duration that survives `stop()` flipping `recording` off. */
  private elapsedFrozen(): number {
    const last = this.events[this.events.length - 1]?.t ?? 0;
    return this.recording ? this.elapsed() : last;
  }
}

/** Same-origin path only — never a full URL and never a query string
 *  (PROTOCOL.md §6). A query is where tokens and email addresses live. */
export function stripQuery(pathOrUrl: string): string {
  const cut = pathOrUrl.search(/[?#]/);
  const path = cut < 0 ? pathOrUrl : pathOrUrl.slice(0, cut);
  try {
    // A cross-origin request contributes its HOST, not its path: another
    // service's URL structure is not this app's business.
    const u = new URL(path);
    return u.host;
  } catch {
    return path;
  }
}
