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

    @MainActor
    @Test func preparedDiagnosticSessionPublishesHandshakeAndResetClosesMailboxBeforeCleanup() async throws {
        let manager = DiagnosticLaunchSessionManager()
        let handshake = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZdeepDiagnostics/session.json")
        try? FileManager.default.removeItem(at: handshake)
        let filesAdapter = DiagnosticCleanupProbe { !FileManager.default.fileExists(atPath: handshake.path) }
        let adapters: [OwnedDataCategory: any OwnedDataCategoryCleaning] = [
            .keychain: DiagnosticCleanupProbe(),
            .files: filesAdapter,
            .preferences: DiagnosticCleanupProbe(),
            .webData: DiagnosticCleanupProbe()
        ]
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(
                arguments: ["--environment", "local", "--usb-diagnostics", "--web-url", "http://127.0.0.1:1"],
                variables: [:]
            ),
            bindingStore: DiagnosticLaunchBindingStore(),
            sessionManager: manager,
            ownedClientDataCleaner: OwnedClientDataCleaner(adapters: adapters)
        )
        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }

        let prepared = try #require(coordinator.activeWebSession)
        let statusData = try await waitForHandshake(at: handshake, sessionID: prepared.id.uuidString.lowercased())
        let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        #expect(status?["ready"] as? Bool == true)
        #expect(!coordinator.isWebViewOpen)

        await coordinator.resetClientData()

        #expect(prepared.isClosed)
        #expect(await filesAdapter.probePassed)
    }

    @MainActor
    @Test func switchingFromDiagnosticLocalToProdDoesNotStartMailboxForProdWebSession() async throws {
        let handshake = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZdeepDiagnostics/session.json")
        try? FileManager.default.removeItem(at: handshake)
        let configuration = LaunchConfiguration(
            arguments: ["--environment", "local", "--usb-diagnostics", "--web-url", "http://127.0.0.1:1"],
            variables: [:]
        )
        #expect(configuration.usbDiagnosticsEnabled)
        #expect(configuration.isUSBDiagnosticsEnabled(in: .local))
        #expect(!configuration.isUSBDiagnosticsEnabled(in: .prod))
        let factory = DiagnosticEligibilityWebSessionFactory()
        let adapters: [OwnedDataCategory: any OwnedDataCategoryCleaning] = [
            .keychain: DiagnosticCleanupProbe(),
            .files: DiagnosticCleanupProbe(),
            .preferences: DiagnosticCleanupProbe(),
            .webData: DiagnosticCleanupProbe()
        ]
        let coordinator = AppCoordinator(
            configuration: configuration,
            sessionFactory: factory,
            bindingStore: DiagnosticLaunchBindingStore(),
            sessionManager: DiagnosticLaunchSessionManager(),
            ownedClientDataCleaner: OwnedClientDataCleaner(adapters: adapters)
        )
        defer {
            coordinator.closeCurrentWebSession()
            try? FileManager.default.removeItem(at: handshake)
        }

        await coordinator.switchEnvironment(to: .prod)
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        try await Task.sleep(for: .milliseconds(500))

        #expect(factory.environments == [.prod])
        #expect(factory.sessions.count == 1)
        #expect(!FileManager.default.fileExists(atPath: handshake.path))
    }

    private func waitForHandshake(at url: URL, sessionID: String) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               status["sessionId"] as? String == sessionID {
                return data
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DiagnosticMailboxLaunchTestError.handshakeTimedOut
    }
}

private enum DiagnosticMailboxLaunchTestError: Error { case handshakeTimedOut }

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
private final class DiagnosticEligibilityWebSessionFactory: WebSessionFactory {
    private(set) var environments: [AppEnvironment] = []
    private(set) var sessions: [DiagnosticLaunchWebSession] = []

    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        environments.append(environment)
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
    private(set) var closeCount = 0
    func close() { closeCount += 1 }
}

private actor DiagnosticCleanupProbe: OwnedDataCategoryCleaning {
    private let check: (@Sendable () -> Bool)?
    private(set) var probePassed = false
    init(check: (@Sendable () -> Bool)? = nil) { self.check = check }
    func clean() async throws { if let check { probePassed = check() } }
    func isEmpty() async throws -> Bool { probePassed || check == nil }
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
