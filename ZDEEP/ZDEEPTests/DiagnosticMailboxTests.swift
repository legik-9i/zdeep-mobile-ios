import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticMailboxTests {
    @Test func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) {
            try DiagnosticMailboxRequest.decode(
                Data("{bad".utf8),
                activeSessionID: "active-session",
                acceptedIDs: [],
                now: Date()
            )
        }
    }

    @Test func duplicateUUIDIsRejected() throws {
        let id = UUID()
        let request = makeRequest(id: id, sessionID: "active-session", deadline: Date().addingTimeInterval(30))
        #expect(throws: (any Error).self) {
            try DiagnosticMailboxRequest.decode(
                request,
                activeSessionID: "active-session",
                acceptedIDs: [id],
                now: Date()
            )
        }
    }

    @Test func staleSessionIsRejected() {
        let request = makeRequest(id: UUID(), sessionID: "old-session", deadline: Date().addingTimeInterval(30))
        #expect(throws: (any Error).self) {
            try DiagnosticMailboxRequest.decode(
                request,
                activeSessionID: "active-session",
                acceptedIDs: [],
                now: Date()
            )
        }
    }

    @Test func expiredRequestIsRejected() {
        let now = Date()
        let request = makeRequest(id: UUID(), sessionID: "active-session", deadline: now.addingTimeInterval(-1))
        #expect(throws: (any Error).self) {
            try DiagnosticMailboxRequest.decode(
                request,
                activeSessionID: "active-session",
                acceptedIDs: [],
                now: now
            )
        }
    }

    @Test func acceptedRequestUUIDsRemainRejectedAfterMoreThan128Commands() {
        var replayGuard = DiagnosticMailboxReplayGuard()
        let ids = (0..<129).map { _ in UUID() }
        for id in ids {
            replayGuard.remember(id)
        }

        #expect(replayGuard.count == 129)
        #expect(replayGuard.contains(ids[0]))
    }

    @Test func acknowledgementRemovesCopiedResponseAndRequestFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = directory.appendingPathComponent("inbox", isDirectory: true)
        let outbox = directory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        for url in [
            inbox.appendingPathComponent("\(id).uploading"),
            inbox.appendingPathComponent("\(id).ready"),
            inbox.appendingPathComponent("\(id).ack.uploading"),
            inbox.appendingPathComponent("\(id).ack.ready"),
            outbox.appendingPathComponent("\(id).json")
        ] {
            try Data(id.utf8).write(to: url)
        }

        #expect(DiagnosticMailbox.cleanupAcknowledgedFiles(inbox: inbox, outbox: outbox, requestID: id))

        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).uploading").path))
        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).ready").path))
        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).ack.ready").path))
        #expect(!FileManager.default.fileExists(atPath: outbox.appendingPathComponent("\(id).json").path))
    }

    @Test func acknowledgementCannotDeleteRequestWithoutResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = directory.appendingPathComponent("inbox", isDirectory: true)
        let outbox = directory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        for suffix in ["uploading", "ready", "ack.uploading", "ack.ready"] {
            let body = suffix == "ack.uploading" ? id : "request"
            try Data(body.utf8).write(to: inbox.appendingPathComponent("\(id).\(suffix)"))
        }

        #expect(!DiagnosticMailbox.cleanupAcknowledgedFiles(inbox: inbox, outbox: outbox, requestID: id))
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).uploading").path))
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).ack.ready").path))
    }

    private func makeRequest(id: UUID, sessionID: String, deadline: Date) -> Data {
        let object: [String: Any] = [
            "protocolVersion": 1,
            "id": id.uuidString.lowercased(),
            "sessionId": sessionID,
            "deadline": deadline.timeIntervalSince1970,
            "javascript": "1+1"
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
