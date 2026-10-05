#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import Foundation
import SwiftUI

nonisolated struct EmptyUITestBindingStore: BindingStoring {
    func restore() async throws -> RegisteredBinding? { nil }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

@MainActor
struct AuthorizationUITestHost: View {
    enum Scenario: String { case denied, authorized, registered, registeredLoading = "registered-loading" }

    @StateObject private var coordinator: AppCoordinator
    private let store: AuthorizationUITestBindingStore

    static func scenario(arguments: [String]) -> Scenario? {
        guard let index = arguments.firstIndex(of: "--ui-test-authorization"),
              arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    init(scenario: Scenario) {
        let store = AuthorizationUITestBindingStore(registered: scenario == .registered || scenario == .registeredLoading)
        self.store = store
        let manager = AuthorizationUITestSessionManager(store: store, waitsForStop: scenario == .registeredLoading)
        let permission = AuthorizationUITestCameraPermission(authorized: scenario == .authorized)
        let coordinator = AppCoordinator(
            configuration: .current,
            bindingStore: store,
            sessionManager: manager,
            cameraPermission: permission
        )
        coordinator.syntheticAuthorizationUITestEnabled = scenario == .authorized
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some View {
        ContentView(coordinator: coordinator)
            .overlay(alignment: .bottom) {
                VStack {
                    Text("pair \(store.beginCount) · complete \(store.completeCount)")
                        .accessibilityIdentifier("registration-count")
                    Text("reset \(store.resetCount)")
                        .accessibilityIdentifier("reset-count")
                }
                .font(.caption)
                .padding(4)
                .background(.regularMaterial)
            }
            .task { await coordinator.start() }
    }
}

private final class AuthorizationUITestBindingStore: BindingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var binding: RegisteredBinding?
    private var begins = 0
    private var completes = 0
    private var resets = 0

    init(registered: Bool) {
        binding = registered ? RegisteredBinding(
            bindingId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            publicCertificate: "synthetic-certificate",
            carId: "synthetic-car"
        ) : nil
    }

    var beginCount: Int { lock.withLock { begins } }
    var completeCount: Int { lock.withLock { completes } }
    var resetCount: Int { lock.withLock { resets } }

    func restore() async throws -> RegisteredBinding? { lock.withLock { binding } }
    func beginRegistration() async throws -> PendingBinding {
        lock.withLock { begins += 1 }
        return PendingBinding(bindingId: UUID(), publicCertificate: "synthetic-pending")
    }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { Data("synthetic-signature".utf8) }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding {
        lock.withLock {
            completes += 1
            let value = RegisteredBinding(bindingId: bindingId, publicCertificate: "synthetic-certificate", carId: carId)
            binding = value
            return value
        }
    }
    func reset() async throws { lock.withLock { resets += 1; binding = nil } }
}

@MainActor
private struct AuthorizationUITestCameraPermission: CameraPermissionProviding {
    let authorized: Bool
    func status() -> AVAuthorizationStatus { authorized ? .authorized : .denied }
    func requestAccess() async -> Bool { authorized }
}

@MainActor
private final class AuthorizationUITestSessionManager: SessionManaging {
    private let store: AuthorizationUITestBindingStore
    private var binding: RegisteredBinding?
    private var observers: [UUID: @MainActor (SessionManagerEvent) -> Void] = [:]
    private let waitsForStop: Bool
    private var updateContinuation: CheckedContinuation<Void, Never>?

    init(store: AuthorizationUITestBindingStore, waitsForStop: Bool) {
        self.store = store
        self.waitsForStop = waitsForStop
    }
    var currentSession: AuthSession? { nil }
    var hasPublishedSession: Bool { false }
    var lastError: AuthFailure? { failure }
    var registeredBinding: RegisteredBinding? { binding }
    var isAuthorizationInFlight: Bool { false }

    func register(binding pending: PendingBinding, carToken: String) async throws -> AuthSession {
        let registered = try await store.completeRegistration(bindingId: pending.bindingId, carId: "synthetic-car")
        binding = registered
        return session
    }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        self.binding = binding
        if waitsForStop {
            await withCheckedContinuation { updateContinuation = $0 }
        }
        throw failure
    }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        let id = UUID()
        observers[id] = observer
        return AuthorizationUITestCancellationHandle { [weak self] in self?.observers[id] = nil }
    }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {
        binding = nil
        updateContinuation?.resume()
        updateContinuation = nil
    }

    private var failure: AuthFailure {
        AuthFailure(kind: .timeout, stage: .token, attemptId: UUID(), message: "synthetic timeout", diagnosticCode: "TIMEOUT")
    }
    private var session: AuthSession {
        AuthSession(accessToken: "synthetic", userId: "synthetic", carId: "synthetic-car", expiresAt: "2099-01-01T00:00:00Z", deadline: .seconds(3600), serverTimeMs: 0, attemptId: UUID())
    }
}

@MainActor
private final class AuthorizationUITestCancellationHandle: CancellationHandle {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
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
