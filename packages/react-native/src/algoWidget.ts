// The public façade — `AlgoWidget.init(...)` and the handful of calls an app
// author is expected to hold in their head.
//
// Everything underneath is separately usable, and deliberately so: an app with
// its own navigation shape or its own crash reporter can take the recorder and
// the client and leave this alone. This is the ninety-percent path, not the
// only one.
import { AlgoWidgetClient, type ClientOptions } from './client.ts';
import { CrashReporter, type CrashStore } from './crash.ts';
import { TraceRecorder } from './recorder.ts';
import { bindAll, makeNavigationTracker, type Sinks, type Unbind } from './bindings.ts';
import { capabilitiesOf, resolveNativeCapture, type CaptureInfo, type NativeCapture } from './capture.ts';
import type { AppFacts, PortalConfig, StagedFile } from './protocol.ts';

export interface InitOptions extends Omit<ClientOptions, 'platform'> {
  /** Absent ⇒ read from React Native's Platform.OS at call time. Passed
   *  explicitly in tests and in any host that already knows. */
  platform?: 'android' | 'ios';
  /** Where crash reports wait for the next launch. Injected rather than
   *  imported so this package needs no AsyncStorage dependency — an app already
   *  has a storage layer, and forcing a second one on it is rude. */
  crashStore?: CrashStore;
  /** The host's kill switch, checked on every crash. Absent ⇒ on, matching the
   *  portal default, but the host's `false` always wins. */
  crashCaptureEnabled?: () => boolean;
  /** Prefilled, editable, never trusted. */
  identity?: { name?: string; email?: string };
  native?: NativeCapture | null;
}

/**
 * The whole SDK, wired.
 *
 * `init` never throws and never rejects. A portal that refuses us, a device
 * with no native module, a network that is down — each of those means some part
 * of the widget is unavailable, and the correct response to all of them is the
 * same: report less, hide the entry point, and let the app get on with being an
 * app. An SDK that can break a customer's launch path is not one they can ship.
 */
export class AlgoWidget {
  readonly client: AlgoWidgetClient;
  readonly recorder: TraceRecorder;
  readonly crash: CrashReporter | null;
  readonly nav: ReturnType<typeof makeNavigationTracker>;
  readonly capabilities: CaptureInfo;
  private readonly unbind: Unbind;

  // Fields rather than TypeScript parameter properties: `node --test
  // --experimental-strip-types` runs these sources with no build step, and
  // strip-only mode cannot desugar a parameter property. Keeping the tests
  // buildless is worth six lines.
  private constructor(parts: {
    client: AlgoWidgetClient;
    recorder: TraceRecorder;
    crash: CrashReporter | null;
    nav: ReturnType<typeof makeNavigationTracker>;
    capabilities: CaptureInfo;
    unbind: Unbind;
  }) {
    this.client = parts.client;
    this.recorder = parts.recorder;
    this.crash = parts.crash;
    this.nav = parts.nav;
    this.capabilities = parts.capabilities;
    this.unbind = parts.unbind;
  }

  static async init(opts: InitOptions): Promise<AlgoWidget> {
    const platform = opts.platform ?? detectPlatform();
    const native = opts.native === undefined ? resolveNativeCapture() : opts.native;
    const capabilities = await capabilitiesOf(native);

    const client = new AlgoWidgetClient({ ...opts, platform });
    // One round trip up front, so the portal's config — the tiers on offer, the
    // recording cap, whether crash capture is on at all — is known before the
    // reporter can press anything. A null ticket is not an error here: it means
    // the entry point stays hidden.
    const ticket = await client.session().catch(() => null);
    const portal: PortalConfig | null = ticket?.portal ?? null;

    const recorder = new TraceRecorder({
      platform,
      framework: 'react_native',
      maxSeconds: portal?.recordingMaxSeconds ?? 300,
    });

    // Crash capture needs somewhere to persist. Without a store the reports
    // would be built on a dying process and immediately lost, so the feature is
    // OFF rather than pretending — the same absent-means-off rule the portal
    // flag follows.
    const nav = makeNavigationTracker({ recorder });
    const crash =
      opts.crashStore && portal?.crashCapture !== false
        ? new CrashReporter({
            store: opts.crashStore,
            currentRoute: nav.currentRoute,
            ...(opts.app ? { app: () => opts.app as AppFacts } : {}),
            ...(opts.crashCaptureEnabled ? { enabled: opts.crashCaptureEnabled } : {}),
          })
        : null;

    const sinks: Sinks = { recorder, ...(crash ? { crash } : {}) };
    const unbind = bindAll(sinks);

    const widget = new AlgoWidget({ client, recorder, crash, nav, capabilities, unbind });
    // Anything a previous launch persisted goes now — a crash report is worth
    // most when it arrives before the user hits the same wall again.
    if (crash) void crash.flush((report) => client.crash(report)).catch(() => 0);
    return widget;
  }

  /** Whether the widget can be opened at all. False when the portal refused the
   *  session — the host should hide its report entry point rather than show one
   *  that fails. */
  get available(): boolean {
    return this.client.portal !== null;
  }

  /** Which recording tiers to actually offer: the portal's, ANDed with what
   *  this device can do. A portal that never enabled voice is not overridden by
   *  a microphone, and a portal that did is not offered on a device without one. */
  get offeredModes(): ('steps' | 'voice' | 'screen')[] {
    const portal = this.client.portal;
    if (!portal?.recordingEnabled) return [];
    return portal.recordingModes.filter((m) => {
      if (m === 'steps') return true;
      if (m === 'voice') return this.capabilities.canRecordVoice;
      return this.capabilities.canRecordScreen;
    });
  }

  /** The route the reporter is on. Feed this from the app's navigation. */
  onRouteChange(route: string, cause: 'user' | 'app' = 'user'): void {
    this.nav.onRouteChange(route, cause);
  }

  /** Submit. Returns the issue id, or null when it could not be filed —
   *  callers show the reporter a failure, never a stack. */
  async report(input: {
    description: string;
    reportType?: 'bug' | 'feature' | 'question';
    name?: string;
    email?: string;
    attachments?: StagedFile[];
  }): Promise<string | null> {
    return this.client.report({ ...input, route: this.nav.currentRoute() });
  }

  /** Remove every global patch this SDK installed. Rarely needed in an app;
   *  essential in a test, and in a host that swaps portals at runtime. */
  dispose(): void {
    this.recorder.cancel();
    this.unbind();
  }
}

/** React Native's `Platform.OS`, read defensively — this module must import
 *  nothing from react-native so it stays testable on a laptop. */
function detectPlatform(): 'android' | 'ios' {
  const p = (globalThis as { Platform?: { OS?: string } }).Platform?.OS;
  return p === 'ios' ? 'ios' : 'android';
}
