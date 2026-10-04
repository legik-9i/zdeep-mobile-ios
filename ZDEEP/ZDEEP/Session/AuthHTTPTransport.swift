import Foundation

@MainActor
protocol AuthHTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func cancelCurrentRequest()
}

@MainActor
final class URLSessionAuthHTTPTransport: AuthHTTPTransport {
    private let session: URLSession
    private var currentTask: Task<(Data, URLResponse), Error>?
    private var currentTaskId: UUID?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RedirectBlockingDelegate(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let taskId = UUID()
        let task = Task { try await session.data(for: request) }
        currentTaskId = taskId
        currentTask = task
        defer {
            if currentTaskId == taskId {
                currentTaskId = nil
                currentTask = nil
            }
        }
        let (data, response) = try await task.value
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    func cancelCurrentRequest() {
        currentTask?.cancel()
        currentTask = nil
        currentTaskId = nil
    }
}

nonisolated private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
