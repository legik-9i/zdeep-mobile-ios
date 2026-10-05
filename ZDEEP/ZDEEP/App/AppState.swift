import Foundation

enum AppScreen: Equatable {
    case logo
    case welcome
    case scanner
    case cameraPermissionDenied
    case cameraPermissionRestricted
    case loading
    case web
    case error(NativeErrorPresentation)
}

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
        String(failure.diagnosticCode.prefix(15))
    }

    var displayAttemptId: String {
        String(failure.attemptId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    var diagnosticLine: String {
        "Код: NT · \(diagnosticCode) · \(displayAttemptId)"
    }

    var userExplanation: String {
        let explanation: String
        switch failure.serverCode {
        case "INVALID_CAR_TOKEN":
            explanation = "QR-код недействителен или истёк; требуется новый QR-код."
        case "UNKNOWN_USER":
            explanation = "Сервер не нашёл пользователя для этой привязки."
        case "CAR_ACCESS_DENIED":
            explanation = "Доступ к автомобилю запрещён."
        case "INVALID_SIGNATURE":
            explanation = "Сервер отклонил подпись запроса."
        case "TIMESTAMP_OUT_OF_RANGE":
            explanation = "Время запроса не соответствует времени сервера."
        case "RATE_LIMITED":
            explanation = "Слишком много запросов авторизации."
        case "AUTH_UNAVAILABLE", "INTERNAL_ERROR":
            explanation = "Сервис авторизации временно недоступен или завершился ошибкой."
        case "INVALID_REQUEST", "METHOD_NOT_ALLOWED", "UNSUPPORTED_MEDIA_TYPE":
            explanation = "Сервер отклонил формат запроса авторизации."
        default:
            explanation = fallbackExplanation
        }

        guard let serverCode = failure.serverCode, !serverCode.isEmpty else { return explanation }
        return "\(explanation) \(serverCode)"
    }

    private var fallbackExplanation: String {
        switch failure.kind {
        case .network:
            return failure.stage == .web
                ? "Не удалось загрузить веб-интерфейс."
                : "Не удалось подключиться к серверу авторизации."
        case .timeout:
            return failure.stage == .web
                ? "Истекло время ожидания загрузки веб-интерфейса."
                : "Истекло время ожидания ответа сервера авторизации."
        case .server:
            if failure.serverCode == nil, let status = failure.httpStatus {
                return "Сервер отклонил запрос (HTTP \(status))."
            }
            return "Сервер отклонил запрос."
        case .invalidResponse:
            return failure.stage == .web
                ? "Не удалось получить корректный ответ веб-интерфейса."
                : "Сервер прислал некорректный ответ."
        case .local:
            if failure.diagnosticCode == "KEYCHAIN" {
                return "Не удалось получить ключ авторизации."
            }
            if failure.diagnosticCode == "SIGNATURE" {
                return "Не удалось создать подпись запроса."
            }
            return switch failure.stage {
            case .web: "Не удалось загрузить веб-интерфейс."
            case .storage, .publication: "Не удалось сохранить регистрацию автомобиля."
            case .pair, .token: "Не удалось выполнить локальную операцию авторизации."
            }
        }
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
    case environment(target: AppEnvironment, previous: AppEnvironment, stage: EnvironmentSwitchStage, progress: OwnedCleanupProgress)
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
