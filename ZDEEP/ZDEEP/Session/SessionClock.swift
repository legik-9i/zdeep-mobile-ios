import Foundation

@MainActor
protocol SessionClock: AnyObject {
    var now: Duration { get }
    var wallTimeMs: Double { get }
    func schedule(at deadline: Duration, action: @escaping @MainActor () -> Void) -> any CancellationHandle
}

@MainActor
final class ContinuousSessionClock: SessionClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: Duration { origin.duration(to: clock.now) }
    var wallTimeMs: Double { Date().timeIntervalSince1970 * 1_000 }

    func schedule(at deadline: Duration, action: @escaping @MainActor () -> Void) -> any CancellationHandle {
        let target = origin.advanced(by: deadline)
        let task = Task { @MainActor [clock] in
            do {
                try await clock.sleep(until: target)
                action()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        return ClockTaskCancellationHandle(task)
    }
}

@MainActor
private final class ClockTaskCancellationHandle: CancellationHandle {
    private var task: Task<Void, Never>?

    init(_ task: Task<Void, Never>) { self.task = task }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
