import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticEventStoreTests {
    @Test func test_suspended_journal_does_not_write_until_cleanup_completes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let store = DiagnosticEventStore(fileURL: fileURL)

        store.suspendWrites()
        store.record(category: "cleanup.inProgress")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        store.resumeWrites()
        store.record(category: "cleanup.completed")
        #expect(store.snapshot().map(\.category) == ["cleanup.completed"])
    }

    @Test func test_secrets_are_removed_from_fields_and_urls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiagnosticEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        store.record(category: "navigation", operationID: "op-1", fields: [
            "url": "https://user:password-value@example.test/path?access_token=secret-value&mode=ok#apiKey=fragment-secret&auth=fragment-auth",
            "authorization": "Bearer do-not-store",
            "apiKey": "api-key-secret",
            "auth": "auth-field-secret",
            "message": "https://example.test/?token=inline-secret"
        ])

        let exported = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!exported.contains("secret-value"))
        #expect(!exported.contains("do-not-store"))
        #expect(!exported.contains("inline-secret"))
        #expect(!exported.contains("password-value"))
        #expect(!exported.contains("fragment-secret"))
        #expect(!exported.contains("fragment-auth"))
        #expect(!exported.contains("api-key-secret"))
        #expect(!exported.contains("auth-field-secret"))
        #expect(exported.contains("example.test/path"))
        #expect(exported.contains("mode=ok"))
    }

    @Test func test_journal_is_bounded_by_size() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let store = DiagnosticEventStore(fileURL: fileURL, maxBytes: 300)
        for index in 0..<20 {
            store.record(category: "test", operationID: "op-\(index)", fields: ["index": index, "padding": String(repeating: "x", count: 40)])
        }

        #expect(try Data(contentsOf: fileURL).count <= 300)
        #expect(store.snapshot().count < 20)
        #expect(store.snapshot().last?.operationID == "op-19")
    }

    @Test func test_journal_strictly_caps_oversized_category_and_operation_id() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let store = DiagnosticEventStore(fileURL: fileURL, maxBytes: 300)

        store.record(
            category: String(repeating: "c", count: 10_000),
            operationID: String(repeating: "o", count: 10_000),
            fields: ["url": "https://example.test"]
        )

        #expect(try Data(contentsOf: fileURL).count <= 300)
        #expect(store.snapshot().last?.operationID?.count ?? 0 <= 120)
        #expect(store.snapshot().last?.category.count ?? 0 <= 120)
    }

    @Test func test_export_writes_snapshot_as_json_lines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiagnosticEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        store.record(category: "one", operationID: "op-1")
        store.record(category: "two", operationID: "op-2")
        let exportURL = directory.appendingPathComponent("exports/current.jsonl")

        try store.export(to: exportURL)

        let lines = try String(contentsOf: exportURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(store.snapshot().map(\.category) == ["one", "two"])
    }
}
