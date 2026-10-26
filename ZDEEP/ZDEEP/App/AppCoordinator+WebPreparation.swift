import Foundation

@MainActor
extension AppCoordinator {
    func webSessionDidEmit(_ event: WebSessionEvent, scenarioID: UUID) {
        guard activeScenarioID == scenarioID else { return }
        switch event {
        case .documentPreparing(let identity, let url, let reason):
            guard identity.containerId == webSession?.id else { return }
            if readinessIdentity == nil, readinessRemaining == .zero,
               case .error(.retryable(_, context: .web)) = screen { return }
            let continuePendingBudget = readinessIdentity == nil
                && (readinessStartedAt != nil || readinessRemaining < .seconds(60))
            cancelReadinessBudget(reset: false)
            currentCommittedDocument = nil
            acceptedReadyDocument = nil
            readinessAcceptedScreen = nil
            readinessIdentity = identity
            readinessURL = url
            readinessReason = reason
            if !continuePendingBudget { readinessRemaining = .seconds(60) }
            setWebViewOpen(false)
            if reason == .fullNavigation || reason == .explicitRetry || reason == .processRecovery {
                if reason == .processRecovery || didRevealWebSession {
                    clearWebLoading()
                } else if webLoadingImageName == nil {
                    beginWebLoading()
                }
                screen = .loading
            }
            if let binding = restoredBinding, sessionManager.currentSession?.carId == binding.carId {
                if readinessRemaining == .zero {
                    readinessDidTimeout(identity, scenarioID: scenarioID)
                } else {
                    startReadinessBudget(for: identity)
                }
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
            clearWebLoading()
            screen = .error(.retryable(failure, context: .web(
                url: readinessURL ?? endpoints.web, bindingId: binding.bindingId, reason: readinessReason
            )))
        case .processTerminated:
            currentCommittedDocument = nil
            cancelReadinessBudget(reset: true)
            guard let binding = restoredBinding else { return }
            setWebViewOpen(false)
            guard didRevealWebSession, !didRecoverProcess, let webSession else {
                readinessIdentity = nil
                clearWebLoading()
                screen = .error(.retryable(Self.webRecoveryFailure(), context: .web(
                    url: readinessURL ?? endpoints.web, bindingId: binding.bindingId, reason: .processRecovery
                )))
                return
            }
            didRecoverProcess = true
            clearWebLoading()
            screen = .loading
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

    func retryAuthorization(_ binding: RegisteredBinding, webURL: URL? = nil) async {
        guard restoredBinding?.bindingId == binding.bindingId,
              let scenarioID = activeScenarioID else { return }
        let webSession = self.webSession
        beginWebLoading()
        screen = .loading
        setWebViewOpen(false)
        invalidateCurrentReadiness()
        webSession?.invalidateCurrentDocument()
        do {
            _ = try await sessionManager.updateSession(binding: binding)
            guard activeScenarioID == scenarioID else { return }
            readinessRemaining = .seconds(60)
            webSession?.prepareAndLoad(url: webURL ?? endpoints.web, reason: .explicitRetry)
            readinessSessionDidChange()
        } catch {
            guard activeScenarioID == scenarioID else { return }
            clearWebLoading()
            screen = .error(.retryable(sessionManager.lastError ?? Self.restoreFailure(error), context: .authorization(binding)))
        }
    }

    func retryWebDocument(url: URL) async {
        guard let binding = restoredBinding,
              let webSession,
              let scenarioID = activeScenarioID else { return }
        if sessionManager.currentSession?.carId != binding.carId {
            await retryAuthorization(binding, webURL: url)
            return
        }
        guard activeScenarioID == scenarioID else { return }
        beginWebLoading()
        screen = .loading
        setWebViewOpen(false)
        invalidateCurrentReadiness()
        webSession.invalidateCurrentDocument()
        readinessRemaining = .seconds(60)
        webSession.prepareAndLoad(url: url, reason: .explicitRetry)
    }

    func readinessSessionDidChange() {
        guard let binding = restoredBinding,
              sessionManager.currentSession?.carId == binding.carId else { return }
        guard let identity = readinessIdentity else {
            startPendingReadinessBudget()
            return
        }
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
        pendingReadinessTimerID = nil
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
        pendingReadinessTimerID = nil
        readinessStartedAt = nil
        if reset { readinessRemaining = .seconds(60) }
    }

    private func startPendingReadinessBudget() {
        guard let scenarioID = activeScenarioID, isActive, screen == .loading,
              readinessIdentity == nil, readinessTimer == nil, readinessStartedAt == nil,
              let binding = restoredBinding,
              sessionManager.currentSession?.carId == binding.carId else { return }
        let timerID = UUID()
        pendingReadinessTimerID = timerID
        if readinessRemaining == .zero {
            pendingReadinessDidTimeout(timerID, scenarioID: scenarioID)
            return
        }
        let startedAt = sessionClock.now
        readinessStartedAt = startedAt
        readinessTimer = sessionClock.schedule(at: startedAt + readinessRemaining) { [weak self] in
            self?.pendingReadinessDidTimeout(timerID, scenarioID: scenarioID)
        }
    }

    private func pendingReadinessDidTimeout(_ timerID: UUID, scenarioID: UUID) {
        guard pendingReadinessTimerID == timerID,
              activeScenarioID == scenarioID,
              readinessIdentity == nil,
              screen == .loading,
              let binding = restoredBinding else { return }
        cancelReadinessBudget(reset: false)
        readinessRemaining = .zero
        clearWebLoading()
        let failure = AuthFailure(kind: .timeout, stage: .web, attemptId: UUID(),
            message: "Web session did not become ready", diagnosticCode: "WEB_READY_TIMEOUT")
        screen = .error(.retryable(failure, context: .web(
            url: endpoints.web, bindingId: binding.bindingId, reason: .initial
        )))
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
        clearWebLoading()
        setWebViewOpen(false)
        let failure = AuthFailure(kind: .timeout, stage: .web, attemptId: identity.attemptId,
            message: "Web session did not become ready", diagnosticCode: "WEB_READY_TIMEOUT")
        screen = .error(.retryable(failure, context: .web(
            url: readinessURL ?? endpoints.web, bindingId: binding.bindingId, reason: readinessReason
        )))
    }

    private func invalidateCurrentReadiness() {
        cancelReadinessBudget(reset: true)
        readinessIdentity = nil
        readinessURL = nil
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
