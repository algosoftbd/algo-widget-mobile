// Auto crash capture (docs/PROTOCOL.md §5).
//
// When the app dies, the SDK files the bug report itself. Two things make this
// different from a reporter-driven report, and both shape the whole file:
//
//  1. THE PROCESS IS DYING. A network call inside an uncaught-exception handler
//     is a race the handler usually loses, so the payload is PERSISTED and sent
//     on next launch. Everything here is written to survive being interrupted
//     halfway.
//  2. NOBODY IS WATCHING. An unattended writer with a bug becomes a flood, so
//     the throttles below are required rather than defensive.
import {
  CRASH_MAX_CONSOLE,
  CRASH_MAX_REQUESTS,
  CRASH_VERSION,
  TRACE_MAX_MESSAGE_LEN,
  TRACE_MAX_METHOD_LEN,
  TRACE_MAX_PATH_LEN,
  clampNum,
  clampStack,
  clampText,
  type AppFacts,
  type CrashKind,
  type CrashReport,
} from './protocol.ts';
import { stripQuery } from './recorder.ts';

/** Somewhere to put a report while the process dies. Injected rather than
 *  imported so this file stays testable and free of AsyncStorage. */
export interface CrashStore {
  save(reports: CrashReport[]): Promise<void>;
  load(): Promise<CrashReport[]>;
  clear(): Promise<void>;
}

export interface CrashOptions {
  store: CrashStore;
  /** The route AT CRASH TIME, read fresh — see `routeAtCrash` below. */
  currentRoute: () => string;
  app?: () => AppFacts & { online?: boolean; memoryMb?: number };
  now?: () => number;
  /** Absent ⇒ crash capture is off for this app, whatever the portal says. The
   *  host keeps a kill switch the OS cannot take away. */
  enabled?: () => boolean;
}

/** One burst per launch: a screen that throws forty times in a second is ONE
 *  crash, not forty. */
const MAX_PER_LAUNCH = 1;
/** Per route, per process. Three is enough to see a pattern, few enough that a
 *  broken app cannot spend a portal's whole hourly budget. */
const MAX_PER_ROUTE = 3;
/** Same signature, same half hour — almost certainly the same user hitting the
 *  same wall again. */
const COOLDOWN_MS = 30 * 60_000;

export class CrashReporter {
  private readonly ring: { console: NonNullable<CrashReport['console']>; requests: NonNullable<CrashReport['requests']> } =
    { console: [], requests: [] };
  private burst = 0;
  private readonly perRoute = new Map<string, number>();
  private readonly cooldown = new Map<string, number>();
  private readonly now: () => number;

  private readonly opts: CrashOptions;

  constructor(opts: CrashOptions) {
    this.opts = opts;
    this.now = opts.now ?? Date.now;
  }

  /** The last errors before the crash. Shapes and statuses only — an argument's
   *  VALUE is never recorded, here or anywhere. */
  noteConsole(level: 'error' | 'warn', message: string): void {
    this.ring.console.push({
      level,
      message: clampText(message, TRACE_MAX_MESSAGE_LEN) ?? '',
      at: this.now(),
    });
    if (this.ring.console.length > CRASH_MAX_CONSOLE) this.ring.console.shift();
  }

  noteFailedRequest(method: string, path: string, status: number, ms?: number): void {
    if (status > 0 && status < 400) return;
    const entry: NonNullable<CrashReport['requests']>[number] = {
      method: clampText(method, TRACE_MAX_METHOD_LEN) ?? '',
      path: clampText(stripQuery(path), TRACE_MAX_PATH_LEN) ?? '',
      status: clampNum(status, 0, 599) ?? 0,
      at: this.now(),
    };
    const clampedMs = clampNum(ms, 0, 600_000);
    if (clampedMs !== undefined) entry.ms = clampedMs;
    this.ring.requests.push(entry);
    if (this.ring.requests.length > CRASH_MAX_REQUESTS) this.ring.requests.shift();
  }

  /**
   * Record a crash. Returns false when a throttle suppressed it.
   *
   * Persists rather than sends: see the file header. The caller is inside a
   * handler on a dying process and must do as little as possible.
   */
  async capture(kind: CrashKind, error: { name?: string; message?: string; stack?: string }): Promise<boolean> {
    if (this.opts.enabled && !this.opts.enabled()) return false;
    if (this.burst >= MAX_PER_LAUNCH) return false;

    // Read the route NOW, not at launch. An app navigates for the whole life of
    // its process without restarting, so a route captured at startup would make
    // every crash look like it happened on the first screen — and a per-launch
    // budget would silently become a per-user-session budget, where one screen's
    // crash suppresses another's.
    const route = this.opts.currentRoute();

    const seenOnRoute = this.perRoute.get(route) ?? 0;
    if (seenOnRoute >= MAX_PER_ROUTE) return false;

    const signature = crashSignature(kind, error.name, error.message, route);
    const last = this.cooldown.get(signature);
    if (last !== undefined && this.now() - last < COOLDOWN_MS) return false;

    this.burst += 1;
    this.perRoute.set(route, seenOnRoute + 1);
    this.cooldown.set(signature, this.now());

    const stack = clampStack(error.stack);
    const report: CrashReport = {
      v: CRASH_VERSION,
      at: this.now(),
      error: {
        kind,
        name: clampText(error.name, 120) ?? 'Error',
        message: clampText(error.message, 500) ?? '(no message)',
        ...(stack !== undefined ? { stack } : {}),
      },
      page: { route },
      ...(this.ring.console.length > 0 ? { console: [...this.ring.console] } : {}),
      ...(this.ring.requests.length > 0 ? { requests: [...this.ring.requests] } : {}),
      ...(this.opts.app ? { app: this.opts.app() } : {}),
    };

    try {
      const queued = await this.opts.store.load();
      // Cap the queue: an app that crashes on every launch must not accumulate
      // an unbounded backlog on the user's device.
      await this.opts.store.save([...queued, report].slice(-5));
    } catch {
      // A failed write loses one crash report. Throwing here would lose the
      // crash the app was already having.
      return false;
    }
    return true;
  }

  /**
   * Send anything persisted by a previous launch, then clear.
   *
   * Cleared unconditionally on a successful send AND on a permanent refusal: a
   * report the server will never accept must not be retried on every launch for
   * the life of the install.
   */
  async flush(send: (report: CrashReport) => Promise<boolean>): Promise<number> {
    let queued: CrashReport[];
    try {
      queued = await this.opts.store.load();
    } catch {
      return 0;
    }
    if (queued.length === 0) return 0;
    let sent = 0;
    const failed: CrashReport[] = [];
    for (const report of queued) {
      // eslint-disable-next-line no-await-in-loop -- ordered, and at most 5
      const ok = await send(report).catch(() => false);
      if (ok) sent += 1;
      else failed.push(report);
    }
    try {
      if (failed.length === 0) await this.opts.store.clear();
      else await this.opts.store.save(failed);
    } catch {
      /* the next launch tries again */
    }
    return sent;
  }
}

/**
 * A grouping key, never a security primitive.
 *
 * The ROUTE is part of it deliberately: the same error on two screens is two
 * bugs, and merging them hides one of them. Numbers and hex ids are normalized
 * out so one bug groups with its own repeats rather than filing one issue per
 * user.
 */
export function crashSignature(
  kind: CrashKind,
  name: string | undefined,
  message: string | undefined,
  route: string,
): string {
  const normalized = (message ?? '')
    .toLowerCase()
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, '<uuid>')
    .replace(/\b[0-9a-f]{16,}\b/g, '<hash>')
    .replace(/\d+/g, '<n>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, TRACE_MAX_MESSAGE_LEN);
  return [kind, (name ?? '').toLowerCase(), normalized, route.toLowerCase()].join('|');
}

/** Browser/runtime notices that are not exceptions. Filing these as crashes
 *  buries the real one — measured on the web loader, where a live page's report
 *  named a ResizeObserver notice and the actual TypeError appeared nowhere. */
export function isIgnorableCrash(name: string | undefined, message: string | undefined): boolean {
  const m = `${name ?? ''} ${message ?? ''}`.toLowerCase();
  return (
    m.includes('resizeobserver loop') ||
    m.trim() === 'script error.' ||
    m.includes('network request failed') // a dropped connection is not a crash
  );
}
