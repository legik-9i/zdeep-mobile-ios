import AVFoundation
import Testing
@testable import ZDEEP

struct CameraPermissionTests {
    @Test func test_permission_states_are_reported_without_requesting_access() {
        for status in [AVAuthorizationStatus.notDetermined, .authorized, .denied, .restricted] {
            #expect(CameraPermission.isAuthorized(status) == (status == .authorized))
        }
    }

    @Test func test_scanner_completion_is_delivered_once() {
        let gate = ScannerResultGate()
        var results: [String] = []

        gate.finish(.success("first")) { results.append(try! $0.get()) }
        gate.finish(.success("second")) { results.append(try! $0.get()) }

        #expect(results == ["first"])
    }

    @Test func test_scanner_completion_after_cancel_is_ignored() {
        let gate = ScannerResultGate()
        var results: [String] = []
        gate.cancel()
        gate.finish(.success("late")) { results.append(try! $0.get()) }

        #expect(results.isEmpty)
    }

}
