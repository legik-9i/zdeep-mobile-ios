import Foundation

@MainActor
extension AppCoordinator {
    func webSessionDidEmit(_ event: WebSessionEvent, scenarioID: UUID) {
        guard activeScenarioID == scenarioID else { return }
        switch event {
        case .documentPreparing(let identity, let url, let reason):
            guard identity.containerId == webSession?.id else { return }
            cancelReadinessBudget(reset: false)
            currentCommittedDocument = nil
            acceptedReadyDocument = nil
            readinessAcceptedScreen = nil
            readinessIdentity = identity
            readinessReason = reason
            readinessRemaining = .seconds(60)
            setWebViewOpen(false)
            if reason == .fullNavigation || reason == .explicitRetry || reason == .processRecovery {
                screen = .loading
                canCancelAuthorization = true
            }
            if let binding = restoredBinding, sessionManager.currentSession?.carId == binding.carId {
                startReadinessBudget(for: identity)
            }
            eventStore.record(category: "webview.preparing", operationID: identity.containerId.uuidString, fields: [
                "reason": String(describing: reason),
                "document": identity.documentId.uuidString
            ])
            _ = url
        case .documentCommitted(let identity):
            guard identity.containerId == webSession?.id,
                  identity == readinessIdentity else { return }
            currentCommittedDocument = identity
        case .documentFailed(let identity, let failure):
            guard identity.containerId == webSession?.id,
                  identity == readinessIdentity else { return }
            currentCommittedDocument = nil
            readinessIdentity = nil
            acceptedReadyDocument = nil
            readinessAcceptedScreen = nil
            cancelReadinessBudget(reset: true)
            guard let binding = restoredBinding else { return }
            setWebViewOpen(false)
            canCancelAuthorization = false
            screen = .error(.retryable(failure, context: .web(
                url: endpoints.web, bindingId: binding.bindingId, reason: readinessReason
            )))
        case .processTerminated:
            currentCommittedDocument = nil
            cancelReadinessBudget(reset: true)
            guard let binding = restoredBinding else { return }
            setWebViewOpen(false)
            guard didRevealWebSession, !didRecoverProcess, let webSession else {
                readinessIdentity = nil
                canCancelAuthorization = false
                screen = .error(.retryable(Self.webRecoveryFailure(), context: .web(
                    url: endpoints.web, bindingId: binding.bindingId, reason: .processRecovery
                )))
                return
            }
            didRecoverProcess = true
            screen = .loading
            canCancelAuthorization = true
            webSession.recoverFromProcessTermination()
        }
    }

    func acceptWebReady(
        _ identity: WebDocumentIdentity,
        scenarioID: UUID,
        screen readyScreen: WebReadyScreen = .content
    ) throws {
        guard activeScenarioID == scenarioID,
              webSession?.id == identity.containerId,
              readinessIdentity == identity,
              currentCommittedDocument == identity,
              let binding = restoredBinding,
              let session = sessionManager.currentSession,
              session.carId == binding.carId,
              screen == .loading || screen == .web else {
            throw AuthFailure(kind: .local, stage: .web, attemptId: identity.attemptId, message: "Web session is not ready", diagnosticCode: "WEB_READY")
        }
        acceptedReadyDocument = identity
        readinessAcceptedScreen = readyScreen
        cancelReadinessBudget(reset: true)
        readinessRemaining = .zero
        if readinessReason == .processRecovery { didRecoverProcess = false }
        revealAcceptedWebReadyIfPossible()
    }

    func retryAuthorization(_ binding: RegisteredBinding) async {
        guard restoredBinding?.bindingId == binding.bindingId,
              let scenarioID = activeScenarioID else { return }
        let webSession = self.webSession
        canCancelAuthorization = true
        screen = .loading
        setWebViewOpen(false)
        invalidateCurrentReadiness()
        webSession?.invalidateCurrentDocument()
        do {
            _ = try await sessionManager.updateSession(binding: binding)
            guard activeScenarioID == scenarioID else { return }
            readinessRemaining = .seconds(60)
            webSession?.prepareAndLoad(url: endpoints.web, reason: .explicitRetry)
            readinessSessionDidChange()
        } catch {
            guard activeScenarioID == scenarioID else { return }
            canCancelAuthorization = false
            screen = .error(.retryable(sessionManager.lastError ?? Self.restoreFailure(error), context: .authorization(binding)))
        }
    }

    func retryWebDocument(url: URL) async {
        guard let binding = restoredBinding,
              let webSession,
              let scenarioID = activeScenarioID else { return }
        canCancelAuthorization = true
        screen = .loading
        setWebViewOpen(false)
        invalidateCurrentReadiness()
        webSession.invalidateCurrentDocument()
        if sessionManager.currentSession?.carId != binding.carId {
            await retryAuthorization(binding)
            return
        }
        guard activeScenarioID == scenarioID else { return }
        readinessRemaining = .seconds(60)
        webSession.prepareAndLoad(url: url, reason: .explicitRetry)
    }

    func readinessSessionDidChange() {
        guard let identity = readinessIdentity,
              let binding = restoredBinding,
              sessionManager.currentSession?.carId == binding.carId else { return }
        if acceptedReadyDocument == identity {
            revealAcceptedWebReadyIfPossible()
        } else {
            startReadinessBudget(for: identity)
        }
    }

    func pauseReadinessBudget() {
        guard let startedAt = readinessStartedAt else { return }
        readinessRemaining = max(.zero, readinessRemaining - (sessionClock.now - startedAt))
        readinessTimer?.cancel()
        readinessTimer = nil
        readinessStartedAt = nil
    }

    func resumeReadinessBudget() {
        revealAcceptedWebReadyIfPossible()
        readinessSessionDidChange()
    }

    func cancelReadinessBudget(reset: Bool) {
        if let startedAt = readinessStartedAt {
            readinessRemaining = max(.zero, readinessRemaining - (sessionClock.now - startedAt))
        }
        readinessTimer?.cancel()
        readinessTimer = nil
        readinessStartedAt = nil
        if reset { readinessRemaining = .seconds(60) }
    }

    private func startReadinessBudget(for identity: WebDocumentIdentity) {
        guard let scenarioID = activeScenarioID,
              isActive, readinessIdentity == identity,
              acceptedReadyDocument != identity,
              readinessTimer == nil, readinessRemaining > .zero,
              let binding = restoredBinding,
              sessionManager.currentSession?.carId == binding.carId else { return }
        let startedAt = sessionClock.now
        readinessStartedAt = startedAt
        readinessTimer = sessionClock.schedule(at: startedAt + readinessRemaining) { [weak self] in
            self?.readinessDidTimeout(identity, scenarioID: scenarioID)
        }
    }

    private func readinessDidTimeout(_ identity: WebDocumentIdentity, scenarioID: UUID) {
        guard readinessIdentity == identity,
              activeScenarioID == scenarioID,
              webSession?.id == identity.containerId,
              acceptedReadyDocument != identity,
              let binding = restoredBinding else { return }
        readinessTimer = nil
        readinessStartedAt = nil
        readinessRemaining = .zero
        readinessIdentity = nil
        currentCommittedDocument = nil
        canCancelAuthorization = false
        setWebViewOpen(false)
        let failure = AuthFailure(kind: .timeout, stage: .web, attemptId: identity.attemptId,
            message: "Web session did not become ready", diagnosticCode: "WEB_READY_TIMEOUT")
        screen = .error(.retryable(failure, context: .web(
            url: endpoints.web, bindingId: binding.bindingId, reason: readinessReason
        )))
    }

    private func invalidateCurrentReadiness() {
        cancelReadinessBudget(reset: true)
        readinessIdentity = nil
        acceptedReadyDocument = nil
        currentCommittedDocument = nil
        readinessAcceptedScreen = nil
    }

    func revealAcceptedWebReadyIfPossible() {
        guard let identity = acceptedReadyDocument,
              readinessIdentity == identity,
              isActive,
              webSession?.id == identity.containerId,
              let binding = restoredBinding,
              sessionManager.currentSession?.carId == binding.carId,
              screen == .loading || screen == .web else { return }
        setWebViewOpen(true)
        screen = .web
        canCancelAuthorization = false
        if !didRevealWebSession {
            didRevealWebSession = true
            sessionManager.webViewDidBecomeVisible()
        }
        eventStore.record(category: "webview.opened", operationID: identity.containerId.uuidString)
    }

    private static func webRecoveryFailure() -> AuthFailure {
        AuthFailure(kind: .network, stage: .web, attemptId: UUID(), message: "Web content process terminated", diagnosticCode: "WEB_PROCESS_TERMINATED")
    }
}
