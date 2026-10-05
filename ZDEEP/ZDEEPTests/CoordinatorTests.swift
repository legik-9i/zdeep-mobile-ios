import Foundation
import Combine
import AVFoundation
import Testing
@testable import ZDEEP

@MainActor
struct CoordinatorTests {
    private static let qrURL = "https://example.invalid/auth/get-otp?token=header.eyJjYXJJZCI6InN5bnRoZXRpYy1jYXIifQ.signature"

    @Test func test_camera_permission_is_requested_before_scanner() async {
        let permission = FakeCameraPermissionProvider(status: .notDetermined, requestResult: true)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(), cameraPermission: permission
        )
        await coordinator.start()

        await coordinator.beginCameraScan()

        #expect(permission.calls == ["status", "request"])
        #expect(coordinator.screen == .scanner)
    }

    @Test func test_cancel_cold_restore_token_attempt_before_and_after_retry() async {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "synthetic", carId: "synthetic-car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false)
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let updateGate = TestSaveGate()
        manager.updateGate = updateGate
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager
        )

        await coordinator.start()
        await updateGate.waitUntilStarted()
        #expect(coordinator.screen == .loading)
        #expect(coordinator.canCancelAuthorization)

        await coordinator.cancelAuthorization()
        #expect(store.resetCount == 1)
        #expect(manager.stopCount == 1)
        #expect(coordinator.screen == .welcome)

        updateGate.resume()
        while !manager.updateFinished { await Task.yield() }
        #expect(coordinator.screen == .welcome)

        let retryBinding = RegisteredBinding(bindingId: UUID(), publicCertificate: "synthetic", carId: "synthetic-car")
        let retryStore = ResettableCoordinatorBindingStore(binding: retryBinding, resetFails: false)
        let retryManager = FakeRegistrationSessionManager(bindingStore: retryStore)
        let retryGate = TestSaveGate()
        retryManager.updateGate = retryGate
        let retryCoordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: retryStore, sessionManager: retryManager
        )
        await retryCoordinator.start()
        await retryGate.waitUntilStarted()
        retryGate.resume()
        while !retryManager.updateFinished { await Task.yield() }
        guard case .error = retryCoordinator.screen else {
            Issue.record("A failed initial token attempt should expose authorization retry")
            return
        }
        retryManager.updateFinished = false
        let retryGate2 = TestSaveGate()
        retryManager.updateGate = retryGate2
        let retryTask = Task { await retryCoordinator.retry() }
        await retryGate2.waitUntilStarted()
        #expect(retryCoordinator.screen == .loading)
        #expect(retryCoordinator.canCancelAuthorization)
        await retryCoordinator.cancelAuthorization()
        #expect(retryStore.resetCount == 1)
        #expect(retryManager.stopCount == 1)
        #expect(retryCoordinator.screen == .welcome)
        retryGate2.resume()
        await retryTask.value
        #expect(retryCoordinator.screen == .welcome)
    }

    @Test func test_camera_settings_return_requires_current_scan_intent() async {
        let permission = FakeCameraPermissionProvider(status: .denied, requestResult: false)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(), cameraPermission: permission
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        #expect(coordinator.screen == .cameraPermissionDenied)

        permission.statusValue = .authorized
        await coordinator.cameraPermissionDidReturn()
        #expect(coordinator.screen == .scanner)

        coordinator.cancelCameraScan()
        let requestCount = permission.calls.filter { $0 == "status" }.count
        await coordinator.cameraPermissionDidReturn()
        #expect(coordinator.screen == .welcome)
        #expect(permission.calls.filter { $0 == "status" }.count == requestCount)
    }

    @Test func test_foreground_rechecksScannerPermissionAndIgnoresInactiveRequestResult() async {
        let permission = FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store,
            sessionManager: manager, cameraPermission: permission
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        #expect(coordinator.screen == .scanner)

        coordinator.setActive(false)
        permission.statusValue = .denied
        coordinator.setActive(true)
        await coordinator.cameraPermissionDidReturn()
        #expect(coordinator.screen == .cameraPermissionDenied)

        coordinator.cancelCameraScan()
        permission.statusValue = .notDetermined
        let requestGate = TestSaveGate()
        permission.requestGate = requestGate
        let requestTask = Task { await coordinator.beginCameraScan() }
        await requestGate.waitUntilStarted()
        coordinator.setActive(false)
        permission.statusValue = .authorized
        requestGate.resume()
        await requestTask.value
        #expect(coordinator.screen != .scanner)

        coordinator.setActive(true)
        await coordinator.cameraPermissionDidReturn()
        #expect(coordinator.screen == .scanner)
        coordinator.setActive(false)
        await coordinator.scannerDidProduce(Self.qrURL)
        #expect(coordinator.screen == .scanner)
        #expect(store.beginCount == 0)
        #expect(manager.registerCount == 0)
        #expect(permission.calls.count >= 4)
    }

    @Test func test_lateBeginRegistrationCannotResetNewScenarioBinding() async {
        let store = RegistrationCoordinatorBindingStore()
        let beginGate = TestSaveGate()
        store.beginGate = beginGate
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        let oldRegistration = Task { await coordinator.scannerDidProduce(Self.qrURL) }
        await beginGate.waitUntilStarted()

        await coordinator.cancelAuthorization()
        await coordinator.beginCameraScan()
        await coordinator.scannerDidProduce(Self.qrURL)
        let newBinding = store.registeredBinding
        #expect(newBinding != nil)
        #expect(store.beginCount == 2)
        #expect(store.resetCount == 1)

        beginGate.resume()
        await oldRegistration.value
        #expect(store.resetCount == 1)
        let restoredBinding = try? await store.restore()
        #expect(restoredBinding == newBinding)
    }

    @Test func test_restoreRetryWithUnexpectedBindingStaysInRestoreWithoutAuthOrWeb() async {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "synthetic", carId: "synthetic-car")
        let store = SequencedCoordinatorBindingStore([
            .success(nil),
            .failure(.installMarker(operation: "exists")),
            .success(binding),
            .success(nil)
        ])
        let manager = CoordinatorSessionManager()
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: manager
        )
        await coordinator.start()
        await coordinator.resetBindingAndShowWelcome()
        guard case .error(let firstError) = coordinator.screen else {
            Issue.record("A failed restore after reset must remain retryable")
            return
        }
        #expect(firstError.retryContext == .restore)

        await coordinator.retry()
        guard case .error(let retriedError) = coordinator.screen else {
            Issue.record("An unexpected binding must not start token authorization")
            return
        }
        #expect(retriedError.retryContext == .restore)
        #expect(retriedError.failure == firstError.failure)
        #expect(manager.updateCount == 0)
        #expect(factory.sessions.isEmpty)

        await coordinator.retry()
        #expect(coordinator.screen == .welcome)
        #expect(manager.updateCount == 0)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_new_scenario_invalidates_pending_camera_permission_result() async throws {
        let permission = FakeCameraPermissionProvider(status: .notDetermined, requestResult: true)
        let requestGate = TestSaveGate()
        permission.requestGate = requestGate
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(), cameraPermission: permission
        )
        await coordinator.start()
        let task = Task { await coordinator.beginCameraScan() }
        await requestGate.waitUntilStarted()
        await coordinator.startNewWelcomeScenario()
        await requestGate.resume()
        await task.value

        #expect(coordinator.screen == .welcome)
        #expect(coordinator.activeScenarioID != nil)
    }

    @Test func test_closing_scanner_returns_to_welcome_without_binding() async {
        let store = RegistrationCoordinatorBindingStore()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: FakeRegistrationSessionManager(bindingStore: store),
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()

        coordinator.cancelCameraScan()

        #expect(coordinator.screen == .welcome)
        #expect(store.beginCount == 0)
        #expect(store.resetCount == 0)
    }

    @Test func test_stale_scanner_result_after_welcome_is_ignored() async {
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        await coordinator.startNewWelcomeScenario()

        await coordinator.scannerDidProduce(Self.qrURL)

        #expect(coordinator.screen == .welcome)
        #expect(store.beginCount == 0)
        #expect(manager.registerCount == 0)
    }

    @Test func test_restricted_camera_permission_has_back_without_settings_return() async {
        let permission = FakeCameraPermissionProvider(status: .restricted, requestResult: false)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(), cameraPermission: permission
        )
        await coordinator.start()

        await coordinator.beginCameraScan()

        #expect(coordinator.screen == .cameraPermissionRestricted)
        #expect(permission.calls == ["status"])
        coordinator.cancelCameraScan()
        #expect(coordinator.screen == .welcome)
    }

    @Test func test_one_qr_starts_one_pair_and_complete() async {
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        #expect(coordinator.screen == .scanner)

        await coordinator.scannerDidProduce(Self.qrURL)
        await coordinator.scannerDidProduce(Self.qrURL)

        #expect(coordinator.screen == .loading)
        #expect(store.beginCount == 1)
        #expect(manager.registerCount == 1)
        #expect(store.completeCount == 1)
        #expect(store.registeredBinding?.carId == "synthetic-car")
    }

    @Test func test_invalid_qr_returns_start_over_without_beginning_registration() async {
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()

        await coordinator.scannerDidProduce("https://example.invalid/not-a-car-qr")

        guard case .error(let presentation) = coordinator.screen else {
            Issue.record("An unsupported QR must return a start-over error")
            return
        }
        #expect(presentation.actions == [.startOver])
        #expect(store.beginCount == 0)
        #expect(manager.registerCount == 0)
        #expect(store.resetCount == 0)
    }

    @Test func test_pair_failure_cleans_binding_before_initial_error() async {
        let failure = AuthFailure(kind: .network, stage: .pair, attemptId: UUID(), message: "fixture", diagnosticCode: "NETWORK")
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        manager.registrationError = RegistrationFailure(failure: failure, registeredBinding: nil)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()

        await coordinator.scannerDidProduce(Self.qrURL)

        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 2)
        #expect(store.registeredBinding == nil)
        guard case .error(let presentation) = coordinator.screen else {
            Issue.record("A pair failure should appear after cleanup")
            return
        }
        #expect(presentation.actions == [.startOver])
    }

    @Test func test_cleanup_failure_blocks_scanner_and_offers_only_retry() async {
        let failure = AuthFailure(kind: .network, stage: .pair, attemptId: UUID(), message: "fixture", diagnosticCode: "NETWORK")
        let store = RegistrationCoordinatorBindingStore(resetFailures: 1)
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        manager.registrationError = RegistrationFailure(failure: failure, registeredBinding: nil)
        let permission = FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager, cameraPermission: permission
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        await coordinator.scannerDidProduce(Self.qrURL)
        let permissionCallsBefore = permission.calls.count

        await coordinator.beginCameraScan()

        guard case .error(let presentation) = coordinator.screen else {
            Issue.record("A failed pending-binding cleanup must block new scanner intents")
            return
        }
        #expect(presentation.actions == [.retry])
        #expect(permission.calls.count == permissionCallsBefore)
        #expect(store.beginCount == 1)

        await coordinator.retry()

        #expect(store.resetCount == 2)
        guard case .error(let initialError) = coordinator.screen else {
            Issue.record("Successful cleanup retry should then expose the original start-over error")
            return
        }
        #expect(initialError.actions == [.startOver])
    }

    @Test func test_registered_save_then_expired_jwt_uses_token_retry_without_cleanup() async {
        let failure = AuthFailure(kind: .timeout, stage: .token, attemptId: UUID(), message: "expired", diagnosticCode: "TIMEOUT")
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        manager.registrationError = RegistrationFailure(failure: failure, registeredBinding: nil)
        manager.completeBeforeRegistrationError = true
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()

        await coordinator.scannerDidProduce(Self.qrURL)

        #expect(store.resetCount == 0)
        #expect(store.registeredBinding != nil)
        guard case .error(let presentation) = coordinator.screen else {
            Issue.record("A saved registration with an expired JWT should preserve the registered authorization error")
            return
        }
        if case .authorization(let retryBinding) = presentation.retryContext {
            #expect(retryBinding == store.registeredBinding)
        } else {
            Issue.record("A saved binding must use the token retry context")
        }
    }

    @Test func test_cancel_during_save_cleans_late_registered_result() async throws {
        let store = RegistrationCoordinatorBindingStore()
        let saveGate = TestSaveGate()
        store.saveGate = saveGate
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        await coordinator.beginCameraScan()
        let registration = Task { await coordinator.scannerDidProduce(Self.qrURL) }
        await saveGate.waitUntilStarted()

        if let scenario = coordinator.activeScenarioID {
            coordinator.nativeFirstFrameDidRender(scenarioID: scenario)
        }
        #expect(factory.sessions.isEmpty)

        await coordinator.cancelAuthorization()
        await saveGate.resume()
        await registration.value

        #expect(store.resetCount == 1)
        #expect(try await store.restore() == nil)
        #expect(manager.currentSession == nil)
        #expect(!coordinator.isWebViewOpen)
        #expect(coordinator.screen == .welcome)
    }

    @Test func test_cancel_after_jwt_before_reveal_resets_binding() async throws {
        let store = RegistrationCoordinatorBindingStore()
        let manager = FakeRegistrationSessionManager(bindingStore: store)
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: manager,
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()
        let welcomeScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: welcomeScenario)
        await coordinator.beginCameraScan()
        await coordinator.scannerDidProduce(Self.qrURL)
        let webSession = try #require(factory.sessions.first)
        let loadingScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: loadingScenario)
        let preparedDuringRegistration = try #require(factory.sessions.last)

        await coordinator.cancelAuthorization()
        #expect(try await store.restore() == nil)
        #expect(manager.currentSession == nil)
        #expect(webSession.closeCount == 1)
        #expect(preparedDuringRegistration.closeCount == 1)
        #expect(!coordinator.isWebViewOpen)
        #expect(coordinator.screen == .welcome)
    }

    @Test func test_marker_failure_after_reset_blocks_welcome_until_restore_retry() async {
        let store = RegistrationCoordinatorBindingStore(restoreFailuresAfterReset: 1)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: FakeRegistrationSessionManager(bindingStore: store),
            cameraPermission: FakeCameraPermissionProvider(status: .authorized, requestResult: true)
        )
        await coordinator.start()

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen != .welcome)
        #expect(store.resetCount == 1)
        guard case .error(let presentation) = coordinator.screen else {
            Issue.record("A marker restore failure after reset must keep authorization blocked")
            return
        }
        #expect(presentation.retryContext == .restore)

        await coordinator.retry()

        #expect(coordinator.screen == .welcome)
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 3)
    }

    @Test func test_none_restores_to_welcome() async {
        let bindingStore = CoordinatorBindingStore(result: .success(nil))
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: FakeWebSessionFactory(), bindingStore: bindingStore, sessionManager: manager
        )

        await coordinator.start()

        #expect(coordinator.screen == .welcome)
        #expect(manager.updateCount == 0)
    }

    @Test func test_registered_starts_one_token_without_welcome_flash() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "certificate", carId: "car")
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: FakeWebSessionFactory(),
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )

        await coordinator.start()

        #expect(coordinator.screen != .welcome)
        #expect(manager.updateCount == 1)
        #expect(coordinator.activeScenarioID != nil)
    }

    @Test func test_restore_error_starts_no_webview() async {
        let manager = CoordinatorSessionManager()
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .failure(BindingStoreError.invalidRecord)), sessionManager: manager
        )

        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }

        #expect(coordinator.screen != .welcome)
        #expect(manager.updateCount == 0)
        #expect(coordinator.isWebPrepared == false)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_restore_retry_resets_native_frame_gate() async throws {
        let factory = FakeWebSessionFactory()
        let store = SequencedCoordinatorBindingStore([
            .failure(.invalidRecord),
            .success(nil)
        ])
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: CoordinatorSessionManager()
        )

        await coordinator.start()
        let failedScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: failedScenario)
        await coordinator.retry()

        let restoredScenario = try #require(coordinator.activeScenarioID)
        #expect(restoredScenario != failedScenario)
        #expect(factory.sessions.isEmpty)
        coordinator.nativeFirstFrameDidRender(scenarioID: restoredScenario)

        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_factory_waits_for_native_frame() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)

        #expect(factory.sessions.isEmpty)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_stale_frame_callback_does_not_create_container() async throws {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        let stale = try #require(coordinator.activeScenarioID)
        await coordinator.startNewWelcomeScenario()

        coordinator.nativeFirstFrameDidRender(scenarioID: stale)

        #expect(factory.sessions.isEmpty)
    }

    @Test func test_background_defers_web_creation() async throws {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.setActive(false)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)

        #expect(factory.sessions.isEmpty)
        coordinator.setActive(true)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_reveal_keeps_the_prepared_session_instance() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let originalID = prepared.id
        let identity = WebDocumentIdentity(containerId: originalID, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)

        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)

        #expect(coordinator.isWebViewOpen)
        #expect(coordinator.screen == .web)
        #expect(coordinator.preparedWebSessionID == originalID)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_session_expiry_keeps_visible_web_session_open() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)
        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)

        manager.currentSession = nil
        manager.emit(.sessionExpired(AuthFailure(
            kind: .timeout, stage: .web, attemptId: UUID(), message: "expired", diagnosticCode: "TIMEOUT"
        )))

        #expect(coordinator.screen == .web)
        #expect(coordinator.isWebViewOpen)
        #expect(prepared.closeCount == 0)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_ready_rejects_session_for_different_car() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "other-car",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "bound-car")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)

        do {
            try coordinator.acceptWebReady(identity, scenarioID: scenarioID)
            Issue.record("A session for a different car must not reveal the WebView")
        } catch let failure as AuthFailure {
            #expect(failure.diagnosticCode == "WEB_READY")
        }

        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.count == 1)
        #expect(prepared.closeCount == 0)
    }

    @Test func test_reset_action_does_not_show_welcome_when_binding_cleanup_fails() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: true)
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        #expect(coordinator.activeScenarioID != nil)

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen != .welcome)
        if case .error(let presentation) = coordinator.screen {
            #expect(presentation.retryContext == .cleanup(reason: .rebind, next: .restoreThenWelcome))
        } else {
            Issue.record("A failed reset must remain an actionable cleanup error")
        }
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 1)

        let failedScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: failedScenario)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_reset_action_shows_welcome_only_after_store_is_empty() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen == .welcome)
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 2)
    }

    @Test func test_reset_action_restore_failure_retries_restore_without_reset() async {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false, restoreFailuresAfterReset: 1)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen != .welcome)
        if case .error(let presentation) = coordinator.screen {
            #expect(presentation.retryContext == .restore)
        } else {
            Issue.record("A post-reset restore error must preserve restore retry context")
        }
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 2)

        await coordinator.retry()

        #expect(coordinator.screen == .welcome)
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 3)
    }

    @Test func test_initial_registration_start_over_does_not_reset_binding_store() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        let failure = AuthFailure(
            kind: .network, stage: .pair, attemptId: UUID(), message: "local fixture",
            diagnosticCode: "NETWORK"
        )

        await coordinator.startOverAfterError(.initialRegistrationFailure(failure))

        #expect(coordinator.screen == .welcome)
        #expect(coordinator.activeScenarioID != nil)
        #expect(store.resetCount == 0)
        #expect(store.restoreCount == 1)
    }

    @Test func test_background_execution_balances_scheduled_refresh_and_bridge_recover_without_coordinator_task() {
        let manager = CoordinatorSessionManager()
        let adapter = FakeBackgroundTaskProvider()
        let execution = BackgroundExecution(sessionManager: manager, provider: adapter)
        execution.setActive(false)

        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 1)
        manager.emit(.authorizationActivityChanged(false))
        #expect(adapter.endCount == 1)

        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 2)
        manager.emit(.authorizationActivityChanged(false))
        #expect(adapter.endCount == 2)
    }

    @Test func test_background_execution_expiration_blocks_new_tasks_until_foreground() {
        let manager = CoordinatorSessionManager()
        let adapter = FakeBackgroundTaskProvider()
        let execution = BackgroundExecution(sessionManager: manager, provider: adapter)
        execution.setActive(false)
        manager.emit(.authorizationActivityChanged(true))
        adapter.expire()

        #expect(adapter.beginCount == 1)
        #expect(adapter.endCount == 1)
        manager.emit(.authorizationActivityChanged(false))
        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 1)

        execution.setActive(true)
        execution.setActive(false)
        #expect(adapter.beginCount == 2)
        #expect(adapter.endCount == 1)
    }

    @Test func test_select_prod_does_not_load_web() async {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(coordinator.environment == .local)
        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_environment_switch_is_blocked_until_auth_manager_rebuild() async {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: manager,
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .test)

        let panel = DebugPanel(
            coordinator: coordinator,
            eventStore: DiagnosticEventStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
        #expect(coordinator.environment == .local)
        #expect(coordinator.endpoints == AppEnvironment.local.endpoints)
        #expect(manager.updateCount == 0)
        #expect(state.clearCount == 0)
        #expect(factory.sessions.isEmpty)
        #expect(!panel.isEnvironmentPickerEnabled)
    }

    @Test func test_debug_webview_status_tracks_prepared_to_visible_transition() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        #expect(DebugPanel.webViewState(
            isOpen: coordinator.isWebViewOpen, isPrepared: coordinator.isWebPrepared,
            isLoading: prepared.isLoading, hasError: prepared.navigationError != nil
        ) == "Подготовлен (скрыт)")

        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)
        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)
        #expect(DebugPanel.webViewState(
            isOpen: coordinator.isWebViewOpen, isPrepared: coordinator.isWebPrepared,
            isLoading: prepared.isLoading, hasError: prepared.navigationError != nil
        ) == "Открыт")
    }

    @Test func test_close_then_reopen_creates_new_session() async {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager()
        )

        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }
        coordinator.openWebView()
        let firstSession = factory.sessions[0]
        coordinator.closeWebView()
        coordinator.openWebView()

        #expect(factory.sessions.count == 2)
        #expect(firstSession.closeCount == 1)
        #expect(factory.sessions[0].id != factory.sessions[1].id)
    }

    @Test func test_cross_database_switch_requests_clear() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            clearClientState: { await state.clear() }
        )
        await coordinator.switchEnvironment(to: .test)

        #expect(state.clearCount == 0)
        #expect(coordinator.environment == .local)
        #expect(!coordinator.isWebViewOpen)
    }

    @Test func test_suspended_environment_clear_blocks_open_and_stale_switches() async {
        let factory = FakeWebSessionFactory()
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            sessionFactory: factory,
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .test)
        await coordinator.switchEnvironment(to: .prod)

        let panel = DebugPanel(coordinator: coordinator, eventStore: DiagnosticEventStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        #expect(!panel.isEnvironmentPickerEnabled)

        #expect(coordinator.environment == .local)
        #expect(!coordinator.isTransitioning)
        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.isEmpty)
        #expect(state.clearCount == 0)
    }

    @Test func test_test_prod_switch_preserves_store() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "test"], variables: [:]),
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(state.clearCount == 0)
        #expect(coordinator.environment == .test)
    }

    @Test func test_session_published_state_updates_coordinator_and_journal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiagnosticEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(),
            eventStore: store
        )
        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }
        coordinator.openWebView()
        let session = try #require(factory.sessions.first)
        let url = URL(string: "https://example.test/path?apiKey=private-value")!

        session.publishState(url: url, isLoading: false, navigationError: "failed")
        try await Task.sleep(for: .milliseconds(50))

        let stateEvent = try #require(store.snapshot().last)
        #expect(stateEvent.category == "webview.state")
        #expect(stateEvent.fields["url"] == .string("https://example.test/path?apiKey=%5BREDACTED%5D"))
        #expect(stateEvent.fields["isLoading"] == .bool(false))
        #expect(stateEvent.fields["navigationError"] == .string("failed"))
    }

}

@MainActor
private final class FakeWebSessionFactory: WebSessionFactory {
    private(set) var sessions: [FakeWebSession] = []

    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        let session = FakeWebSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class FakeWebSession: WebSessionHandle, ObservableObject {
    let id = UUID()
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var navigationError: String?
    private(set) var closeCount = 0

    func publishState(url: URL?, isLoading: Bool, navigationError: String?) {
        currentURL = url
        self.isLoading = isLoading
        self.navigationError = navigationError
    }

    func close() {
        closeCount += 1
    }
}

private struct CoordinatorBindingStore: BindingStoring {
    let result: Result<RegisteredBinding?, BindingStoreError>

    func restore() async throws -> RegisteredBinding? { try result.get() }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

private final class ResettableCoordinatorBindingStore: BindingStoring, @unchecked Sendable {
    private var binding: RegisteredBinding?
    private let resetFails: Bool
    private var restoreFailuresAfterReset: Int
    private(set) var resetCount = 0
    private(set) var restoreCount = 0
    private var hasReset = false

    init(binding: RegisteredBinding, resetFails: Bool, restoreFailuresAfterReset: Int = 0) {
        self.binding = binding
        self.resetFails = resetFails
        self.restoreFailuresAfterReset = restoreFailuresAfterReset
    }

    func restore() async throws -> RegisteredBinding? {
        restoreCount += 1
        if hasReset && restoreFailuresAfterReset > 0 {
            restoreFailuresAfterReset -= 1
            throw BindingStoreError.invalidRecord
        }
        return binding
    }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {
        resetCount += 1
        if resetFails { throw BindingStoreError.invalidRecord }
        hasReset = true
        binding = nil
    }
}

private final class SequencedCoordinatorBindingStore: BindingStoring {
    private var results: [Result<RegisteredBinding?, BindingStoreError>]

    init(_ results: [Result<RegisteredBinding?, BindingStoreError>]) {
        self.results = results
    }

    func restore() async throws -> RegisteredBinding? {
        guard !results.isEmpty else { throw BindingStoreError.invalidRecord }
        return try results.removeFirst().get()
    }

    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

@MainActor
private final class CoordinatorSessionManager: SessionManaging {
    var currentSession: AuthSession?
    var hasPublishedSession = false
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    private(set) var updateCount = 0
    private var observers: [@MainActor (SessionManagerEvent) -> Void] = []

    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession { throw BindingStoreError.registrationNotAllowed }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        updateCount += 1
        throw BindingStoreError.registrationNotAllowed
    }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        observers.append(observer)
        return CoordinatorCancellation()
    }
    func emit(_ event: SessionManagerEvent) { observers.forEach { $0(event) } }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {}
}

@MainActor
private final class FakeBackgroundTaskProvider: BackgroundTaskProviding {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var expiration: (() -> Void)?

    func begin(expiration: @escaping () -> Void) -> UUID? {
        beginCount += 1
        self.expiration = expiration
        return UUID()
    }
    func end(_ identifier: UUID) { endCount += 1 }
    func expire() { expiration?() }
}

@MainActor
private final class FakeCameraPermissionProvider: CameraPermissionProviding {
    var statusValue: AVAuthorizationStatus
    let requestResult: Bool
    var requestGate: TestSaveGate?
    private(set) var calls: [String] = []

    init(status: AVAuthorizationStatus, requestResult: Bool) {
        statusValue = status
        self.requestResult = requestResult
    }

    func status() -> AVAuthorizationStatus {
        calls.append("status")
        return statusValue
    }

    func requestAccess() async -> Bool {
        calls.append("request")
        await requestGate?.wait()
        return requestResult
    }
}

private final class RegistrationCoordinatorBindingStore: BindingStoring, @unchecked Sendable {
    private var pending: PendingBinding?
    private(set) var registeredBinding: RegisteredBinding?
    private(set) var beginCount = 0
    private(set) var completeCount = 0
    private(set) var resetCount = 0
    private(set) var restoreCount = 0
    private var resetFailures: Int
    private var restoreFailuresAfterReset: Int
    private var hasReset = false
    var saveGate: TestSaveGate?
    var beginGate: TestSaveGate?

    init(resetFailures: Int = 0, restoreFailuresAfterReset: Int = 0) {
        self.resetFailures = resetFailures
        self.restoreFailuresAfterReset = restoreFailuresAfterReset
    }

    func restore() async throws -> RegisteredBinding? {
        restoreCount += 1
        if hasReset, restoreFailuresAfterReset > 0 {
            restoreFailuresAfterReset -= 1
            throw BindingStoreError.installMarker(operation: "exists")
        }
        return registeredBinding
    }

    func beginRegistration() async throws -> PendingBinding {
        guard pending == nil, registeredBinding == nil else { throw BindingStoreError.registrationNotAllowed }
        beginCount += 1
        let binding = PendingBinding(bindingId: UUID(), publicCertificate: "synthetic-public-key")
        pending = binding
        if beginCount == 1 { await beginGate?.wait() }
        return binding
    }

    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }

    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding {
        completeCount += 1
        await saveGate?.wait()
        guard let pending, pending.bindingId == bindingId else { throw BindingStoreError.staleBinding }
        let binding = RegisteredBinding(bindingId: bindingId, publicCertificate: pending.publicCertificate, carId: carId)
        registeredBinding = binding
        self.pending = nil
        return binding
    }

    func reset() async throws {
        resetCount += 1
        if resetFailures > 0 {
            resetFailures -= 1
            throw BindingStoreError.keychain(operation: "delete", status: -1)
        }
        hasReset = true
        pending = nil
        registeredBinding = nil
    }
}

@MainActor
private final class FakeRegistrationSessionManager: SessionManaging {
    private let bindingStore: any BindingStoring
    var currentSession: AuthSession?
    var hasPublishedSession = false
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    var registrationError: Error?
    var completeBeforeRegistrationError = false
    var updateGate: TestSaveGate?
    var updateFinished = false
    private(set) var registerCount = 0
    private(set) var updateCount = 0
    private(set) var stopCount = 0
    private var observers: [@MainActor (SessionManagerEvent) -> Void] = []

    init(bindingStore: any BindingStoring) { self.bindingStore = bindingStore }

    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession {
        registerCount += 1
        if let registrationError {
            var completedBinding: RegisteredBinding?
            if completeBeforeRegistrationError {
                completedBinding = try await bindingStore.completeRegistration(bindingId: binding.bindingId, carId: "synthetic-car")
                registeredBinding = completedBinding
            }
            if let failure = registrationError as? RegistrationFailure {
                let savedBinding = completedBinding ?? failure.registeredBinding
                registeredBinding = savedBinding
                throw RegistrationFailure(failure: failure.failure, registeredBinding: savedBinding)
            }
            throw registrationError
        }
        registeredBinding = try await bindingStore.completeRegistration(bindingId: binding.bindingId, carId: "synthetic-car")
        let session = AuthSession(
            accessToken: "synthetic-fixture-session", userId: "synthetic-user", carId: "synthetic-car",
            expiresAt: "synthetic", deadline: .seconds(3600), serverTimeMs: 0, attemptId: UUID()
        )
        currentSession = session
        hasPublishedSession = true
        return session
    }

    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        updateCount += 1
        await updateGate?.wait()
        updateFinished = true
        throw BindingStoreError.registrationNotAllowed
    }

    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        observers.append(observer)
        return CoordinatorCancellation()
    }
    func emit(_ event: SessionManagerEvent) { observers.forEach { $0(event) } }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {
        stopCount += 1
        currentSession = nil
        hasPublishedSession = false
        registeredBinding = nil
        isAuthorizationInFlight = false
    }
}

@MainActor
private final class TestSaveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CoordinatorCancellation: CancellationHandle {
    func cancel() {}
}

@MainActor
private final class FakeClientState {
    private(set) var clearCount = 0

    func clear() async {
        clearCount += 1
    }
}

private actor SuspendedClientStateClear {
    private(set) var count = 0
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func clear() async {
        count += 1
        guard count == 1 else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            clearContinuation = continuation
        }
    }

    func waitUntilClearStarts() async {
        guard count == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishClear() {
        clearContinuation?.resume()
        clearContinuation = nil
    }
}
