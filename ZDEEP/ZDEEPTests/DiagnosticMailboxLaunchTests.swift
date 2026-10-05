import Foundation
import Combine
import Testing
@testable import ZDEEP

struct DiagnosticMailboxLaunchTests {
    @Test func diagnosticWebViewAutoOpenRequiresTheDedicatedExplicitFlag() {
        let optedIn = LaunchConfiguration(
            arguments: ["--environment", "local", "--usb-diagnostics"],
            variables: [:]
        )
        let explicitOpen = LaunchConfiguration(
            arguments: ["--environment", "local", "--usb-diagnostics", "--usb-diagnostics-open-webview"],
            variables: [:]
        )
        let withoutDiagnostics = LaunchConfiguration(arguments: ["--environment", "local"], variables: [:])

        #expect(optedIn.usbDiagnosticsEnabled)
        #expect(!optedIn.usbDiagnosticsOpenWebViewEnabled)
        #expect(explicitOpen.usbDiagnosticsOpenWebViewEnabled)
        #expect(!withoutDiagnostics.usbDiagnosticsOpenWebViewEnabled)
    }

    @MainActor
    @Test func explicitDiagnosticOpenFlagNeverRevealsOrBypassesAuthorization() async {
        let factory = DiagnosticLaunchWebSessionFactory()
        let manager = DiagnosticLaunchSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(
                arguments: ["--environment", "local", "--usb-diagnostics", "--usb-diagnostics-open-webview"],
                variables: [:]
            ),
            sessionFactory: factory,
            bindingStore: DiagnosticLaunchBindingStore(),
            sessionManager: manager
        )

        #expect(factory.sessions.isEmpty)
        #expect(!coordinator.isWebViewOpen)
        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }

        #expect(factory.sessions.count == 1)
        #expect(!coordinator.isWebViewOpen)
        #expect(manager.updateCount == 0)
    }
}

@MainActor
private final class DiagnosticLaunchWebSessionFactory: WebSessionFactory {
    private(set) var sessions: [DiagnosticLaunchWebSession] = []
    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        let session = DiagnosticLaunchWebSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class DiagnosticLaunchWebSession: WebSessionHandle, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let id = UUID()
    var currentURL: URL? { nil }
    var isLoading = false
    var navigationError: String? { nil }
    func close() {}
}

private struct DiagnosticLaunchBindingStore: BindingStoring {
    func restore() async throws -> RegisteredBinding? { nil }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

@MainActor
private final class DiagnosticLaunchSessionManager: SessionManaging {
    var currentSession: AuthSession?
    var hasPublishedSession = false
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    private(set) var updateCount = 0
    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession { throw BindingStoreError.registrationNotAllowed }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession { updateCount += 1; throw BindingStoreError.registrationNotAllowed }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle { DiagnosticLaunchCancellation() }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {}
}

@MainActor
private final class DiagnosticLaunchCancellation: CancellationHandle {
    func cancel() {}
}
