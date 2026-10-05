import Foundation

@MainActor
extension AppCoordinator {
    func resetBindingAndShowWelcome() async {
        await performBindingCleanup(reason: .rebind, next: .restoreThenWelcome)
    }

    func retryBindingCleanup(reason: LocalResetReason, next: CleanupNextStep) async {
        await performBindingCleanup(reason: reason, next: next)
    }

    func performBindingCleanup(reason: LocalResetReason, next: CleanupNextStep) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        cameraScanIntentID = nil
        didConsumeCameraResult = false
        canCancelAuthorization = false
        activeScenarioID = UUID()
        didReceiveFirstFrame = false
        closeCurrentWebSession()
        sessionManager.stop()
        screen = .loading

        do {
            try await bindingStore.reset()
        } catch {
            showCleanupError(reason: reason, next: next)
            return
        }

        do {
            guard try await bindingStore.restore() == nil else {
                showCleanupError(reason: reason, next: next)
                return
            }
            restoredBinding = nil
            restoreAfterCleanup = nil
            activeScenarioID = UUID()
            switch next {
            case .restoreThenWelcome:
                screen = .welcome
            case .showRegistrationError(let failure):
                screen = .error(.initialRegistrationFailure(failure))
            }
        } catch {
            restoreAfterCleanup = next
            activeScenarioID = UUID()
            screen = .error(.retryable(Self.restoreFailure(error), context: .restore))
        }
    }

    private func showCleanupError(reason: LocalResetReason, next: CleanupNextStep) {
        let failure = AuthFailure(
            kind: .local, stage: .storage, attemptId: UUID(),
            message: "Binding cleanup failed", diagnosticCode: "KEYCHAIN"
        )
        activeScenarioID = UUID()
        screen = .error(.retryable(failure, context: .cleanup(reason: reason, next: next)))
    }
}
