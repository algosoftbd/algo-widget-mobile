import XCTest

@testable import AlgoWidget

/// The iOS core is capture, and capture needs hardware — so these tests are
/// deliberately thin, and the real coverage lives in the Flutter and React
/// Native packages where the protocol, the recorder and the crash throttles can
/// be exercised on a laptop.
///
/// What IS worth asserting here is that the type compiles and its lifecycle is
/// safe to call in the order a host will call it, including the orders a host
/// gets wrong: `purge` before anything was written, `stopVoice` before
/// `startVoice`. Both happen in real apps — a reporter cancelling immediately
/// hits exactly this path — and neither may throw.
final class AlgoWidgetCaptureTests: XCTestCase {

    func testStopBeforeStartIsSafe() {
        let capture = AlgoWidgetCapture()
        // A reporter who opens the panel and immediately cancels produces this.
        capture.stopVoice()
    }

    func testPurgeOnAnEmptyDirectoryIsSafe() {
        let capture = AlgoWidgetCapture()
        capture.purge()
        capture.purge()
    }

    #if canImport(ReplayKit)
    func testScreenAvailabilityIsReadableWithoutStarting() {
        // Reading availability must not itself start anything: the reporter is
        // told up front whether the tier is on offer, which happens before any
        // consent dialog.
        _ = AlgoWidgetCapture().canRecordScreen
    }
    #endif
}
