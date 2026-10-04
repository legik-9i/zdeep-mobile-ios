import AVFoundation

enum CameraPermission {
    static func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func isAuthorized(_ status: AVAuthorizationStatus) -> Bool {
        status == .authorized
    }
}
