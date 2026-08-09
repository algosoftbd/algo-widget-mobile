// What the report panel DOES, as opposed to what it looks like.
//
// The WebView component around this is a shell: it renders a view, forwards
// messages in, and evaluates the JavaScript this returns. Everything that can
// actually be wrong — the init payload, the recording lifecycle, staging a
// capture, the countdown, what happens when the reporter cancels — lives here,
// where it can be driven message-by-message in a test with no device.
//
// THE RULE THIS FILE EXISTS TO KEEP: a reporter who cancels must be able to
// believe that nothing they recorded left the phone, and nothing stayed on it.
// `cancel` therefore discards the trace, stops the capture AND purges the bytes,
// in that order, before the panel is told.
import type { AlgoWidget } from './algoWidget.ts';
import type { NativeCapture } from './capture.ts';
import { contentTypeFor, stageCaptured } from './capture.ts';
import {
  attachmentMessage,
  parseFrameMessage,
  postToFrame,
  recordResult,
  recordTick,
  type FrameMessage,
  type RecordMode,
} from './frameBridge.ts';

export interface PanelDeps {
  widget: AlgoWidget;
  native: NativeCapture | null;
  /** Read a file the native side produced. Injected so this module needs no
   *  filesystem package — an app already has one. */
  readFile: (path: string) => Promise<Uint8Array>;
  /** Evaluate JavaScript in the WebView. The component wires this to its ref. */
  send: (js: string) => void;
  /** Prefilled, editable, never trusted. */
  identity?: { name?: string; email?: string };
  onClose?: () => void;
  onSubmitted?: (issueId: string | null) => void;
  /** The panel wants the whole screen (the annotation editor does). The host
   *  decides what that means for its own layout. */
  onFullscreen?: (on: boolean) => void;
  onHeight?: (height: number) => void;
  /** Ticks are driven by the host, so this module owns no timer and no test
   *  has to wait on one. */
  now?: () => number;
}

/** How often the countdown the reporter watches is refreshed. One second,
 *  because the panel renders `2:31 left` and anything finer is invisible. */
export const TICK_MS = 1_000;

export class PanelSession {
  private readonly deps: PanelDeps;
  private mode: RecordMode | null = null;

  constructor(deps: PanelDeps) {
    this.deps = deps;
  }

  /** True while a recording is running — the host drives ticks only then. */
  get recording(): boolean {
    return this.mode !== null;
  }

  /** Handle one raw message from the WebView. Unparseable or unknown input is
   *  ignored: the panel and the SDK version independently. */
  async handle(raw: unknown): Promise<void> {
    const message = parseFrameMessage(raw);
    if (!message) return;
    await this.dispatch(message);
  }

  private async dispatch(message: FrameMessage): Promise<void> {
    const deps = this.deps;
    switch (message.type) {
      case 'algo-widget:ready':
        await this.sendInit();
        return;
      case 'algo-widget:size':
        deps.onHeight?.(message.height);
        return;
      case 'algo-widget:fullscreen':
        deps.onFullscreen?.(message.on);
        return;
      case 'algo-widget:close':
        // Closing mid-recording is a cancel, not a pause. The panel is gone;
        // leaving a capture running would keep the platform's recording
        // indicator on with nothing to stop it.
        if (this.recording) await this.stopRecording({ cancel: true });
        deps.onClose?.();
        return;
      case 'algo-widget:snip-request':
        await this.screenshot();
        return;
      case 'algo-widget:record-start':
        await this.startRecording(message.mode);
        return;
      case 'algo-widget:record-stop':
        await this.stopRecording({ cancel: message.cancel === true });
        return;
      case 'algo-widget:submitted':
        deps.onSubmitted?.(message.issueId ?? null);
        return;
    }
  }

  /**
   * Everything the panel needs to render itself and submit.
   *
   * The TICKET goes across, because the panel calls the staging and report
   * routes itself — it is a page on the OS origin, so the ticket never enters
   * the customer's own JavaScript, which is the same trust boundary the web
   * widget uses.
   *
   * A session that cannot be minted is not an error to show a reporter: the
   * panel is told there is no portal and renders its unavailable state, and the
   * host should not have opened it in the first place (`widget.available`).
   */
  private async sendInit(): Promise<void> {
    const { widget, identity, send } = this.deps;
    const ticket = await widget.client.session().catch(() => null);
    const offered = widget.offeredModes;
    send(
      postToFrame({
        type: 'algo-widget:init',
        ...(ticket ? { token: ticket.token, exp: ticket.exp } : {}),
        page: widget.nav.currentRoute(),
        // The tiers the panel may offer are OURS, not the portal's raw list: a
        // device without a microphone must not be shown a voice tier the portal
        // happens to allow.
        portal: ticket
          ? { ...ticket.portal, recordingModes: offered, recordingEnabled: offered.length > 0 }
          : null,
        ...(identity ? { identity } : {}),
      }),
    );
  }

  private async screenshot(): Promise<void> {
    const { native, widget, readFile, send } = this.deps;
    const path = await native?.screenshot().catch(() => null);
    if (!path) {
      send(postToFrame({ type: 'algo-widget:snip-error' }));
      return;
    }
    const staged = await stageCaptured(widget.client, path, readFile);
    if (!staged) {
      send(postToFrame({ type: 'algo-widget:snip-error' }));
      return;
    }
    send(postToFrame(attachmentMessage(staged, 'image')));
  }

  private async startRecording(mode: RecordMode): Promise<void> {
    const { widget, native, send } = this.deps;
    // Never start a tier this client cannot finish. The panel filters on what
    // init advertised, but a stale panel or a permission revoked since is
    // exactly the case this guard is for.
    if (!widget.offeredModes.includes(mode)) {
      send(postToFrame(recordResult({ error: 'that recording option is not available' })));
      return;
    }
    try {
      if (mode === 'voice') await native?.startVoice();
      if (mode === 'screen') await native?.startScreen(true);
    } catch {
      send(postToFrame(recordResult({ error: 'the recording could not be started' })));
      return;
    }
    this.mode = mode;
    widget.recorder.start(widget.nav.currentRoute());
    send(postToFrame({ type: 'algo-widget:record-started', mode }));
  }

  /** Refresh the countdown. Called by the host on an interval — this module
   *  owns no timer, so no test has to wait on one. */
  tick(): void {
    if (!this.recording) return;
    const { widget, send } = this.deps;
    const rec = widget.recorder;
    send(postToFrame(recordTick(rec.remainingMs, rec.eventCount)));
    // The recorder stops ITSELF at the portal's cap; the panel has to be told,
    // or the reporter watches a frozen countdown on a recording that ended.
    if (!rec.isRecording) void this.stopRecording({ cancel: false, auto: true });
  }

  private async stopRecording(opts: { cancel: boolean; auto?: boolean }): Promise<void> {
    const { widget, native, readFile, send } = this.deps;
    const mode = this.mode;
    this.mode = null;
    if (!mode) return;

    // Stop the capture FIRST, whatever else happens. A running MediaProjection
    // keeps the system's recording indicator on, which tells the user something
    // is being captured when nothing is.
    let path: string | null = null;
    try {
      if (mode === 'voice') path = await native?.stopVoice() ?? null;
      if (mode === 'screen') path = await native?.stopScreen() ?? null;
    } catch {
      path = null;
    }
    if (opts.cancel) {
      // Order matters and is the whole promise: discard the trace, then delete
      // the bytes, then tell the panel. A reporter who cancels is entitled to
      // believe nothing left the phone AND nothing stayed on it.
      widget.recorder.cancel();
      await native?.purge().catch(() => undefined);
      send(postToFrame(recordResult({ cancel: true })));
      return;
    }

    const trace = widget.recorder.stop();
    const staged = await widget.client.stageTrace(trace);
    if (staged) send(postToFrame(attachmentMessage(staged, 'trace')));

    if (path) {
      const media = await stageCaptured(widget.client, path, readFile);
      if (media) {
        send(postToFrame(attachmentMessage(media, mode === 'voice' ? 'audio' : 'video')));
      }
    }
    send(postToFrame(recordResult({})));
    // The bytes are staged; the local copies are not needed and must not
    // outlive the report.
    await native?.purge().catch(() => undefined);
  }

  /** The panel is going away. Same guarantee as cancel. */
  async dispose(): Promise<void> {
    if (this.recording) await this.stopRecording({ cancel: true });
  }
}

/** Re-exported so a host wiring its own component does not have to reach for
 *  two modules to declare one file's content type. */
export { contentTypeFor };
