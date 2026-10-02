import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticExecutorTests {
    @Test @MainActor func test_operation_deadline_includes_navigation_wait() async throws {
        let startedAt = ContinuousClock.now

        do {
            _ = try await DiagnosticOperation.run(
                timeout: .milliseconds(100),
                waitForNavigation: { _ in try await Task.sleep(for: .milliseconds(60)) },
                execute: { deadline in
                    try await Task.sleep(for: min(.milliseconds(60), deadline.remaining))
                    try deadline.ensureRemaining()
                    return JSONValue.bool(true)
                }
            )
            Issue.record("Expected one timeout to include navigation and evaluation")
        } catch let error as DiagnosticError {
            #expect(error == .timedOut(lastValue: nil))
        }

        #expect(startedAt.duration(to: .now) < .milliseconds(160))
    }

    @Test @MainActor func test_navigation_timeout_does_not_start_evaluator() async throws {
        var evaluatorStarted = false

        do {
            _ = try await DiagnosticOperation.run(
                timeout: .milliseconds(50),
                waitForNavigation: { _ in try await Task.sleep(for: .milliseconds(100)) },
                execute: { _ in
                    evaluatorStarted = true
                    return JSONValue.bool(true)
                }
            )
            Issue.record("Expected navigation to consume the operation deadline")
        } catch let error as DiagnosticError {
            #expect(error == .timedOut(lastValue: nil))
        }

        #expect(!evaluatorStarted)
    }

    @Test @MainActor func test_cancelled_queued_command_never_reaches_evaluator() async throws {
        let gate = AsyncCommandGate()
        var evaluated: [String] = []
        var completions: [String: DiagnosticExecutor.EvaluationCompletion] = [:]
        let executor = DiagnosticExecutor(gate: gate) { source, completion in
            evaluated.append(source)
            completions[source] = completion
        }

        let first = Task { try await executor.executeJavaScript("first", timeout: .seconds(3)) }
        try await waitUntil { evaluated.contains("first") }
        let second = Task { try await executor.executeJavaScript("second", timeout: .seconds(3)) }
        try await waitUntil { await gate.queuedWaiterCount == 1 }

        second.cancel()
        do {
            _ = try await second.value
            Issue.record("Expected queued command cancellation")
        } catch is CancellationError {
            #expect(true)
        }
        #expect(await gate.queuedWaiterCount == 0)
        #expect(evaluated == ["first"])

        completions["first"]?(.success("finished"))
        #expect(try await first.value == .string("finished"))
        await Task.yield()
        #expect(evaluated == ["first"])
    }

    @Test @MainActor func test_queued_command_timeout_never_reaches_evaluator() async throws {
        let gate = AsyncCommandGate()
        var evaluated: [String] = []
        var finishFirst: (@MainActor (Result<Any?, Error>) -> Void)?
        let executor = DiagnosticExecutor(gate: gate) { source, completion in
            evaluated.append(source)
            if source == "first" {
                finishFirst = completion
            }
        }

        let first = Task { try await executor.executeJavaScript("first", timeout: .seconds(3)) }
        try await waitUntil { evaluated.contains("first") }
        let second = Task { try await executor.executeJavaScript("second", timeout: .milliseconds(100)) }
        try await waitUntil { await gate.queuedWaiterCount == 1 }

        do {
            _ = try await second.value
            Issue.record("Expected queued command to use up its deadline")
        } catch let error as DiagnosticError {
            #expect(error == .timedOut(lastValue: nil))
        }
        #expect(await gate.queuedWaiterCount == 0)
        #expect(evaluated == ["first"])

        finishFirst?(.success("finished"))
        _ = try await first.value
        await Task.yield()
        #expect(evaluated == ["first"])
    }

    @Test @MainActor func test_cancel_after_permit_handoff_returns_permit() async throws {
        let barrier = AsyncGateHandoffBarrier()
        let gate = AsyncCommandGate(afterPermitHandoff: { await barrier.pause() })
        let deadline = DiagnosticDeadline(timeout: .seconds(2))
        try await gate.acquire(until: deadline)

        let queued = Task { try await gate.acquire(until: DiagnosticDeadline(timeout: .seconds(2))) }
        try await waitUntil { await gate.queuedWaiterCount == 1 }
        await gate.release()
        await barrier.waitUntilPaused()

        queued.cancel()
        await barrier.resume()
        do {
            try await queued.value
            Issue.record("Expected cancellation after permit handoff")
        } catch is CancellationError {
            #expect(true)
        }

        let next = Task {
            try await gate.acquire(until: DiagnosticDeadline(timeout: .seconds(1)))
            await gate.release()
        }
        try await next.value
    }

    @Test func test_replaced_navigation_ignores_old_finish_and_failure_callbacks() {
        var gate = NavigationCallbackGate<Int>()
        var isLoading = false
        var currentURL: URL?
        var navigationError: String?

        gate.replace(with: 1)
        _ = gate.applyIfCurrent(1) {
            isLoading = true
            currentURL = URL(string: "https://old.example")
        }
        gate.replace(with: 2)
        _ = gate.applyIfCurrent(2) {
            isLoading = true
            currentURL = URL(string: "https://new.example")
            navigationError = nil
        }

        let staleFinishApplied = gate.applyIfCurrent(1) {
            isLoading = false
            currentURL = URL(string: "https://old.example/finished")
        }
        let staleFailureApplied = gate.applyIfCurrent(1) {
            isLoading = false
            currentURL = URL(string: "https://old.example/error")
            navigationError = "stale failure"
        }

        #expect(!staleFinishApplied)
        #expect(!staleFailureApplied)
        #expect(isLoading)
        #expect(currentURL == URL(string: "https://new.example"))
        #expect(navigationError == nil)

        let adoptedUserNavigation = gate.beginIfCurrentOrAdopt(3) {
            isLoading = true
            currentURL = URL(string: "https://user-link.example")
            navigationError = nil
        }
        #expect(adoptedUserNavigation)
        #expect(gate.isCurrent(3))
        #expect(currentURL == URL(string: "https://user-link.example"))
    }

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

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DiagnosticError.timedOut(lastValue: nil) }
            try await Task.sleep(for: min(.milliseconds(5), remaining))
        }
    }
}

private final class HostedFixtureBundleMarker: NSObject {}

private actor AsyncGateHandoffBarrier {
    private var isPaused = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        while !isPaused { await Task.yield() }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
