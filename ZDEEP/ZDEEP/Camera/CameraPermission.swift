import AVFoundation

@MainActor
protocol CameraPermissionProviding {
    func status() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

@MainActor
struct SystemCameraPermissionProvider: CameraPermissionProviding {
    func status() -> AVAuthorizationStatus { CameraPermission.status() }
    func requestAccess() async -> Bool { await CameraPermission.requestAccess() }
}

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
