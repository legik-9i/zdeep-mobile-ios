import Foundation

enum SessionRefreshPolicy {
    private static let refreshLead = Duration.seconds(120)
    private static let retryDelays: [Duration] = [
        .seconds(5), .seconds(10), .seconds(20), .seconds(30), .seconds(30)
    ]

    static func refreshDeadline(for session: AuthSession) -> Duration {
        session.deadline - refreshLead
    }

    static func retryDelay(failureCount: Int) -> Duration {
        let index = min(max(1, failureCount) - 1, retryDelays.count - 1)
        return retryDelays[index]
    }
}
