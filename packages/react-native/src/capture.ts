// The native capture surface (docs/PROTOCOL.md §2, and WIDGET_MOBILE.md §7).
//
// An INTERFACE plus a resolver, not an implementation. Everything below crosses
// to Kotlin or Swift, so the only thing this file can usefully do is define the
// contract precisely and degrade honestly when the native side is absent — a
// managed Expo app without the config plugin, a simulator, a build where the
// module was not linked.
//
// THE DEGRADATION RULE. A missing capability is reported as absent, never as a
// failure and never as a silent no-op. The panel is told which tiers this
// client can actually offer, so a reporter is never shown a Record button that
// throws the moment it is pressed — which is worse than not offering it, because
// they have already decided to spend the effort by then.
import type { AlgoWidgetClient } from './client.ts';
import type { StagedFile } from './protocol.ts';

/** What the native module exposes. Structural, so this file needs no
 *  react-native import and stays testable on a laptop. */
export interface NativeCapture {
  /** A PNG of the app's own window. No permission, no consent dialog, and it
   *  cannot see another app — which is why it is the default evidence rather
   *  than a recording. */
  screenshot(): Promise<string | null>;

  /** Start microphone capture. Resolves to a file path.
   *
   *  `.m4a` by contract: AAC-in-MP4 is what both platforms write natively AND
   *  what the transcription service accepts by name, so a voice note reaches a
   *  transcript with no re-encode anywhere. */
  startVoice(): Promise<string>;
  stopVoice(): Promise<string | null>;

  /**
   * Start screen capture.
   *
   * On Android this shows the system consent dialog and starts a foreground
   * service — the platform's requirements, not ours, and both are visible to
   * the user by design. On iOS it is ReplayKit's in-app recorder, which
   * captures THIS APP ONLY.
   *
   * That asymmetry is real and is surfaced through {@link CaptureInfo.wholeDevice}
   * rather than smoothed over: a reporter on Android is about to record
   * everything on screen, and telling them so is the difference between consent
   * and a surprise.
   */
  startScreen(withMicrophone: boolean): Promise<void>;
  stopScreen(): Promise<string | null>;

  /** Delete everything this SDK has written to disk. Cancel must guarantee
   *  both that nothing recorded left the device AND that nothing stays on it. */
  purge(): Promise<void>;

  /** What this device/build can actually do, asked once at init. */
  info(): Promise<CaptureInfo>;
}

export interface CaptureInfo {
  canScreenshot: boolean;
  canRecordVoice: boolean;
  canRecordScreen: boolean;
  /** True when a screen recording captures the whole device rather than just
   *  this app (Android). The panel says so before the reporter starts. */
  wholeDevice: boolean;
}

/** Nothing is available. What an app gets when the native module is not linked
 *  — a managed Expo build without the config plugin, a bare simulator. */
export const NO_CAPTURE: CaptureInfo = {
  canScreenshot: false,
  canRecordVoice: false,
  canRecordScreen: false,
  wholeDevice: false,
};

/**
 * Find the native module, or null.
 *
 * Deliberately tolerant: `NativeModules` may be absent (a test, a web target),
 * present-but-empty (module not linked), or present with an older shape (an app
 * updated the JS and not the native side). All three mean the same thing to a
 * reporter — some tiers are not on offer — and none of them is worth an
 * exception at import time.
 */
export function resolveNativeCapture(nativeModules?: Record<string, unknown>): NativeCapture | null {
  const modules =
    nativeModules ??
    (globalThis as { nativeModuleProxy?: Record<string, unknown> }).nativeModuleProxy;
  const mod = modules?.AlgoWidgetCapture as Partial<NativeCapture> | undefined;
  if (!mod || typeof mod.info !== 'function') return null;
  return mod as NativeCapture;
}

/**
 * What this client can offer, as the frame needs it.
 *
 * ANDed with the portal's own tiers by the caller: a portal that never enabled
 * voice must not be overridden by a device that happens to have a microphone,
 * and a device without one must not be shown a tier the portal did enable.
 */
export async function capabilitiesOf(native: NativeCapture | null): Promise<CaptureInfo> {
  if (!native) return NO_CAPTURE;
  try {
    return await native.info();
  } catch {
    // A module that throws when asked what it can do cannot be trusted to do
    // any of it.
    return NO_CAPTURE;
  }
}

/**
 * Stage a captured file and hand back the ref, or null.
 *
 * The extension decides everything downstream — the size cap, the stored
 * content type, whether the transcription service will even look at it — so it
 * is taken from the path the native side produced rather than guessed.
 */
export async function stageCaptured(
  client: AlgoWidgetClient,
  path: string,
  readFile: (path: string) => Promise<Uint8Array>,
): Promise<StagedFile | null> {
  const filename = path.split('/').pop() || 'capture';
  let bytes: Uint8Array;
  try {
    bytes = await readFile(path);
  } catch {
    return null;
  }
  return client.stage(bytes, filename, contentTypeFor(filename));
}

/** The content type to DECLARE. The server derives the stored one from the
 *  extension regardless; this only has to agree with it. */
export function contentTypeFor(filename: string): string {
  const ext = filename.slice(filename.lastIndexOf('.') + 1).toLowerCase();
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'mp4':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case '3gp':
    case '3gpp':
      return 'video/3gpp';
    default:
      return 'application/octet-stream';
  }
}
