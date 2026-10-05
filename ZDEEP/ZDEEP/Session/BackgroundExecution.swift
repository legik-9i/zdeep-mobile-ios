import UIKit

@MainActor
protocol BackgroundTaskProviding: AnyObject {
    func begin(expiration: @escaping () -> Void) -> UUID?
    func end(_ identifier: UUID)
}

@MainActor
final class SystemBackgroundTaskProvider: BackgroundTaskProviding {
    private final class IdentifierStore {
        var identifiers: [UUID: UIBackgroundTaskIdentifier] = [:]
    }
    private static let store = IdentifierStore()

    func begin(expiration: @escaping () -> Void) -> UUID? {
        let id = UUID()
        let task = UIApplication.shared.beginBackgroundTask(withName: "ZDEEP authorization") {
            Task { @MainActor in expiration() }
        }
        guard task != .invalid else { return nil }
        Self.store.identifiers[id] = task
        return id
    }

    func end(_ identifier: UUID) {
        guard let task = Self.store.identifiers.removeValue(forKey: identifier) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}

@MainActor
final class BackgroundExecution {
    private let sessionManager: any SessionManaging
    private let provider: any BackgroundTaskProviding
    private var subscription: (any CancellationHandle)?
    private var isActive = true
    private var hasAuthorizationInFlight = false
    private var didExpireThisBackgroundPhase = false
    private var identifier: UUID?

    init(sessionManager: any SessionManaging, provider: (any BackgroundTaskProviding)? = nil) {
        self.sessionManager = sessionManager
        self.provider = provider ?? SystemBackgroundTaskProvider()
        hasAuthorizationInFlight = sessionManager.isAuthorizationInFlight
        subscription = sessionManager.subscribe { [weak self] event in
            guard case .authorizationActivityChanged(let running) = event else { return }
            self?.hasAuthorizationInFlight = running
            self?.synchronize()
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            endCurrentTask()
            didExpireThisBackgroundPhase = false
        }
        synchronize()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        endCurrentTask()
    }

    private func synchronize() {
        guard !isActive, hasAuthorizationInFlight, !didExpireThisBackgroundPhase, identifier == nil else {
            if !hasAuthorizationInFlight { endCurrentTask() }
            return
        }
        identifier = provider.begin { [weak self] in
            guard let self else { return }
            self.didExpireThisBackgroundPhase = true
            self.endCurrentTask()
        }
    }

    private func endCurrentTask() {
        guard let identifier else { return }
        self.identifier = nil
        provider.end(identifier)
    }
}
