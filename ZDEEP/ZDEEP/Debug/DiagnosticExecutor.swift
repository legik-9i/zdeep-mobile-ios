import Foundation
import WebKit

struct DiagnosticDeadline: Sendable {
    private let instant: ContinuousClock.Instant

    init(timeout: Duration) {
        instant = ContinuousClock.now.advanced(by: max(.zero, timeout))
    }

    nonisolated var remaining: Duration { max(.zero, ContinuousClock.now.duration(to: instant)) }

    nonisolated func ensureRemaining(lastValue: JSONValue? = nil) throws {
        try Task.checkCancellation()
        guard remaining > .zero else { throw DiagnosticError.timedOut(lastValue: lastValue) }
    }
}

@MainActor
enum DiagnosticOperation {
    static func run<Value>(
        timeout: Duration,
        waitForNavigation: (DiagnosticDeadline) async throws -> Void,
        execute: (DiagnosticDeadline) async throws -> Value
    ) async throws -> Value {
        let deadline = DiagnosticDeadline(timeout: timeout)
        try deadline.ensureRemaining()
        try await waitForNavigation(deadline)
        try deadline.ensureRemaining()
        return try await execute(deadline)
    }
}

actor AsyncCommandGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var isHeld = false
    private var waiters: [Waiter] = []
    private let afterPermitHandoff: (@Sendable () async -> Void)?
    var queuedWaiterCount: Int { waiters.count }

    init(afterPermitHandoff: (@Sendable () async -> Void)? = nil) {
        self.afterPermitHandoff = afterPermitHandoff
    }

    func acquire(until deadline: DiagnosticDeadline) async throws {
        try Task.checkCancellation()
        try deadline.ensureRemaining()
        guard isHeld else {
            isHeld = true
            return
        }

        let id = UUID()
        var acquired = false
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let waiter = Waiter(id: id, continuation: continuation)
                    waiters.append(waiter)
                    let delay = deadline.remaining
                    waiters[waiters.count - 1].timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: delay) } catch { return }
                        await self?.expire(id)
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            acquired = true
            if let afterPermitHandoff { await afterPermitHandoff() }
            try Task.checkCancellation()
            try deadline.ensureRemaining()
        } catch {
            // A waiter can receive the permit just as its task is cancelled or
            // its deadline expires. Return that permit before propagating.
            if acquired { release() }
            throw error
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
            return
        }
        isHeld = false
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: DiagnosticError.timedOut(lastValue: nil))
    }
}

@MainActor
final class DiagnosticExecutor {
    typealias EvaluationCompletion = @MainActor (Result<Any?, Error>) -> Void
    typealias Evaluator = @MainActor (_ source: String, _ completion: @escaping EvaluationCompletion) -> Void

    private final class PendingCommand {
        let command: DiagnosticCommand
        let continuation: CheckedContinuation<Any?, Error>
        var timeoutTask: Task<Void, Never>?

        init(command: DiagnosticCommand, continuation: CheckedContinuation<Any?, Error>) {
            self.command = command
            self.continuation = continuation
        }
    }

    private let evaluate: Evaluator
    private let commandGate: AsyncCommandGate
    private var pendingCommands: [UUID: PendingCommand] = [:]
    private var pageGeneration = 0
    private var isClosed = false

    init(gate: AsyncCommandGate = AsyncCommandGate(), evaluator: @escaping Evaluator) {
        self.commandGate = gate
        self.evaluate = evaluator
    }

    func executeJavaScript(_ source: String, timeout: Duration) async throws -> JSONValue {
        try await executeJavaScript(source, deadline: DiagnosticDeadline(timeout: timeout))
    }

    func executeJavaScript(_ source: String, deadline: DiagnosticDeadline) async throws -> JSONValue {
        try await commandGate.acquire(until: deadline)
        do {
            try deadline.ensureRemaining()
            try ensureActive()
            let generation = pageGeneration
            guard let value = try await evaluateOne(source, deadline: deadline, lastValue: nil) else {
                throw DiagnosticError.nonSerializableResult("JavaScript returned undefined")
            }
            try deadline.ensureRemaining()
            try ensureCurrentPage(generation)
            let json = try JSONValue(anyValue: value)
            await commandGate.release()
            return json
        } catch {
            await commandGate.release()
            throw error
        }
    }

    func waitForJavaScript(
        _ source: String,
        equals expected: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        try await waitForJavaScript(source, equals: expected, deadline: DiagnosticDeadline(timeout: timeout))
    }

    func waitForJavaScript(
        _ source: String,
        equals expected: JSONValue,
        deadline: DiagnosticDeadline
    ) async throws -> JSONValue {
        try await commandGate.acquire(until: deadline)
        do {
            try deadline.ensureRemaining()
            try ensureActive()
            let generation = pageGeneration
            var lastValue: JSONValue?
            while true {
                try deadline.ensureRemaining(lastValue: lastValue)
                guard let value = try await evaluateOne(source, deadline: deadline, lastValue: lastValue) else {
                    throw DiagnosticError.nonSerializableResult("JavaScript returned undefined")
                }
                try deadline.ensureRemaining(lastValue: lastValue)
                try ensureCurrentPage(generation)
                let json = try JSONValue(anyValue: value)
                lastValue = json
                if json == expected {
                    await commandGate.release()
                    return json
                }
                let delay = min(.milliseconds(100), deadline.remaining)
                guard delay > .zero else { throw DiagnosticError.timedOut(lastValue: lastValue) }
                try await Task.sleep(for: delay)
            }
        } catch {
            await commandGate.release()
            throw error
        }
    }

    func navigationDidStart() {
        pageGeneration += 1
        resolvePendingCommands(with: DiagnosticError.pageChanged)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        resolvePendingCommands(with: DiagnosticError.sessionClosed)
    }

    private func evaluateOne(_ source: String, deadline: DiagnosticDeadline, lastValue: JSONValue?) async throws -> Any? {
        try ensureActive()
        try deadline.ensureRemaining(lastValue: lastValue)
        let command = DiagnosticCommand(source: source)
        let timeout = deadline.remaining
        let executor = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let pending = PendingCommand(command: command, continuation: continuation)
                pendingCommands[command.id] = pending
                pending.timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(command.id, with: .failure(DiagnosticError.timedOut(lastValue: lastValue)))
                }
                evaluate(source) { [weak self] result in self?.finish(command.id, with: result) }
            }
        } onCancel: { [executor] in
            Task { @MainActor [executor] in
                executor.finish(command.id, with: .failure(CancellationError()))
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<Any?, Error>) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        pending.timeoutTask?.cancel()
        switch result {
        case .success:
            pending.continuation.resume(with: result)
        case .failure(let error):
            if let diagnosticError = error as? DiagnosticError {
                pending.continuation.resume(throwing: diagnosticError)
            } else if error is CancellationError {
                pending.continuation.resume(throwing: CancellationError())
            } else {
                pending.continuation.resume(throwing: DiagnosticError.javascriptExecutionFailed(error.localizedDescription))
            }
        }
    }

    private func resolvePendingCommands(with error: DiagnosticError) {
        for id in Array(pendingCommands.keys) { finish(id, with: .failure(error)) }
    }

    private func ensureActive() throws {
        guard !isClosed else { throw DiagnosticError.sessionClosed }
    }

    private func ensureCurrentPage(_ generation: Int) throws {
        try ensureActive()
        guard generation == pageGeneration else { throw DiagnosticError.pageChanged }
    }
}
