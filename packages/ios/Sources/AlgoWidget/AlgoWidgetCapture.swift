import AVFoundation
import Foundation
#if canImport(ReplayKit)
import ReplayKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Native capture for the Algo Widget (docs/PROTOCOL.md).
///
/// THE SCOPE RULE FOR THIS FILE: only what cannot be done above the platform.
/// The interaction trace, the wire protocol, the crash throttles and the report
/// UI all live in the Flutter and React Native packages, where they can be
/// tested without a device.
///
/// iOS is the better-behaved of the two platforms here, and in one specific way
/// that is worth stating because it inverts the web situation: ReplayKit's
/// in-app recorder captures **this app only**. On the web, iOS Safari has no
/// screen capture at all, so the widget's recording tiers degrade there. Natively
/// it is the opposite — an iOS recording is narrower and safer than an Android
/// one, which captures the whole device.
///
/// What the platform still decides:
///  - the system asks for microphone permission, and `NSMicrophoneUsageDescription`
///    must exist in the host's Info.plist or the app hard-crashes on first use.
///    That is a missing string, not a denied permission, and it is the single
///    most common integration failure;
///  - `RPScreenRecorder` refuses while another app is recording or mirroring.
public final class AlgoWidgetCapture {

    public init() {}

    /// Where recordings land. App-private by construction: nothing this SDK
    /// writes is readable by another app, and nothing leaves the device until
    /// the reporter presses Send.
    private var outputDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("algo-widget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var audioRecorder: AVAudioRecorder?

    // MARK: - Voice

    /// Audio-only narration.
    ///
    /// `.m4a` deliberately: AAC-in-MP4 is what `AVAudioRecorder` writes natively
    /// AND what the transcription service accepts by name, so a voice note makes
    /// it from the phone to a transcript with no re-encode anywhere.
    ///
    /// Throws rather than returning nil: a failure here has a cause the host
    /// should surface in logs (usually a missing usage description), and
    /// swallowing it produces a Record button that silently does nothing.
    @discardableResult
    public func startVoice() throws -> URL {
        let url = outputDirectory.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        #if canImport(UIKit)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        audioRecorder = recorder
        return url
    }

    public func stopVoice() {
        audioRecorder?.stop()
        audioRecorder = nil
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: - Screen

    #if canImport(ReplayKit)
    /// Whether a recording can start right now.
    ///
    /// `isAvailable` is false while another app records or mirrors the screen,
    /// and a reporter told "not available" up front is better served than one
    /// whose Record button fails silently.
    public var canRecordScreen: Bool {
        RPScreenRecorder.shared().isAvailable
    }

    /// Start an in-app screen recording.
    ///
    /// `startCapture` rather than a broadcast extension: it records THIS app
    /// only, needs no extension target in the host's project, and cannot see
    /// another app. A broadcast extension would capture the whole device — the
    /// Android behaviour — for a feature that only ever needs to show what the
    /// reporter's own app did.
    ///
    /// `microphoneEnabled` follows the tier the reporter picked; it is never set
    /// on their behalf.
    public func startScreen(
        microphoneEnabled: Bool,
        handler: @escaping (CMSampleBuffer, RPSampleBufferType) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = microphoneEnabled
        recorder.startCapture(handler: { buffer, type, error in
            if error == nil { handler(buffer, type) }
        }, completionHandler: completion)
    }

    public func stopScreen(completion: @escaping (Error?) -> Void) {
        RPScreenRecorder.shared().stopCapture(handler: completion)
    }
    #endif

    // MARK: - Screenshot

    #if canImport(UIKit)
    /// A screenshot of the host's own window.
    ///
    /// Not ReplayKit: this needs no permission and no consent flow at all, and
    /// it cannot see another app. A screenshot is the cheapest useful evidence
    /// there is, and making it cost a recording flow would mean most reporters
    /// attach nothing.
    ///
    /// Returns nil rather than throwing — evidence going missing must never
    /// block a report.
    public func screenshot() -> URL? {
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else { return nil }
        let url = outputDirectory.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - Teardown

    /// Delete everything this SDK has written. Cancel must guarantee that
    /// nothing recorded ever left the device — and that nothing stays on it.
    public func purge() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? fm.removeItem(at: url) }
    }
}
