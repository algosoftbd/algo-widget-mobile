// Wiring the SDK into a React Native app's own machinery
// (docs/PROTOCOL.md §3, §5).
//
// This is the file that decides whether a report is worth having. An SDK that
// is only initialised still files reports; they just say nothing — no failed
// request, no logged error, no screen name, and a crash nobody sees. Each
// binding below hands the reproduction one kind of evidence it cannot get on
// its own.
//
// Everything here patches a GLOBAL the host app shares, so every function is
// written to the same three rules:
//
//  1. IT CHAINS, NEVER REPLACES. An app already has a crash reporter and a
//     console; taking one over is a regression the app author did not ask for.
//  2. IT UNINSTALLS. Each returns a teardown that restores exactly what was
//     there — including when two of ours are installed over each other.
//  3. IT NEVER THROWS INTO THE HOST. A bug in observation must not become a bug
//     in the app being observed.
import { compact } from './protocol.ts';
import type { CrashReporter } from './crash.ts';
import type { TraceRecorder } from './recorder.ts';

/** Undo a binding. Idempotent — calling it twice is not an error. */
export type Unbind = () => void;

/** What the collectors write to. Both are optional so an app can wire crash
 *  capture without the recorder, or vice versa. */
export interface Sinks {
  recorder?: TraceRecorder;
  crash?: CrashReporter;
}

// ── Failed requests ────────────────────────────────────────────────────────

/**
 * Record FAILED requests — never successful ones, never headers, never bodies,
 * never query strings.
 *
 * `fetch` is patched rather than an interceptor added because React Native has
 * no shared HTTP client: an app may use fetch, axios-on-fetch, or its own
 * wrapper, and all of them bottom out here. `XMLHttpRequest` is patched too,
 * since axios' default RN adapter uses it directly.
 */
export function bindNetwork(sinks: Sinks): Unbind {
  const g = globalThis as { fetch?: typeof fetch; XMLHttpRequest?: unknown };
  const originalFetch = g.fetch;
  if (!originalFetch) return () => {};

  const record = (method: string, url: string, status: number, ms: number) => {
    // A success is not evidence. Recording every 200 would bury the one request
    // that mattered and spend the trace's 500-event budget on noise.
    if (status >= 400 || status === 0) {
      sinks.recorder?.request(method, url, status, ms);
      sinks.crash?.noteFailedRequest(method, url, status, ms);
    }
  };

  const patched: typeof fetch = async (input, init) => {
    const started = Date.now();
    const method = (init?.method ?? (typeof input === 'object' && 'method' in input ? input.method : 'GET')) || 'GET';
    const url = typeof input === 'string' ? input : String((input as { url?: string }).url ?? input);
    try {
      const res = await originalFetch(input, init);
      record(method, url, res.status, Date.now() - started);
      return res;
    } catch (err) {
      // status 0 is a transport failure — no response ever arrived. It is the
      // single most useful line in an offline bug report.
      record(method, url, 0, Date.now() - started);
      throw err;
    }
  };

  g.fetch = patched;
  return () => {
    // Only restore if nothing else patched on top of us; clobbering a later
    // interceptor would silently disable the app's own instrumentation.
    if (g.fetch === patched) g.fetch = originalFetch;
  };
}

// ── Logged errors ──────────────────────────────────────────────────────────

/**
 * Capture `console.error` / `console.warn` — the SHAPE of what was logged, and
 * only inside the caps.
 *
 * The arguments are stringified and truncated, which is deliberate rather than
 * lazy: an app logs objects, and an object logged by an app that is mid-failure
 * is the most likely place for a user's data to appear. A message is evidence;
 * a serialized payload is a leak.
 */
export function bindConsole(sinks: Sinks): Unbind {
  const original = { error: console.error, warn: console.warn };

  const capture = (level: 'error' | 'warn') =>
    function patched(this: unknown, ...args: unknown[]) {
      try {
        const message = args.map(shapeOf).join(' ');
        sinks.recorder?.console(level, message);
        sinks.crash?.noteConsole(level, message);
      } catch {
        // Observation must never break the app being observed.
      }
      original[level].apply(this, args as never);
    };

  console.error = capture('error');
  console.warn = capture('warn');
  return () => {
    console.error = original.error;
    console.warn = original.warn;
  };
}

/**
 * What a logged argument WAS, not what it contained.
 *
 * A string contributes itself (it is a message the developer wrote). An Error
 * contributes its name and message. Everything else contributes its shape —
 * `[Object]`, `[Array(3)]` — because the alternative is serializing an object
 * an app logged while failing, which is exactly where a user's record ends up.
 */
export function shapeOf(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (value instanceof Error) return `${value.name}: ${value.message}`;
  if (Array.isArray(value)) return `[Array(${value.length})]`;
  if (typeof value === 'object') return '[Object]';
  return String(value);
}

// ── Crashes ────────────────────────────────────────────────────────────────

/** React Native's global handler hook. Structural so this file needs no
 *  react-native import and stays testable on a laptop. */
interface ErrorUtilsLike {
  getGlobalHandler?: () => ((error: Error, isFatal?: boolean) => void) | undefined;
  setGlobalHandler?: (handler: (error: Error, isFatal?: boolean) => void) => void;
}

/**
 * File uncaught errors, CHAINING to whatever handler was already installed.
 *
 * Chaining is not politeness — an app with Crashlytics or Sentry already has a
 * global handler, and replacing it would silently stop their crash reporting
 * the day this SDK is added. Ours runs first (so the report is captured even if
 * theirs tears the process down), then theirs runs unchanged.
 *
 * The report is only PERSISTED here. A network call inside a handler on a dying
 * process is a race the handler usually loses; `flush` sends it on next launch.
 */
export function bindCrashHandler(crash: CrashReporter, errorUtils?: ErrorUtilsLike): Unbind {
  const utils = errorUtils ?? (globalThis as { ErrorUtils?: ErrorUtilsLike }).ErrorUtils;
  if (!utils?.setGlobalHandler) return () => {};
  const previous = utils.getGlobalHandler?.();

  const handler = (error: Error, isFatal?: boolean) => {
    try {
      void crash.capture('error', compact({
        name: error?.name,
        message: error?.message,
        stack: error?.stack,
      }));
    } catch {
      // Never let the reporter be the reason a crash handler throws.
    }
    previous?.(error, isFatal);
  };

  utils.setGlobalHandler(handler);
  return () => {
    if (previous) utils.setGlobalHandler?.(previous);
  };
}

/**
 * File unhandled promise rejections.
 *
 * A separate kind (`unhandledrejection`) rather than folding into `error`,
 * because the two mean different things to whoever reads the report: an
 * uncaught error killed a render, a rejected promise means something the app
 * started never finished and nobody was watching.
 */
export function bindRejectionHandler(crash: CrashReporter): Unbind {
  const g = globalThis as {
    addEventListener?: (t: string, h: (e: unknown) => void) => void;
    removeEventListener?: (t: string, h: (e: unknown) => void) => void;
  };
  if (!g.addEventListener) return () => {};

  const handler = (event: unknown) => {
    const reason = (event as { reason?: unknown })?.reason;
    const error = reason instanceof Error ? reason : undefined;
    void crash.capture('unhandledrejection', compact({
      name: error?.name ?? 'UnhandledRejection',
      message: error?.message ?? shapeOf(reason),
      stack: error?.stack,
    }));
  };
  g.addEventListener('unhandledrejection', handler);
  return () => g.removeEventListener?.('unhandledrejection', handler);
}

// ── Navigation ─────────────────────────────────────────────────────────────

/**
 * Follow the app's navigation so a recorded step can say which screen it
 * happened on — and so a crash knows the route it died on.
 *
 * Takes the route NAME, not a navigation object: React Navigation, Expo Router
 * and a hand-rolled stack all expose that differently, and an SDK that only
 * works with one router is one most apps cannot use. The host calls this from
 * `NavigationContainer.onStateChange` (or its equivalent) with a name it
 * already has.
 *
 * `cause` matters more than it looks: a route guard's redirect and a deliberate
 * tap are the same event otherwise, and a reproduction that lists an app's own
 * redirect as a step sends whoever follows it looking for a control that does
 * not exist.
 */
export function makeNavigationTracker(sinks: Sinks): {
  onRouteChange: (route: string, cause?: 'user' | 'app') => void;
  currentRoute: () => string;
} {
  let current = '';
  return {
    onRouteChange(route, cause = 'user') {
      if (!route || route === current) return;
      current = route;
      sinks.recorder?.navigate(route, cause);
    },
    // Read fresh by the crash reporter on every crash — an app navigates for
    // the whole life of its process, so a route captured once at launch would
    // put every crash on the first screen.
    currentRoute: () => current,
  };
}

// ── Everything, once ───────────────────────────────────────────────────────

export interface BindOptions extends Sinks {
  /** Absent ⇒ bound. Each can be disabled where the host has its own. */
  network?: boolean;
  console?: boolean;
  crashes?: boolean;
  errorUtils?: ErrorUtilsLike;
}

/**
 * Install every binding the sinks support, and return ONE teardown.
 *
 * Teardown order is the reverse of install order, so a handler chained on top
 * of another is always removed before the one beneath it — otherwise unbinding
 * ours would leave the host's handler pointing at a function we have discarded.
 */
export function bindAll(opts: BindOptions): Unbind {
  const undo: Unbind[] = [];
  if (opts.network !== false) undo.push(bindNetwork(opts));
  if (opts.console !== false) undo.push(bindConsole(opts));
  if (opts.crashes !== false && opts.crash) {
    undo.push(bindCrashHandler(opts.crash, opts.errorUtils));
    undo.push(bindRejectionHandler(opts.crash));
  }
  return () => {
    for (const fn of undo.reverse()) {
      try {
        fn();
      } catch {
        // A teardown that throws must not strand the others.
      }
    }
    undo.length = 0;
  };
}
