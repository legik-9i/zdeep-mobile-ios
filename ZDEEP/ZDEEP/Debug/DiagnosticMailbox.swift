#if DEBUG
import Foundation

struct DiagnosticMailboxRequest: Decodable {
    let protocolVersion: Int
    let id: UUID
    let sessionId: String
    let deadline: TimeInterval
    let javascript: String

    static func decode(
        _ data: Data,
        activeSessionID: String,
        acceptedIDs: Set<UUID>,
        now: Date = Date()
    ) throws -> DiagnosticMailboxRequest {
        let request = try JSONDecoder().decode(DiagnosticMailboxRequest.self, from: data)
        guard request.protocolVersion == 1 else { throw DiagnosticMailboxError.unsupportedVersion }
        guard request.sessionId == activeSessionID else { throw DiagnosticMailboxError.staleSession }
        guard !acceptedIDs.contains(request.id) else { throw DiagnosticMailboxError.duplicateRequest }
        guard request.deadline.isFinite, request.deadline > now.timeIntervalSince1970,
              request.deadline <= now.addingTimeInterval(300).timeIntervalSince1970 else {
            throw DiagnosticMailboxError.invalidDeadline
        }
        guard !request.javascript.isEmpty, request.javascript.utf8.count <= 128_000 else {
            throw DiagnosticMailboxError.invalidJavaScript
        }
        return request
    }
}

struct DiagnosticMailboxReplayGuard {
    private var ids = Set<UUID>()

    var count: Int { ids.count }
    var acceptedIDs: Set<UUID> { ids }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func remember(_ id: UUID) {
        ids.insert(id)
    }
}

private enum DiagnosticMailboxError: LocalizedError {
    case unsupportedVersion
    case staleSession
    case duplicateRequest
    case invalidDeadline
    case invalidJavaScript

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Unsupported diagnostic protocol version"
        case .staleSession: "Diagnostic request targets an inactive WebView session"
        case .duplicateRequest: "Diagnostic request UUID was already accepted"
        case .invalidDeadline: "Diagnostic request deadline is invalid or expired"
        case .invalidJavaScript: "Diagnostic JavaScript source is empty or too large"
        }
    }
}

@MainActor
final class DiagnosticMailbox {
    private struct ErrorPayload: Encodable {
        let name: String
        let message: String
    }

    private struct Response: Encodable {
        let protocolVersion = 1
        let id: String
        let sessionId: String
        let ok: Bool
        let result: JSONValue?
        let error: ErrorPayload?
    }

    private struct SessionStatus: Encodable {
        let protocolVersion = 1
        let sessionId: String
        let environment: String
        let url: String?
        let updatedAt: TimeInterval
        let ready = true
    }

    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ZdeepDiagnostics", isDirectory: true)
    private let inbox = directory.appendingPathComponent("inbox", isDirectory: true)
    private let outbox = directory.appendingPathComponent("outbox", isDirectory: true)
    private let session: WebSession
    private let environment: AppEnvironment
    private let eventStore: DiagnosticEventStore
    private var pollTask: Task<Void, Never>?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var stoppedTasks: [Task<Void, Never>] = []
    private var replayGuard = DiagnosticMailboxReplayGuard()
    private var inFlightIDs = Set<UUID>()

    init(session: WebSession, environment: AppEnvironment, eventStore: DiagnosticEventStore) {
        self.session = session
        self.environment = environment
        self.eventStore = eventStore
    }

    static func removeStaleHandshake() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("session.json"))
    }

    nonisolated static func cleanupAcknowledgedFiles(inbox: URL, outbox: URL, requestID: String) -> Bool {
        guard let id = UUID(uuidString: requestID)?.uuidString.lowercased() else { return false }
        let acknowledgement = inbox.appendingPathComponent("\(id).ack.uploading")
        let acknowledgementMarker = inbox.appendingPathComponent("\(id).ack.ready")
        let response = outbox.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: acknowledgementMarker.path),
              FileManager.default.fileExists(atPath: response.path),
              let acknowledgementData = try? Data(contentsOf: acknowledgement),
              String(data: acknowledgementData, encoding: .utf8) == id else { return false }

        let pendingFiles = [
            inbox.appendingPathComponent("\(id).uploading"),
            inbox.appendingPathComponent("\(id).ready"),
            acknowledgement,
            response
        ]
        do {
            for url in pendingFiles where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.removeItem(at: acknowledgementMarker)
            return true
        } catch {
            return false
        }
    }

    func start() {
        guard pollTask == nil, !session.isClosed else { return }
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            publishHandshake()
            pollTask = Task { [weak self] in await self?.poll() }
        } catch {
            eventStore.record(category: "usb.mailbox.start.failed", operationID: session.id.uuidString)
        }
    }

    func stop() {
        if let pollTask {
            pollTask.cancel()
            stoppedTasks.append(pollTask)
        }
        pollTask = nil
        for task in commandTasks.values {
            task.cancel()
            stoppedTasks.append(task)
        }
        commandTasks.removeAll()
        inFlightIDs.removeAll()
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("session.json"))
    }

    func waitUntilStopped() async {
        let tasks = stoppedTasks
        stoppedTasks.removeAll()
        for task in tasks { await task.value }
    }

    private func poll() async {
        while !Task.isCancelled, !session.isClosed {
            autoreleasepool {
                publishHandshake()
                consumeAcknowledgements()
                consumeReadyRequests()
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { break }
        }
    }

    private func publishHandshake() {
        let status = SessionStatus(
            sessionId: session.id.uuidString.lowercased(),
            environment: environment.rawValue,
            url: sanitizedURL(session.currentURL),
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder.sorted.encode(status) else { return }
        try? data.write(to: Self.directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func consumeReadyRequests() {
        guard let markers = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for marker in markers where marker.lastPathComponent.hasSuffix(".ready") {
            guard !Task.isCancelled,
                  let uuid = UUID(uuidString: String(marker.lastPathComponent.dropLast(".ready".count))) else { continue }
            let responseURL = outbox.appendingPathComponent("\(uuid.uuidString.lowercased()).json")
            guard !FileManager.default.fileExists(atPath: responseURL.path) else { continue }
            guard !inFlightIDs.contains(uuid) else { continue }
            let requestURL = inbox.appendingPathComponent("\(uuid.uuidString.lowercased()).uploading")
            guard let data = try? Data(contentsOf: requestURL) else { continue }
            do {
                let request = try DiagnosticMailboxRequest.decode(
                    data,
                    activeSessionID: session.id.uuidString.lowercased(),
                    acceptedIDs: replayGuard.acceptedIDs
                )
                guard UUID(uuidString: marker.deletingPathExtension().lastPathComponent) == request.id else {
                    throw DiagnosticMailboxError.invalidJavaScript
                }
                replayGuard.remember(request.id)
                inFlightIDs.insert(request.id)
                commandTasks[request.id] = Task { [weak self] in await self?.execute(request) }
            } catch {
                write(Response(
                    id: uuid.uuidString.lowercased(),
                    sessionId: session.id.uuidString.lowercased(),
                    ok: false,
                    result: nil,
                    error: ErrorPayload(name: "DiagnosticRequestError", message: error.localizedDescription)
                ), to: responseURL)
                eventStore.record(category: "usb.command.rejected", operationID: uuid.uuidString.lowercased())
            }
        }
    }

    private func execute(_ request: DiagnosticMailboxRequest) async {
        defer {
            inFlightIDs.remove(request.id)
            commandTasks.removeValue(forKey: request.id)
        }
        guard !session.isClosed, request.sessionId == session.id.uuidString.lowercased() else { return }
        let responseURL = outbox.appendingPathComponent("\(request.id.uuidString.lowercased()).json")
        guard !FileManager.default.fileExists(atPath: responseURL.path) else { return }
        let remaining = max(0.001, request.deadline - Date().timeIntervalSince1970)
        do {
            let result = try await session.executeJavaScript(request.javascript, timeout: .seconds(remaining))
            guard !session.isClosed else { return }
            write(Response(
                id: request.id.uuidString.lowercased(),
                sessionId: request.sessionId,
                ok: true,
                result: result,
                error: nil
            ), to: responseURL)
            eventStore.record(category: "usb.command.completed", operationID: request.id.uuidString.lowercased())
        } catch {
            guard !session.isClosed else { return }
            write(Response(
                id: request.id.uuidString.lowercased(),
                sessionId: request.sessionId,
                ok: false,
                result: nil,
                error: ErrorPayload(name: "JavaScriptError", message: error.localizedDescription)
            ), to: responseURL)
            eventStore.record(category: "usb.command.failed", operationID: request.id.uuidString.lowercased())
        }
    }

    private func consumeAcknowledgements() {
        guard let markers = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for marker in markers where marker.lastPathComponent.hasSuffix(".ack.ready") {
            let id = String(marker.lastPathComponent.dropLast(".ack.ready".count))
            guard UUID(uuidString: id) != nil else { continue }
            if Self.cleanupAcknowledgedFiles(inbox: inbox, outbox: outbox, requestID: id) {
                eventStore.record(category: "usb.command.acknowledged", operationID: id)
            }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.sorted.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func sanitizedURL(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
#endif
