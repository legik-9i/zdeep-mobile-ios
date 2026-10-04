import Foundation

enum NativeErrorAction: Equatable {
    case retry
    case startOver
    case reset
    case rebind
}

enum NativeErrorPresentation: Equatable {
    case initialRegistrationFailure(AuthFailure)
    case retryable(AuthFailure, context: RetryContext)

    var failure: AuthFailure {
        switch self {
        case .initialRegistrationFailure(let failure), .retryable(let failure, _): failure
        }
    }

    var retryContext: RetryContext? {
        guard case .retryable(_, let context) = self else { return nil }
        return context
    }

    var actions: [NativeErrorAction] {
        switch retryContext {
        case nil: [.startOver]
        case .restore: [.retry, .reset]
        case .authorization, .web: [.retry, .rebind]
        case .cleanup, .environment, .fullReset: [.retry]
        }
    }

    var diagnosticCode: String {
        String((failure.serverCode ?? failure.diagnosticCode).prefix(15))
    }

    var displayAttemptId: String {
        String(failure.attemptId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        if shortVersion.isEmpty { return build }
        if build.isEmpty { return shortVersion }
        return "\(shortVersion) (\(build))"
    }
}

enum RetryContext: Equatable {
    case restore
    case authorization(RegisteredBinding)
    case web(url: URL, bindingId: UUID, reason: WebPreparationReason)
    case cleanup(reason: LocalResetReason, next: CleanupNextStep)
    case environment(target: AppEnvironment, previous: AppEnvironment, stage: EnvironmentSwitchStage)
    case fullReset(OwnedCleanupProgress)
}

enum CleanupNextStep: Equatable {
    case restoreThenWelcome
    case showRegistrationError(AuthFailure)
}

enum LocalResetReason: Equatable {
    case cancel
    case rebind
    case failedRegistration
    case storageReset
}

enum EnvironmentSwitchStage: Equatable {
    case cleanup
    case apply
}

struct OwnedCleanupProgress: Equatable {
    let remaining: Set<OwnedDataCategory>
    let failures: [OwnedDataCategory: AuthFailure]
}

enum OwnedDataCategory: Hashable {
    case keychain
    case files
    case preferences
    case webData
}
