// The Algo Widget wire contract — see docs/PROTOCOL.md.
//
// This file is the TypeScript half of a contract that also exists in Dart
// (packages/flutter/lib/src/protocol.dart). The two are written from the same
// document and land in the same commit; if you change one without the other,
// one of the two SDKs is now wrong and nothing will tell you until a report is
// silently refused in production.
//
// Deliberately dependency-free and platform-free: no React, no React Native, no
// fetch polyfill. It is the part that can be reasoned about and tested without a
// device, which is most of what goes wrong.

/** Which platform is asking. Decides which attestation the server expects. */
export type Platform = 'android' | 'ios';

/** Which toolkit built the app. Shapes the element descriptors a reader should
 *  expect, and nothing else. */
export type Framework = 'flutter' | 'react_native' | 'native';

/** Trace format version this SDK writes.
 *
 *  DO NOT BUMP THIS AHEAD OF THE SERVER. The staging boundary accepts a range
 *  going back but still refuses anything above its own ceiling, so a client that
 *  ships a higher version has every recording refused — from every installed
 *  copy, until every user updates. Server first, always (PROTOCOL.md §7). */
export const TRACE_VERSION = 1;
export const CRASH_VERSION = 1;

// ── Caps (PROTOCOL.md §3) ──────────────────────────────────────────────────
// Enforced server-side too. They live here so a reporter is told BEFORE an
// upload rather than after it, and so the recorder can stop itself.

export const TRACE_MAX_EVENTS = 500;
/** Head+tail retention, NOT a ring buffer: the beginning of a recording is the
 *  setup a reproduction needs ("log in, open Orders, switch to Draft"). A ring
 *  buffer throws exactly that away. Must sum to TRACE_MAX_EVENTS. */
export const TRACE_HEAD_EVENTS = 150;
export const TRACE_TAIL_EVENTS = 350;
export const TRACE_MAX_DURATION_MS = 15 * 60_000;
export const TRACE_MAX_BYTES = 512 * 1024;

export const TRACE_MAX_TEXT_LEN = 80;
export const TRACE_MAX_PATH_LEN = 256;
export const TRACE_MAX_MESSAGE_LEN = 200;
export const TRACE_MAX_ATTR_LEN = 120;
export const TRACE_MAX_KEY_LEN = 32;
export const TRACE_MAX_METHOD_LEN = 12;
export const TRACE_MAX_TITLE_LEN = 200;

export const CRASH_MAX_CONSOLE = 20;
export const CRASH_MAX_REQUESTS = 10;
export const CRASH_MAX_STACK_FRAMES = 30;

export const MAX_ATTACHMENTS = 6;
export const MAX_BYTES = {
  image: 10 * 1024 * 1024,
  audio: 25 * 1024 * 1024,
  video: 60 * 1024 * 1024,
  trace: TRACE_MAX_BYTES,
} as const;

// ── The trace document ─────────────────────────────────────────────────────

export interface TraceElement {
  /** `testID` — the rung to aim for. It is a compile-time symbol in the app's
   *  own source, which is exactly what makes it greppable by the agent that
   *  later writes the fix. */
  testid?: string;
  id?: string;
  name?: string;
  component?: string;
  role?: string;
  label?: string;
  tag?: string;
  /** Visible text, redaction rules applied. Never an input's value. */
  text?: string;
  path?: string;
}

export type TraceEvent =
  | { type: 'click'; t: number; el?: TraceElement; x?: number; y?: number }
  | { type: 'input'; t: number; el?: TraceElement }
  | { type: 'submit'; t: number; el?: TraceElement }
  | { type: 'nav'; t: number; from?: string; to?: string; cause?: 'user' | 'app' }
  | { type: 'key'; t: number; key?: string }
  | { type: 'scroll'; t: number; el?: TraceElement; dy?: number }
  | { type: 'resize'; t: number; w?: number; h?: number }
  | { type: 'console'; t: number; level?: 'error' | 'warn'; message?: string }
  | { type: 'request'; t: number; method?: string; path?: string; status?: number; ms?: number }
  | { type: 'visibility'; t: number; hidden: boolean }
  | { type: 'gesture'; t: number; gesture?: Gesture; el?: TraceElement }
  | { type: 'mark'; t: number; label?: string };

export type Gesture = 'swipe' | 'long_press' | 'pinch' | 'back' | 'shake';

export interface TracePage {
  /** The screen, as the app's own router names it. NEVER a synthetic `app://`
   *  URL — a fabricated address is indistinguishable downstream from a real
   *  one, and the server has a `url` field for clients that genuinely have one. */
  route: string;
  title?: string;
  viewport?: { w: number; h: number };
}

export interface Trace {
  v: number;
  startedAt: number;
  durationMs: number;
  page: TracePage;
  client: { kind: Platform; framework: Framework };
  events: TraceEvent[];
  dropped?: number;
}

// ── App facts ──────────────────────────────────────────────────────────────

/** What the app says about itself. Untrusted display data server-side, exactly
 *  like a reporter's typed name — the identity half (platform, appId) comes off
 *  the verified ticket and is not sent here. */
export interface AppFacts {
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  /** Model NAME ('Pixel 8'). Never a device identifier: nothing here may single
   *  out a handset across reports. */
  deviceModel?: string;
  locale?: string;
}

// ── Crash ──────────────────────────────────────────────────────────────────

export type CrashKind = 'error' | 'unhandledrejection' | 'boundary';

export interface CrashReport {
  v: number;
  at: number;
  error: { kind: CrashKind; name: string; message: string; stack?: string };
  page: { route: string; title?: string };
  console?: { level: 'error' | 'warn'; message: string; at: number }[];
  requests?: { method?: string; path?: string; status: number; ms?: number; at: number }[];
  app?: AppFacts & { online?: boolean; memoryMb?: number };
}

// ── Session ────────────────────────────────────────────────────────────────

export interface PortalConfig {
  title: string;
  accentColor: string | null;
  showBrandLogo: boolean;
  recordingEnabled: boolean;
  recordingModes: ('steps' | 'voice' | 'screen')[];
  recordingMaxSeconds: number;
  crashCapture: boolean;
  maxAttachments: number;
}

export interface Ticket {
  token: string;
  exp: number;
  portal: PortalConfig;
}

/** What a session attempt produced.
 *
 *  `challenge` is NOT a failure — it is step one of the exchange, and an SDK
 *  that reports it as an error has misread the protocol (PROTOCOL.md §1). */
export type SessionResult =
  | { kind: 'ticket'; ticket: Ticket }
  | { kind: 'challenge'; challenge: string; exp: number }
  | { kind: 'refused'; status: number; reason: string; retryable: boolean };

/**
 * One accepted upload, as the staging route returns it.
 *
 * Note the field is `filename`, not `name`, and there is no size or content
 * type: the STORED content type is derived server-side from the extension and
 * is deliberately not the client's to declare.
 */
export interface StagedFile {
  fileId: string;
  filename: string;
  /** 'image' | 'audio' | 'video' | 'trace' — echoed back, and accepted-and-
   *  ignored when a ref is sent with the report. */
  kind?: string;
}

/** A file the route REFUSED, with its reason. A rejection arrives inside a 200
 *  beside whatever succeeded — one bad attachment must never fail a whole
 *  submission, so it is reported rather than thrown. */
export interface RejectedFile {
  filename: string;
  reason: string;
}

/** The staging route's response. Not a single object: the part is repeatable,
 *  and a request can be partly accepted. */
export interface StageResponse {
  ok: boolean;
  uploaded: StagedFile[];
  rejected: RejectedFile[];
}

/** What the report route accepts as an attachment. `{ fileId, filename }` — a
 *  staging response echoed back verbatim would be REFUSED, because `kind` is
 *  tolerated but `name`/`contentType`/`size` are not. */
export function attachmentRef(file: StagedFile): { fileId: string; filename: string } {
  return { fileId: file.fileId, filename: file.filename };
}

// ── Normalization ──────────────────────────────────────────────────────────
// The server clamps and truncates everything anyway. Doing it here too is not
// belt-and-braces: it keeps the document inside TRACE_MAX_BYTES so the upload
// is not refused wholesale, and it keeps an over-long value from costing a
// reporter their whole recording.

export function clampText(v: string | undefined, max: number): string | undefined {
  if (v === undefined) return undefined;
  const s = v.trim();
  return s.length === 0 ? undefined : s.slice(0, max);
}

export function clampNum(v: number | undefined, min: number, max: number): number | undefined {
  if (v === undefined || !Number.isFinite(v)) return undefined;
  return Math.min(Math.max(min, Math.round(v)), max);
}

/** Truncate a stack to CRASH_MAX_STACK_FRAMES frames and strip query strings.
 *
 *  The query strip is not cosmetic: a frame location can be an app URL, and that
 *  is exactly where a reset token or an email address lives. */
export function clampStack(stack: string | undefined): string | undefined {
  if (!stack) return undefined;
  return stack
    .split('\n')
    .slice(0, CRASH_MAX_STACK_FRAMES)
    .join('\n')
    .replace(/\?[^\s)'"]*/g, '');
}

/** Apply the retention rule: keep the first TRACE_HEAD_EVENTS and the last
 *  TRACE_TAIL_EVENTS, with one `mark` recording what went.
 *
 *  Reading a trace without that marker would suggest the middle simply never
 *  happened. */
export function applyRetention(events: TraceEvent[]): { events: TraceEvent[]; dropped: number } {
  if (events.length <= TRACE_MAX_EVENTS) return { events, dropped: 0 };
  const head = events.slice(0, TRACE_HEAD_EVENTS);
  const tail = events.slice(events.length - TRACE_TAIL_EVENTS);
  const dropped = events.length - head.length - tail.length;
  const marker: TraceEvent = {
    type: 'mark',
    t: head[head.length - 1]?.t ?? 0,
    label: `${dropped} events omitted`,
  };
  return { events: [...head, marker, ...tail], dropped };
}

/** Set a key only when the clamped value survived.
 *
 *  Under `exactOptionalPropertyTypes` an explicit `undefined` is not the same as
 *  an absent key, and here the distinction is real rather than pedantic: an
 *  `undefined` would be serialized away by `JSON.stringify` anyway, but it would
 *  also let a whitespace-only attribute look like a present rung to every
 *  in-process reader between here and the upload. */
function put<T extends object, K extends keyof T>(out: T, key: K, value: T[K] | undefined): void {
  if (value !== undefined) out[key] = value;
}

/** Element identity, best rung first — never the whole ladder when a good rung
 *  exists, because every field costs bytes against TRACE_MAX_BYTES. */
export function normalizeElement(el: TraceElement | undefined): TraceElement | undefined {
  if (!el) return undefined;
  const out: TraceElement = {};
  const attr = (v?: string) => clampText(v, TRACE_MAX_ATTR_LEN);
  put(out, 'testid', attr(el.testid));
  put(out, 'id', attr(el.id));
  put(out, 'name', attr(el.name));
  put(out, 'component', attr(el.component));
  put(out, 'role', attr(el.role));
  put(out, 'label', attr(el.label));
  put(out, 'tag', attr(el.tag));
  put(out, 'text', clampText(el.text, TRACE_MAX_TEXT_LEN));
  put(out, 'path', clampText(el.path, TRACE_MAX_PATH_LEN));
  return Object.keys(out).length > 0 ? out : undefined;
}

export { put as setIfDefined };

/** Every field of T, but each may also be undefined. */
type Undefinable<T> = { [K in keyof T]: T[K] | undefined };

/**
 * Drop the keys whose value is undefined.
 *
 * Every collector here builds an event out of CLAMPED values, and a clamp can
 * legitimately return nothing (an all-whitespace label, a non-finite
 * coordinate). Under `exactOptionalPropertyTypes` an explicit `undefined` is not
 * the same as an absent key, and the conditional-spread idiom
 * (`...(x ? { x } : {})`) does not help when the value itself may be undefined.
 * One helper beats that argument at nineteen call sites.
 */
export function compact<T extends object>(obj: Undefinable<T>): T {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined) out[k] = v;
  }
  return out as T;
}

/** Which staging bucket an extension falls in — decides the size cap an SDK
 *  should enforce before uploading. Unknown extensions return undefined and
 *  must not be staged. */
export function kindForFilename(name: string): keyof typeof MAX_BYTES | undefined {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  if (['png', 'jpg', 'jpeg', 'gif', 'webp'].includes(ext)) return 'image';
  if (['m4a', 'aac', 'mp3', 'wav', 'weba', 'ogg', 'oga'].includes(ext)) return 'audio';
  if (['mp4', 'mov', '3gp', '3gpp', 'webm'].includes(ext)) return 'video';
  if (ext === 'json') return 'trace';
  return undefined;
}
