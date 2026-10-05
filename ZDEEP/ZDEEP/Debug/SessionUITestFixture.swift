#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import SwiftUI

nonisolated struct EmptyUITestBindingStore: BindingStoring {
    func restore() async throws -> RegisteredBinding? { nil }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

struct SessionUITestFixture: View {
    enum Configuration: String {
        case initial
        case registered
        case unknown
        case missingCode = "missing-code"
        case restore
        case cameraDenied = "camera-denied"
        case cameraRestricted = "camera-restricted"
        case loading
        case logo
    }

    let configuration: Configuration
    @State private var lastAction: String?

    static func configuration(arguments: [String]) -> Configuration? {
        guard let flagIndex = arguments.firstIndex(of: "--ui-test-presentation"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return Configuration(rawValue: arguments[flagIndex + 1])
    }

    var body: some View {
        Group {
            switch configuration {
            case .initial:
                errorView(.initialRegistrationFailure(failure()))
            case .registered:
                errorView(.retryable(failure(
                    message: "Raw response body must never be shown",
                    serverCode: "CAR_ACCESS_DENIED",
                    diagnosticCode: "HTTP_403",
                    httpStatus: 403
                ), context: .authorization(binding)))
            case .unknown:
                errorView(.initialRegistrationFailure(failure(
                    message: "Raw error body that must never be shown",
                    serverCode: "UNKNOWN_SERVER_FAILURE_CODE",
                    diagnosticCode: "HTTP_503"
                )))
            case .missingCode:
                errorView(.initialRegistrationFailure(failure(
                    message: "Raw response body must never be shown",
                    serverCode: nil,
                    diagnosticCode: "HTTP_503"
                )))
            case .restore:
                errorView(.retryable(failure(), context: .restore))
            case .cameraDenied:
                CameraPermissionView(status: .denied, onSettings: { record("SETTINGS") }, onBack: { record("BACK") })
            case .cameraRestricted:
                CameraPermissionView(status: .restricted, onSettings: { record("SETTINGS") }, onBack: { record("BACK") })
            case .loading:
                NativeLoadingView(canCancel: true, onCancel: { record("CANCEL") })
            case .logo:
                StartupLogoView()
            }
        }
        .overlay(alignment: .bottom) {
            if let lastAction {
                Text(lastAction)
                    .font(.caption)
                    .accessibilityIdentifier("fixture-action")
            }
        }
    }

    private var binding: RegisteredBinding {
        RegisteredBinding(
            bindingId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            publicCertificate: "synthetic-public-certificate",
            carId: "synthetic-car"
        )
    }

    private func errorView(_ presentation: NativeErrorPresentation) -> some View {
        NativeErrorView(
            presentation: presentation,
            onRetry: { record("RETRY") },
            onStartOver: { record("START_OVER") },
            onRebind: { record("REBIND") }
        )
    }

    private func failure(
        message: String = "Не удалось получить данные автомобиля",
        serverCode: String? = nil,
        diagnosticCode: String = "HTTP_503",
        httpStatus: Int = 503
    ) -> AuthFailure {
        AuthFailure(
            kind: .server,
            stage: .web,
            attemptId: UUID(uuidString: "D8E15186-1111-4111-8111-111111111111")!,
            message: message,
            httpStatus: httpStatus,
            serverCode: serverCode,
            diagnosticCode: diagnosticCode
        )
    }

    private func record(_ action: String) {
        lastAction = action
    }
}
#endif
