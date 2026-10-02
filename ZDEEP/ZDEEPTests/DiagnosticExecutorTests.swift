import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticExecutorTests {
    @Test @MainActor func test_executor_timeout_includes_last_value() async throws {
        let executor = DiagnosticExecutor { _, _ in }

        do {
            _ = try await executor.waitForJavaScript(
                "false",
                equals: .bool(true),
                timeout: .milliseconds(40)
            )
            Issue.record("Expected JavaScript polling to time out")
        } catch let error as DiagnosticError {
            #expect(error == .timedOut(lastValue: nil))
        }
    }

    @Test @MainActor func test_cancelled_javascript_resolves_without_waiting_for_timeout() async throws {
        var finishEvaluation: (@MainActor (Result<Any?, Error>) -> Void)?
        let executor = DiagnosticExecutor { _, completion in
            finishEvaluation = completion
        }
        let command = Task {
            try await executor.executeJavaScript("'late'", timeout: .seconds(5))
        }

        try await Task.sleep(for: .milliseconds(30))
        command.cancel()

        do {
            _ = try await command.value
            Issue.record("Expected cancellation to end JavaScript evaluation")
        } catch is CancellationError {
            #expect(true)
        }

        finishEvaluation?(.success("late"))
    }

    @Test @MainActor func test_navigation_rejects_pending_javascript_result() async throws {
        var finishEvaluation: (@MainActor (Result<Any?, Error>) -> Void)?
        let executor = DiagnosticExecutor { _, completion in
            finishEvaluation = completion
        }
        let command = Task {
            try await executor.executeJavaScript("'old page'", timeout: .seconds(5))
        }

        try await Task.sleep(for: .milliseconds(30))
        executor.navigationDidStart()
        do {
            _ = try await command.value
            Issue.record("Expected navigation to reject the old page result")
        } catch let error as DiagnosticError {
            #expect(error == .pageChanged)
        }

        finishEvaluation?(.success("stale"))
    }

    @Test @MainActor func test_closed_executor_rejects_pending_javascript_result() async throws {
        let executor = DiagnosticExecutor { _, _ in }
        let command = Task {
            try await executor.executeJavaScript("'pending'", timeout: .seconds(5))
        }

        try await Task.sleep(for: .milliseconds(30))
        executor.close()
        do {
            _ = try await command.value
            Issue.record("Expected closing the session to reject a pending result")
        } catch let error as DiagnosticError {
            #expect(error == .sessionClosed)
        }
    }

    @Test func test_json_value_codable_preserves_nested_types() throws {
        let value: JSONValue = .object([
            "name": .string("Zdeep"),
            "active": .bool(true),
            "count": .number(3),
            "items": .array([.null, .string("ready")])
        ])

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(decoded == value)
    }

    @Test func test_json_value_rejects_non_json_result() throws {
        #expect(throws: DiagnosticError.self) {
            try JSONValue(anyValue: Date(timeIntervalSince1970: 0))
        }

        #expect(throws: DiagnosticError.self) {
            try JSONValue(anyValue: ["value": Double.infinity])
        }
    }

    @Test @MainActor func test_document_script_sees_native_object_at_document_start() async throws {
        let session = WebSession()
        defer { session.close() }
        let fixture = try #require(
            Bundle(for: HostedFixtureBundleMarker.self).url(
                forResource: "document-start",
                withExtension: "html"
            )
        )

        session.load(url: fixture)
        _ = try await session.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(5)
        )
        #expect(session.currentURL?.standardizedFileURL == fixture.standardizedFileURL)
        let injectedValue = try await session.executeJavaScript(
            "document.documentElement.dataset.nativeObject",
            timeout: .seconds(5)
        )
        let objectKeys = try await session.executeJavaScript(
            "document.documentElement.dataset.nativeObjectKeys",
            timeout: .seconds(5)
        )
        let subframeType = try await session.waitForJavaScript(
            "document.querySelector('iframe')?.contentWindow.document.documentElement.dataset.nativeObject ?? 'not-ready'",
            equals: .string("undefined"),
            timeout: .seconds(5)
        )

        #expect(injectedValue == .string("object"))
        #expect(objectKeys == .string("0"))
        #expect(subframeType == .string("undefined"))
    }

    @Test @MainActor func test_failed_navigation_returns_navigation_error() async throws {
        let session = WebSession()
        defer { session.close() }
        let missingFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("html")

        session.load(url: missingFixture)

        do {
            _ = try await session.executeJavaScript("true", timeout: .seconds(5))
            Issue.record("Expected a missing local document to fail navigation")
        } catch let error as DiagnosticError {
            guard case .navigationFailed = error else {
                Issue.record("Unexpected error for failed navigation: \(error)")
                return
            }
        }
    }
}

private final class HostedFixtureBundleMarker: NSObject {}
