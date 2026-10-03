import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticEventStoreTests {
    @Test func test_secrets_are_removed_from_fields_and_urls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiagnosticEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        store.record(category: "navigation", operationID: "op-1", fields: [
            "url": "https://example.test/path?access_token=secret-value&mode=ok",
            "authorization": "Bearer do-not-store",
            "message": "https://example.test/?token=inline-secret"
        ])

        let exported = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!exported.contains("secret-value"))
        #expect(!exported.contains("do-not-store"))
        #expect(!exported.contains("inline-secret"))
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
