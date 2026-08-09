// HTTP transport for the Algo Widget protocol (docs/PROTOCOL.md).
//
// Platform-free by construction: it takes `fetch` and an attestation provider as
// inputs rather than reaching for them. That is what lets the whole session
// exchange — the part most likely to be got wrong, and the part no device is
// needed to get wrong — be tested without a simulator.
import {
  CRASH_VERSION,
  MAX_BYTES,
  TRACE_VERSION,
  attachmentRef,
  kindForFilename,
  type AppFacts,
  type CrashReport,
  type Platform,
  type SessionResult,
  type StagedFile,
  type StageResponse,
  type Ticket,
  type Trace,
} from './protocol.ts';

/** Produces a platform attestation for a server-issued challenge.
 *
 *  Returning null means "I cannot attest" — a missing Play Services, a
 *  simulator, a provider that threw. The client then reports a refusal rather
 *  than retrying forever, because nothing about this attempt will differ next
 *  time. */
export type AttestationProvider = (challenge: string) => Promise<string | null>;

export interface ClientOptions {
  /** OS host, no trailing slash — e.g. `https://os.algosoftbd.com`. */
  host: string;
  /** The portal's `pk_…` key. Not a secret: it ships inside the app, which is
   *  the entire reason attestation exists. */
  portalKey: string;
  platform: Platform;
  /** Package name (Android) / bundle id (iOS). A LOOKUP KEY, never an identity
   *  — the server uses what the attestation reports. */
  appId: string;
  app?: AppFacts;
  attest?: AttestationProvider;
  /** Called once for every piece of evidence that could not be staged. A
   *  report submits without it either way — evidence going missing must never
   *  block a reporter — but it is never silent. */
  onEvidenceDropped?: (filename: string, reason: string) => void;
  fetch?: typeof globalThis.fetch;
  /** Wall clock, injectable so ticket-expiry logic is testable. */
  now?: () => number;
}

/** Trailing slashes, without the backtracking a `/\/+$/` invites. */
function stripTrailingSlash(host: string): string {
  let end = host.length;
  while (end > 0 && host[end - 1] === '/') end -= 1;
  return host.slice(0, end);
}

/** Re-mint this far before a ticket actually expires, so a long upload cannot
 *  finish against a ticket that died mid-flight. */
const TICKET_SKEW_MS = 60_000;

export class AlgoWidgetClient {
  private readonly opts: Required<Pick<ClientOptions, 'host' | 'portalKey' | 'platform' | 'appId'>> &
    ClientOptions;
  private readonly doFetch: typeof globalThis.fetch;
  private readonly now: () => number;
  private ticket: Ticket | null = null;
  /** In-flight session, so ten simultaneous callers do not mint ten tickets. */
  private pending: Promise<Ticket | null> | null = null;

  constructor(opts: ClientOptions) {
    this.opts = { ...opts, host: stripTrailingSlash(opts.host) };
    this.doFetch = opts.fetch ?? globalThis.fetch;
    this.now = opts.now ?? Date.now;
  }

  /** The portal's config, once a session exists. Null before that. */
  get portal() {
    return this.ticket?.portal ?? null;
  }

  /** One round trip. Exposed so the exchange can be driven step by step in
   *  tests; ordinary callers want `session()`. */
  async requestSession(challenge?: string, attestation?: string): Promise<SessionResult> {
    const body: Record<string, unknown> = {
      key: this.opts.portalKey,
      client: {
        platform: this.opts.platform,
        appId: this.opts.appId,
        ...(challenge ? { challenge } : {}),
        ...(attestation ? { attestation } : {}),
        ...(this.opts.app ? { app: this.opts.app } : {}),
      },
    };
    let res: Response;
    try {
      res = await this.doFetch(`${this.opts.host}/api/widget/session`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    } catch (err) {
      // A network failure IS retryable — unlike every refusal below, next time
      // really might differ.
      return { kind: 'refused', status: 0, reason: String(err), retryable: true };
    }
    const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;

    if (res.ok && typeof json.token === 'string') {
      return {
        kind: 'ticket',
        ticket: {
          token: json.token,
          exp: typeof json.exp === 'number' ? json.exp : this.now() + 30 * 60_000,
          portal: json.portal as Ticket['portal'],
        },
      };
    }
    // 401 + challenge is STEP ONE, not an error. Reporting it as a failure is
    // the single most likely way to misimplement this protocol.
    if (res.status === 401 && typeof json.challenge === 'string') {
      return {
        kind: 'challenge',
        challenge: json.challenge,
        exp: typeof json.exp === 'number' ? json.exp : this.now() + 120_000,
      };
    }
    return {
      kind: 'refused',
      status: res.status,
      reason: typeof json.error === 'string' ? json.error : `session refused (${res.status})`,
      // 429 is the only refusal worth trying again later; the rest are
      // configuration, and retrying a misconfiguration is just noise.
      retryable: res.status === 429,
    };
  }

  /**
   * A valid ticket, minting one if needed. Null when the portal will not have
   * us — which callers must treat as "hide the report button", never as an
   * error to show a reporter (PROTOCOL.md §1).
   */
  async session(): Promise<Ticket | null> {
    if (this.ticket && this.ticket.exp - TICKET_SKEW_MS > this.now()) return this.ticket;
    // Coalesce: a crash flush and a reporter pressing the button at the same
    // moment must not race two exchanges.
    this.pending ??= this.mint().finally(() => {
      this.pending = null;
    });
    return this.pending;
  }

  private async mint(): Promise<Ticket | null> {
    const first = await this.requestSession();
    if (first.kind === 'ticket') {
      this.ticket = first.ticket;
      return this.ticket;
    }
    if (first.kind === 'refused') return null;

    // Attestation round. Exactly ONE retry: a second challenge would be a
    // second chance at the same deterministic outcome.
    const token = this.opts.attest ? await this.opts.attest(first.challenge).catch(() => null) : null;
    if (!token) return null;

    const second = await this.requestSession(first.challenge, token);
    if (second.kind !== 'ticket') return null;
    this.ticket = second.ticket;
    return this.ticket;
  }

  private async authed(path: string, init: RequestInit): Promise<Response | null> {
    const ticket = await this.session();
    if (!ticket) return null;
    const headers = new Headers(init.headers);
    headers.set('x-widget-token', ticket.token);
    try {
      return await this.doFetch(`${this.opts.host}${path}`, { ...init, headers });
    } catch {
      return null;
    }
  }

  /**
   * Stage one piece of evidence.
   *
   * Refuses over-cap and unknown-extension files HERE rather than uploading
   * them to be refused: the reporter is on a phone, probably on mobile data, and
   * finding out after a 60 MB upload is the worst possible time.
   */
  async stage(
    bytes: Uint8Array | Blob,
    filename: string,
    contentType: string,
  ): Promise<StagedFile | null> {
    const kind = kindForFilename(filename);
    if (!kind) {
      this.dropped(filename, 'unsupported file type');
      return null;
    }
    const size = bytes instanceof Blob ? bytes.size : bytes.byteLength;
    if (size > MAX_BYTES[kind]) {
      this.dropped(filename, `too large (max ${Math.round(MAX_BYTES[kind] / 1024 / 1024)} MB)`);
      return null;
    }

    const form = new FormData();
    const blob = bytes instanceof Blob ? bytes : new Blob([bytes as BlobPart], { type: contentType });
    // The part is named `files` and is REPEATABLE (the route reads
    // `getAll('files')`). A part named `file` gets a 400 "no files".
    form.append('files', blob, filename);
    const res = await this.authed('/api/widget/files', { method: 'POST', body: form });
    if (!res?.ok) {
      this.dropped(filename, `upload failed (${res?.status ?? 'network'})`);
      return null;
    }
    const body = (await res.json().catch(() => null)) as StageResponse | null;
    // A 200 does NOT mean accepted: a per-file rejection comes back in
    // `rejected` beside whatever succeeded, because one bad attachment must
    // never fail a whole submission.
    const rejected = body?.rejected?.[0];
    if (rejected) {
      this.dropped(rejected.filename, rejected.reason);
      return null;
    }
    return body?.uploaded?.[0] ?? null;
  }

  /** Every piece of evidence that goes missing is reported once, here — the
   *  report still submits without it, but silently losing a reporter's
   *  screen recording is not something an SDK gets to do quietly. */
  private dropped(filename: string, reason: string): void {
    this.opts.onEvidenceDropped?.(filename, reason);
  }

  /** Stage a trace. Its own method because the version stamp and the byte cap
   *  are the two things a caller must not have to remember. */
  async stageTrace(trace: Omit<Trace, 'v'>): Promise<StagedFile | null> {
    const doc: Trace = { ...trace, v: TRACE_VERSION };
    const json = JSON.stringify(doc);
    const bytes = new TextEncoder().encode(json);
    if (bytes.byteLength > MAX_BYTES.trace) return null;
    return this.stage(bytes, 'trace.json', 'application/json');
  }

  async report(input: {
    description: string;
    reportType?: 'bug' | 'feature' | 'question';
    name?: string;
    email?: string;
    route?: string;
    attachments?: StagedFile[];
  }): Promise<string | null> {
    const res = await this.authed('/api/widget/report', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        description: input.description,
        reportType: input.reportType ?? 'bug',
        ...(input.name ? { name: input.name } : {}),
        ...(input.email ? { email: input.email } : {}),
        ...(input.route ? { page: input.route } : {}),
        ...(this.opts.app ? { app: this.opts.app } : {}),
        ...(input.attachments?.length
          ? { attachments: input.attachments.map(attachmentRef) }
          : {}),
      }),
    });
    if (!res?.ok) return null;
    const json = (await res.json().catch(() => ({}))) as { issueId?: string };
    return json.issueId ?? null;
  }

  async crash(report: Omit<CrashReport, 'v'>): Promise<boolean> {
    const res = await this.authed('/api/widget/crash', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...report, v: CRASH_VERSION }),
    });
    return Boolean(res?.ok);
  }
}
