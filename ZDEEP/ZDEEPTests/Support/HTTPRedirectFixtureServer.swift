import Foundation
import Network

final class HTTPRedirectFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "zdeep.tests.http-redirect-fixture")
    private let location: URL

    init(location: URL) throws {
        self.location = location
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [location, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                let response = Data(
                    "HTTP/1.1 302 Found\r\nLocation: \(location.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
                )
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        continuation.resume(throwing: FixtureError.missingPort)
                        listener.stateUpdateHandler = nil
                        return
                    }
                    continuation.resume(returning: URL(string: "http://localhost:\(port.rawValue)/redirect")!)
                    listener.stateUpdateHandler = nil
                case .failed(let error):
                    continuation.resume(throwing: error)
                    listener.stateUpdateHandler = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
    }

    private enum FixtureError: Error {
        case missingPort
    }
}
