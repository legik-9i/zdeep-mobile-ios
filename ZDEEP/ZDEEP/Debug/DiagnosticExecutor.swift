import Foundation
import WebKit

private actor AsyncCommandGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class DiagnosticExecutor {
    typealias Evaluator = @MainActor (
        _ source: String,
        _ completion: @escaping @MainActor (Result<Any?, Error>) -> Void
    ) -> Void

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
    private let commandGate = AsyncCommandGate()
    private var pendingCommands: [UUID: PendingCommand] = [:]
    private var pageGeneration = 0
    private var isClosed = false

    init(evaluator: @escaping Evaluator) {
        self.evaluate = evaluator
    }

    func executeJavaScript(_ source: String, timeout: Duration) async throws -> JSONValue {
        await commandGate.acquire()
        do {
            try ensureActive()
            let generation = pageGeneration
            let value = try await evaluateOne(source, timeout: timeout, lastValue: nil)
            try ensureCurrentPage(generation)
            guard let value else {
                throw DiagnosticError.nonSerializableResult("JavaScript returned undefined")
            }
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
        await commandGate.acquire()
        do {
            try ensureActive()
            let generation = pageGeneration
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var lastValue: JSONValue?
            while true {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw DiagnosticError.timedOut(lastValue: lastValue)
                }

                let value = try await evaluateOne(source, timeout: remaining, lastValue: lastValue)
                try ensureCurrentPage(generation)
                guard let value else {
                    throw DiagnosticError.nonSerializableResult("JavaScript returned undefined")
                }
                let json = try JSONValue(anyValue: value)
                lastValue = json
                if json == expected {
                    await commandGate.release()
                    return json
                }

                let nextDelay = min(.milliseconds(100), ContinuousClock.now.duration(to: deadline))
                guard nextDelay > .zero else {
                    throw DiagnosticError.timedOut(lastValue: lastValue)
                }
                try await Task.sleep(for: nextDelay)
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

    private func evaluateOne(_ source: String, timeout: Duration, lastValue: JSONValue?) async throws -> Any? {
        try ensureActive()
        guard timeout > .zero else {
            throw DiagnosticError.timedOut(lastValue: lastValue)
        }
        let command = DiagnosticCommand(source: source)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let pending = PendingCommand(command: command, continuation: continuation)
                pendingCommands[command.id] = pending
                pending.timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(command.id, with: .failure(DiagnosticError.timedOut(lastValue: lastValue)))
                }
                evaluate(source) { [weak self] result in
                    guard let self else { return }
                    self.finish(command.id, with: result)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(command.id, with: .failure(CancellationError()))
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
        for id in Array(pendingCommands.keys) {
            finish(id, with: .failure(error))
        }
    }

    private func ensureActive() throws {
        guard !isClosed else { throw DiagnosticError.sessionClosed }
    }

    private func ensureCurrentPage(_ generation: Int) throws {
        try ensureActive()
        guard generation == pageGeneration else { throw DiagnosticError.pageChanged }
    }
}
