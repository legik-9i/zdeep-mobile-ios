import AVFoundation
import Foundation
import UIKit

@MainActor
extension AppCoordinator {
    func beginCameraScan() async {
        guard screen == .welcome, !isTransitioning else { return }
        let intent = UUID()
        activeScenarioID = intent
        cameraScanIntentID = intent
        didConsumeCameraResult = false
        cameraPermissionRecheckPending = false
        didReceiveFirstFrame = false
        canCancelAuthorization = false
        closeCurrentWebSession()
        screen = .loading

        var status = cameraPermission.status()
        if status == .notDetermined {
            let granted = await cameraPermission.requestAccess()
            guard activeScenarioID == intent, cameraScanIntentID == intent else { return }
            status = granted ? .authorized : cameraPermission.status()
            guard isActive else { return }
        }
        guard activeScenarioID == intent, cameraScanIntentID == intent else { return }
        showCameraState(for: status)
    }

    func cameraPermissionDidReturn() async {
        guard isActive, let intent = cameraScanIntentID,
              activeScenarioID == intent,
              screen == .loading || screen == .scanner || screen == .cameraPermissionDenied || screen == .cameraPermissionRestricted else { return }
        let status = cameraPermission.status()
        guard activeScenarioID == intent, cameraScanIntentID == intent else { return }
        showCameraState(for: status)
        cameraPermissionRecheckPending = false
    }

    func openCameraSettings() {
        guard cameraScanIntentID == activeScenarioID,
              screen == .cameraPermissionDenied else { return }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func cancelCameraScan() {
        guard cameraScanIntentID != nil else { return }
        cameraScanIntentID = nil
        cameraPermissionRecheckPending = false
        didConsumeCameraResult = false
        canCancelAuthorization = false
        activeScenarioID = UUID()
        didReceiveFirstFrame = false
        closeCurrentWebSession()
        screen = .welcome
    }

    func scannerDidProduce(_ value: String) async {
        guard isActive, !cameraPermissionRecheckPending, screen == .scanner, let intent = cameraScanIntentID,
              activeScenarioID == intent, !didConsumeCameraResult else { return }
        didConsumeCameraResult = true
        cameraScanIntentID = nil
        do {
            let qr = try CarQRParser.parse(value)
            screen = .loading
            canCancelAuthorization = true
            await registerFromQR(qr, scenarioID: intent)
        } catch {
            let failure = AuthFailure(
                kind: .invalidResponse, stage: .pair, attemptId: UUID(),
                message: "The QR code is not supported.", diagnosticCode: "BAD_QR"
            )
            activeScenarioID = UUID()
            screen = .error(.initialRegistrationFailure(failure))
        }
    }

    func scannerDidFail() {
        guard screen == .scanner, cameraScanIntentID == activeScenarioID else { return }
        cancelCameraScan()
    }

    func cancelAuthorization() async {
        guard canCancelAuthorization, !isTransitioning else { return }
        await performBindingCleanup(reason: .cancel, next: .restoreThenWelcome)
    }

    private func showCameraState(for status: AVAuthorizationStatus) {
        if CameraPermission.isAuthorized(status) {
            screen = .scanner
        } else if status == .restricted {
            screen = .cameraPermissionRestricted
        } else {
            screen = .cameraPermissionDenied
        }
    }

    private func registerFromQR(_ qr: CarQR, scenarioID: UUID) async {
        let carToken = qr.carToken
        do {
            let pending = try await bindingStore.beginRegistration()
            guard activeScenarioID == scenarioID else { return }
            _ = try await sessionManager.register(binding: pending, carToken: carToken)
            guard activeScenarioID == scenarioID else { return }
            restoredBinding = sessionManager.registeredBinding
            canCancelAuthorization = true
            screen = .loading
            if didReceiveFirstFrame { prepareWebSession() }
        } catch is CancellationError {
            guard activeScenarioID == scenarioID else { return }
            await cleanFailedRegistration(
                AuthFailure(kind: .local, stage: .pair, attemptId: UUID(), message: "Registration was cancelled.", diagnosticCode: "CANCELLED"),
                scenarioID: scenarioID
            )
        } catch let registrationFailure as RegistrationFailure {
            guard activeScenarioID == scenarioID else { return }
            if let binding = registrationFailure.registeredBinding {
                restoredBinding = binding
                canCancelAuthorization = false
                activeScenarioID = UUID()
                screen = .error(.retryable(registrationFailure.failure, context: .authorization(binding)))
            } else {
                await cleanFailedRegistration(registrationFailure.failure, scenarioID: scenarioID)
            }
        } catch {
            guard activeScenarioID == scenarioID else { return }
            await cleanFailedRegistration(sessionManager.lastError ?? Self.restoreFailure(error), scenarioID: scenarioID)
        }
    }

    private func cleanFailedRegistration(_ failure: AuthFailure, scenarioID: UUID) async {
        guard activeScenarioID == scenarioID else { return }
        cameraScanIntentID = nil
        canCancelAuthorization = false
        await performBindingCleanup(reason: .failedRegistration, next: .showRegistrationError(failure))
    }
}
