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
            serverCode: "UNKNOWN_SERVER_FAILURE_CODE"
        ))

        #expect(presentation.diagnosticCode == "UNKNOWN_SERVER_")
        #expect(presentation.diagnosticCode.count <= 15)
    }

    @Test func test_attempt_id_is_eight_hex_characters_without_dashes() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!
        let presentation = NativeErrorPresentation.initialRegistrationFailure(Self.failure(attemptId: id))

        #expect(presentation.displayAttemptId == "a1b2c3d4")
        #expect(presentation.displayAttemptId.count == 8)
        #expect(!presentation.displayAttemptId.contains("-"))
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
        serverCode: String? = "BAD_RESPONSE"
    ) -> AuthFailure {
        AuthFailure(
            kind: .server,
            stage: .pair,
            attemptId: attemptId,
            message: "Безопасная ошибка",
            serverCode: serverCode,
            diagnosticCode: "BAD_RESPONSE"
        )
    }
}
