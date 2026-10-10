import Foundation
import Network
import Testing
import AVFoundation
import WebKit
@testable import ZDEEP

@MainActor
extension WebSessionIntegrationTests {
    private var localLaunchConfiguration: LaunchConfiguration {
        LaunchConfiguration(
            arguments: ["--environment", AppEnvironment.local.rawValue],
            variables: ProcessInfo.processInfo.environment
        )
    }

    @Test func test_local_http_auth_failure_retry_and_invalid_response() async throws {
        let success = try LocalAuthFixture.successBody(carId: "local-http-car", serverTime: 1_000_000, exp: 1_900)
        let server = try LocalAuthHTTPFixture(responses: [
            (403, Data(#"{"code":"UNKNOWN_SERVER_CODE"}"#.utf8)),
            (200, success),
            (200, Data("not-json".utf8))
        ])
        let backend = try await server.start()
        let service = "ru.zdeep.tests.auth.http.\(UUID().uuidString)"
        let keychain = KeychainBindingRecordStorage(service: service)
        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zdeep-local-http-\(UUID().uuidString)", isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: markerRoot.appendingPathComponent("install.marker"))
        defer { try? keychain.delete(); try? marker.remove(); try? FileManager.default.removeItem(at: markerRoot) }

        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        _ = try await store.restore()
        let pending = try await store.beginRegistration()
        let binding = try await store.completeRegistration(bindingId: pending.bindingId, carId: "local-http-car")
        let clock = TestSessionClock(wallTimeMs: 1_000_000)
        let client = AuthClient(bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
                                endpoints: EnvironmentEndpoints(web: AppEnvironment.local.endpoints.web, backend: backend))

        do {
            _ = try await client.token(binding: binding)
            Issue.record("Expected local HTTP 403")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .server)
            #expect(failure.httpStatus == 403)
            #expect(failure.serverCode == "UNKNOWN_SERVER_CODE")
        }
        let refreshed = try await client.token(binding: binding)
        #expect(refreshed.carId == binding.carId)
        do {
            _ = try await client.token(binding: binding)
            Issue.record("Expected malformed local HTTP response to fail")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.diagnosticCode == "BAD_RESPONSE")
        }
        #expect(server.requestCount == 3)

        server.stop()
        do {
            _ = try await client.token(binding: binding)
            Issue.record("Expected an offline local fixture to fail")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .network)
            #expect(failure.diagnosticCode == "NETWORK")
        }
        #expect(server.requestCount == 3)
    }

    @Test func test_local_binding_to_real_web_ready() async throws {
        let service = "ru.zdeep.tests.auth.flow.\(UUID().uuidString)"
        let keychain = KeychainBindingRecordStorage(service: service)
        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zdeep-local-flow-\(UUID().uuidString)", isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: markerRoot.appendingPathComponent("install.marker"))
        defer {
            try? keychain.delete()
            try? marker.remove()
            try? FileManager.default.removeItem(at: markerRoot)
        }

        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        let configuration = localLaunchConfiguration
        let clock = ContinuousSessionClock()
        let client = AuthClient(bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
                                endpoints: configuration.endpoints(for: .local))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        let coordinator = AppCoordinator(configuration: configuration, bindingStore: store, sessionManager: manager,
                                         cameraPermission: LocalAuthCameraPermission(), sessionClock: clock)
        defer { coordinator.closeCurrentWebSession(); manager.stop() }
        await coordinator.start()
        if case .welcome = coordinator.screen { } else { Issue.record("Expected welcome after empty restore") }

        await coordinator.beginCameraScan()
        if case .scanner = coordinator.screen { } else { Issue.record("Expected scanner after local permission fixture") }
        let scenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenario)

        // Keep this fresh token in memory only; the QR uses the local agent URL shape.
        let carToken = try await LocalAuthFixture.fetchFreshCarToken(backend: configuration.endpoints(for: .local).backend)
        var qr = URLComponents(string: "http://localhost/auth/get-otp")!
        qr.queryItems = [URLQueryItem(name: "token", value: carToken)]
        await coordinator.scannerDidProduce(try #require(qr.url?.absoluteString))

        let deadline = ContinuousClock.now + .seconds(75)
        while !coordinator.isWebViewOpen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if case .error = coordinator.screen { Issue.record("Local registration or web preparation failed") ; break }
        }
        #expect(coordinator.isWebViewOpen)
        let binding = try #require(coordinator.restoredBinding)
        #expect(binding.carId == "e0f1c2b3-ce9d-4e0a-95e3-fe4bf1f519f6")
        let web = try #require(coordinator.activeWebSession)
        let preparedContainerId = web.id
        let identity = try #require(coordinator.readinessIdentity)
        #expect(identity.containerId == preparedContainerId)
        #expect(coordinator.currentCommittedDocument == identity)
        let bridgeReply = try await web.executeJavaScript("window.ZdeepNative.getSession().then(session => session.carId)", timeout: .seconds(10))
        #expect(bridgeReply == .string(binding.carId))

        await coordinator.resetBindingAndShowWelcome()
        if case .welcome = coordinator.screen { } else { Issue.record("Rebind reset did not return to welcome") }
        await coordinator.beginCameraScan()
        let rebindScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: rebindScenario)
        // A rebind is a second independent registration, so request a second fresh local token.
        let rebindCarToken = try await LocalAuthFixture.fetchFreshCarToken(backend: configuration.endpoints(for: .local).backend)
        var rebindQR = URLComponents(string: "http://localhost/auth/get-otp")!
        rebindQR.queryItems = [URLQueryItem(name: "token", value: rebindCarToken)]
        await coordinator.scannerDidProduce(try #require(rebindQR.url?.absoluteString))
        let rebindDeadline = ContinuousClock.now + .seconds(75)
        while !coordinator.isWebViewOpen, ContinuousClock.now < rebindDeadline {
            try await Task.sleep(for: .milliseconds(100))
            if case .error = coordinator.screen { Issue.record("Local rebind or web preparation failed") ; break }
        }
        let rebound = try #require(coordinator.restoredBinding)
        let reboundWeb = try #require(coordinator.activeWebSession)
        #expect(rebound.carId == binding.carId)
        #expect(rebound.bindingId != binding.bindingId)
        #expect(rebound.publicCertificate != binding.publicCertificate)
        #expect(reboundWeb.id != preparedContainerId)

        let restoringManager = SessionManager(bindingStore: store,
            authClient: AuthClient(bindingStore: store, transport: URLSessionAuthHTTPTransport(),
                                   clock: clock, endpoints: configuration.endpoints(for: .local)), clock: clock)
        let restoring = AppCoordinator(configuration: configuration, bindingStore: store,
                                       sessionManager: restoringManager, cameraPermission: LocalAuthCameraPermission(),
                                       sessionClock: clock)
        defer { restoring.closeCurrentWebSession(); restoringManager.stop() }
        await restoring.start()
        if case .loading = restoring.screen { } else { Issue.record("Registered restore should remain on loading before token/web completion") }
        if case .welcome = restoring.screen { Issue.record("Registered restore flashed welcome") }
    }

    @Test func test_local_ordinary_binding_reset_preserves_observed_web_data() async throws {
        let fixtureID = UUID().uuidString.lowercased()
        let storageKey = "__zdeep_ordinary_reset_\(fixtureID)"
        let cookieName = "zdeep_ordinary_reset_\(fixtureID)"
        let configuration = localLaunchConfiguration
        let url = configuration.endpoints(for: .local).web
        let seedSession = WebSession(trustedURL: url)
        defer { seedSession.close() }
        seedSession.load(url: url)
        _ = try await seedSession.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(60))
        let seeded = try await seedSession.executeJavaScript(
            "localStorage.setItem('\(storageKey)', 'observed'); document.cookie = '\(cookieName)=observed; path=/'; true",
            timeout: .seconds(10)
        )
        #expect(seeded == .bool(true))
        seedSession.close()

        let service = "ru.zdeep.tests.auth.cache.\(UUID().uuidString)"
        let keychain = KeychainBindingRecordStorage(service: service)
        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zdeep-cache-reset-\(UUID().uuidString)", isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: markerRoot.appendingPathComponent("install.marker"))
        defer { try? keychain.delete(); try? marker.remove(); try? FileManager.default.removeItem(at: markerRoot) }
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        let coordinator = AppCoordinator(configuration: configuration, bindingStore: store)
        await coordinator.start()
        await coordinator.resetBindingAndShowWelcome()
        if case .welcome = coordinator.screen { } else { Issue.record("Ordinary binding reset did not return to welcome") }

        let observedSession = WebSession(trustedURL: url)
        defer {
            Task { @MainActor in
                _ = try? await observedSession.executeJavaScript(
                    "localStorage.removeItem('\(storageKey)'); document.cookie = '\(cookieName)=; Max-Age=0; path=/'; true",
                    timeout: .seconds(5)
                )
                observedSession.close()
            }
        }
        observedSession.load(url: url)
        _ = try await observedSession.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(60))
        let survives = try await observedSession.executeJavaScript(
            "localStorage.getItem('\(storageKey)') === 'observed' && document.cookie.includes('\(cookieName)=observed')",
            timeout: .seconds(10)
        )
        #expect(survives == .bool(true))
    }

    @Test func test_local_pair_then_token_accepts_spki_and_der_signature() async throws {
        let service = "ru.zdeep.tests.auth.\(UUID().uuidString)"
        let keychain = KeychainBindingRecordStorage(service: service)
        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zdeep-local-auth-\(UUID().uuidString)", isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: markerRoot.appendingPathComponent("install.marker"))
        defer {
            try? keychain.delete()
            try? marker.remove()
            try? FileManager.default.removeItem(at: markerRoot)
        }

        let configuration = localLaunchConfiguration
        let carToken = try await LocalAuthFixture.fetchFreshCarToken(backend: configuration.endpoints(for: .local).backend)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)
        let pending = try await store.beginRegistration()
        // Force one server clock rejection without changing the Simulator's system clock.
        let clock = TestSessionClock(wallTimeMs: Date().timeIntervalSince1970 * 1_000 + 600_000)
        let transport = RecordingURLSessionAuthTransport()
        let client = AuthClient(
            bindingStore: store,
            transport: transport,
            clock: clock,
            endpoints: localLaunchConfiguration.endpoints(for: .local)
        )

        let serverTime: Double
        let firstTimestamp: Int64
        do {
            _ = try await client.pair(binding: pending, carToken: carToken)
            Issue.record("The deliberate local clock skew should be rejected")
            throw LocalAuthFixtureError.unavailable
        } catch let failure as AuthFailure {
            #expect(failure.kind == .server)
            #expect(failure.httpStatus == 401)
            #expect(failure.serverCode == "TIMESTAMP_OUT_OF_RANGE")
            #expect(transport.requestTimestamps.count == 1)
            #expect(transport.responseStatuses == [401])
            serverTime = try #require(transport.rejectedServerTimeMs)
            firstTimestamp = try #require(transport.requestTimestamps.first)
        } catch {
            throw error
        }
        #expect(abs(Double(firstTimestamp) - serverTime) > 120_000)

        // A separate caller invocation uses the accepted server-time offset.
        let paired = try await client.pair(binding: pending, carToken: carToken)
        #expect(transport.requestTimestamps.count == 2)
        #expect(transport.responseStatuses == [401, 200])
        #expect(abs(Double(try #require(transport.requestTimestamps.last)) - serverTime) < 120_000)
        let registered = try await store.completeRegistration(bindingId: pending.bindingId, carId: paired.carId)
        let refreshed = try await client.token(binding: registered)

        #expect(registered.bindingId == pending.bindingId)
        #expect(refreshed.userId == paired.userId)
        #expect(refreshed.carId == registered.carId)
        #expect(paired.deadline > clock.now)
        #expect(refreshed.deadline > clock.now)
        #expect(!paired.expiresAt.isEmpty)
        #expect(!refreshed.expiresAt.isEmpty)
    }
}

@MainActor
private struct LocalAuthCameraPermission: CameraPermissionProviding {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

private final class LocalAuthHTTPFixture {
    private let listener = try! NWListener(using: .tcp, on: .any)
    private let queue = DispatchQueue(label: "zdeep.tests.local-auth-http-fixture")
    private let lock = NSLock()
    private var responses: [(Int, Data)]
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }

    init(responses: [(Int, Data)]) throws { self.responses = responses }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                    let reply = self.lock.withLock { () -> (Int, Data)? in
                        self.requests += 1
                        guard !self.responses.isEmpty else { return nil }
                        return self.responses.removeFirst()
                    }
                    guard let (status, body) = reply else { connection.cancel(); return }
                    let reason = status == 200 ? "OK" : "Forbidden"
                    let header = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { continuation.resume(throwing: FixtureError.missingPort); return }
                    continuation.resume(returning: URL(string: "http://localhost:\(port.rawValue)")!)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }
    private enum FixtureError: Error { case missingPort }
}
