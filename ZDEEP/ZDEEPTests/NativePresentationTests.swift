import Foundation
import Testing
@testable import ZDEEP

struct NativePresentationTests {
    @Test func test_error_actions_follow_retry_context() throws {
        let failure = Self.failure()
        let binding = RegisteredBinding(
            bindingId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            publicCertificate: "synthetic-public-certificate",
            carId: "synthetic-car"
        )
        let cases: [(String, NativeErrorPresentation, [NativeErrorAction])] = [
            ("initial registration", .initialRegistrationFailure(failure), [.startOver]),
            ("restore", .retryable(failure, context: .restore), [.retry, .reset]),
            ("registered authorization", .retryable(failure, context: .authorization(binding)), [.retry, .rebind]),
            ("registered web", .retryable(failure, context: .web(
                url: URL(string: "http://localhost:4005")!,
                bindingId: binding.bindingId,
                reason: .initial
            )), [.retry, .rebind]),
            ("cleanup", .retryable(failure, context: .cleanup(reason: .failedRegistration, next: .restoreThenWelcome)), [.retry])
        ]

        for (name, presentation, expectedActions) in cases {
            #expect(presentation.actions == expectedActions, "\(name)")
        }
    }

    @Test func test_diagnostic_code_is_capped_at_fifteen_characters() {
        let presentation = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            serverCode: "CAR_ACCESS_DENIED",
            diagnosticCode: "HTTP_403"
        ))

        #expect(presentation.diagnosticCode == "HTTP_403")
        #expect(presentation.diagnosticCode.count <= 15)
        #expect(presentation.diagnosticLine == "Код: NT · HTTP_403 · A1B2C3D4")
        #expect(presentation.userExplanation == "Доступ к автомобилю запрещён. CAR_ACCESS_DENIED")

        let longCode = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            serverCode: "CAR_ACCESS_DENIED",
            diagnosticCode: "DIAGNOSTIC_CODE_TOO_LONG"
        ))
        #expect(longCode.diagnosticCode == "DIAGNOSTIC_CODE")
        #expect(longCode.diagnosticCode.count == 15)
    }

    @Test func test_attempt_id_is_eight_hex_characters_without_dashes() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!
        let presentation = NativeErrorPresentation.initialRegistrationFailure(Self.failure(attemptId: id))

        #expect(presentation.displayAttemptId == "A1B2C3D4")
        #expect(presentation.displayAttemptId.count == 8)
        #expect(!presentation.displayAttemptId.contains("-"))
    }

    @Test func test_knownServerCodes_mapToSafeRussianExplanations() {
        let mappings: [(String, String)] = [
            ("INVALID_CAR_TOKEN", "QR-код недействителен или истёк; требуется новый QR-код."),
            ("UNKNOWN_USER", "Сервер не нашёл пользователя для этой привязки."),
            ("CAR_ACCESS_DENIED", "Доступ к автомобилю запрещён."),
            ("INVALID_SIGNATURE", "Сервер отклонил подпись запроса."),
            ("TIMESTAMP_OUT_OF_RANGE", "Время запроса не соответствует времени сервера."),
            ("RATE_LIMITED", "Слишком много запросов авторизации."),
            ("AUTH_UNAVAILABLE", "Сервис авторизации временно недоступен или завершился ошибкой."),
            ("INTERNAL_ERROR", "Сервис авторизации временно недоступен или завершился ошибкой."),
            ("INVALID_REQUEST", "Сервер отклонил формат запроса авторизации."),
            ("METHOD_NOT_ALLOWED", "Сервер отклонил формат запроса авторизации."),
            ("UNSUPPORTED_MEDIA_TYPE", "Сервер отклонил формат запроса авторизации.")
        ]

        for (code, explanation) in mappings {
            let failure = Self.failure(
                serverCode: code,
                message: "Raw English server message must not be shown"
            )
            #expect(NativeErrorPresentation.initialRegistrationFailure(failure).userExplanation == "\(explanation) \(code)")
        }
    }

    @Test func test_unknownCode_isPreservedAndMissingCodeUsesGenericHttpExplanation() {
        let unknown = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            serverCode: "UNKNOWN_SERVER_FAILURE_CODE",
            message: "Raw English response body must not be shown"
        ))
        #expect(unknown.userExplanation == "Сервер отклонил запрос. UNKNOWN_SERVER_FAILURE_CODE")
        #expect(!unknown.userExplanation.contains("Raw English"))

        let missing = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            serverCode: nil,
            diagnosticCode: "HTTP_503",
            message: "Raw English response body must not be shown",
            httpStatus: 503
        ))
        #expect(missing.userExplanation == "Сервер отклонил запрос (HTTP 503).")
        #expect(!missing.userExplanation.contains("Raw English"))
    }

    @Test func test_networkTimeoutAndLocalFailuresUseStageSpecificRussianMessages() {
        let network = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            kind: .network,
            stage: .pair,
            serverCode: nil,
            message: "Raw English network error",
        ))
        #expect(network.userExplanation == "Не удалось подключиться к серверу авторизации.")

        let timeout = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            kind: .timeout,
            stage: .web,
            serverCode: nil,
            message: "Raw English timeout",
        ))
        #expect(timeout.userExplanation == "Истекло время ожидания загрузки веб-интерфейса.")

        let keychain = NativeErrorPresentation.initialRegistrationFailure(Self.failure(
            kind: .local,
            stage: .storage,
            serverCode: nil,
            diagnosticCode: "KEYCHAIN",
            message: "Raw English keychain error",
        ))
        #expect(keychain.userExplanation == "Не удалось получить ключ авторизации.")
    }

    @Test func test_app_version_uses_short_version_and_build_number() {
        let presentation = NativeErrorPresentation.initialRegistrationFailure(Self.failure())
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let expected: String
        if shortVersion.isEmpty { expected = build }
        else if build.isEmpty { expected = shortVersion }
        else { expected = "\(shortVersion) (\(build))" }

        #expect(presentation.appVersion == expected)
    }

    private static func failure(
        attemptId: UUID = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!,
        kind: AuthErrorKind = .server,
        stage: AuthStage = .pair,
        serverCode: String? = "BAD_RESPONSE",
        diagnosticCode: String = "BAD_RESPONSE",
        message: String = "Безопасная ошибка",
        httpStatus: Int? = 403
    ) -> AuthFailure {
        AuthFailure(
            kind: kind,
            stage: stage,
            attemptId: attemptId,
            message: message,
            httpStatus: httpStatus,
            serverCode: serverCode,
            diagnosticCode: diagnosticCode
        )
    }
}
