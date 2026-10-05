import Foundation
import CoreFoundation

struct DiagnosticEvent: Codable, Identifiable, Sendable {
    let timestamp: Date
    let category: String
    let operationID: String?
    let fields: [String: JSONValue]

    var id: String { "\(timestamp.timeIntervalSince1970)-\(operationID ?? category)" }
}

final class DiagnosticEventStore: @unchecked Sendable {
    static let shared = DiagnosticEventStore()

    let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var writesSuspended = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileURL: URL? = nil, maxBytes: Int = 256 * 1024) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("ZDEEP/diagnostic-events.jsonl")
        }
        self.maxBytes = max(1, maxBytes)
    }

    func record(category: String, operationID: String? = nil, fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard !writesSuspended else { return }

        var events = readEvents()
        events.append(DiagnosticEvent(
            timestamp: Date(),
            category: Self.sanitize(category),
            operationID: operationID.map(Self.sanitize),
            fields: Self.sanitize(fields)
        ))
        var data = encodeLines(events)
        while data.count > maxBytes, events.count > 1 {
            events.removeFirst()
            data = encodeLines(events)
        }
        if data.count > maxBytes, let original = events.last {
            var compacted = DiagnosticEvent(
                timestamp: original.timestamp,
                category: original.category,
                operationID: original.operationID,
                fields: ["truncated": .bool(true)]
            )
            while true {
                events[events.count - 1] = compacted
                data = encodeLines(events)
                guard data.count > maxBytes else { break }

                let categoryCount = compacted.category.count
                let operationIDCount = compacted.operationID?.count ?? 0
                guard categoryCount > 1 || operationIDCount > 1 else {
                    events.removeLast()
                    data = encodeLines(events)
                    break
                }

                let category = categoryCount > 1 ? String(compacted.category.prefix(max(1, categoryCount / 2))) : compacted.category
                let operationID = operationIDCount > 1
                    ? String(compacted.operationID!.prefix(max(1, operationIDCount / 2)))
                    : compacted.operationID
                compacted = DiagnosticEvent(
                    timestamp: compacted.timestamp,
                    category: category,
                    operationID: operationID,
                    fields: compacted.fields
                )
            }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func suspendWrites() {
        lock.lock()
        writesSuspended = true
        lock.unlock()
    }

    func resumeWrites() {
        lock.lock()
        writesSuspended = false
        lock.unlock()
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return readEvents()
    }

    func export(to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeLines(readEvents()).write(to: url, options: .atomic)
    }

    private func readEvents() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(DiagnosticEvent.self, from: lineData)
        }
    }

    private func encodeLines(_ events: [DiagnosticEvent]) -> Data {
        var result = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            result.append(line)
            result.append(0x0a)
        }
        return result
    }

    nonisolated private static func sanitize(_ fields: [String: Any]) -> [String: JSONValue] {
        fields.reduce(into: [:]) { result, pair in
            if isSensitiveKey(pair.key) {
                result[pair.key] = .string("[REDACTED]")
            } else if let value = sanitizeValue(pair.value) {
                result[pair.key] = value
            }
        }
    }

    nonisolated private static func sanitizeValue(_ value: Any) -> JSONValue? {
        if let string = value as? String { return .string(sanitize(string)) }
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return number.doubleValue.isFinite ? .number(number.doubleValue) : nil
        }
        if let values = value as? [Any] { return .array(values.compactMap(sanitizeValue)) }
        if let values = value as? [String: Any] { return .object(sanitize(values)) }
        if let url = value as? URL { return .string(sanitize(url.absoluteString)) }
        return .string("[UNSUPPORTED]")
    }

    nonisolated private static func sanitize(_ input: String) -> String {
        var output = input
        let urlPattern = #"https?://[^\s\"'<>]+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                output.replaceSubrange(range, with: sanitizeURL(String(output[range])))
            }
        }
        output = output.replacingOccurrences(of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?i)\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, with: "[REDACTED_JWT]", options: .regularExpression)
        return output
    }

    nonisolated private static func sanitizeURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        if components.user != nil { components.user = "[REDACTED]" }
        if components.password != nil { components.password = "[REDACTED]" }
        components.queryItems = sanitizeQueryItems(components.queryItems)
        if let fragment = components.fragment {
            components.fragment = sanitizeFragment(fragment)
        }
        return components.string ?? value
    }

    nonisolated private static func sanitizeFragment(_ fragment: String) -> String {
        let queryStart: String.Index
        let prefix: String
        if let questionMark = fragment.firstIndex(of: "?") {
            prefix = String(fragment[...questionMark])
            queryStart = fragment.index(after: questionMark)
        } else if fragment.contains("=") {
            prefix = ""
            queryStart = fragment.startIndex
        } else {
            return fragment
        }

        let query = String(fragment[queryStart...])
        guard var components = URLComponents(string: "https://fragment.invalid/?\(query)") else { return fragment }
        components.queryItems = sanitizeQueryItems(components.queryItems)
        let sanitizedQuery = components.percentEncodedQuery ?? query
        return prefix + sanitizedQuery
    }

    nonisolated private static func sanitizeQueryItems(_ items: [URLQueryItem]?) -> [URLQueryItem]? {
        items?.map { item in
            isSensitiveKey(item.name) ? URLQueryItem(name: item.name, value: "[REDACTED]") : item
        }
    }

    nonisolated private static func isSensitiveKey(_ key: String) -> Bool {
        let key = key.lowercased().filter(\.isLetter)
        return ["token", "secret", "password", "authorization", "auth", "apikey", "privatekey", "cookie", "certificate", "jwt", "credential", "qr"].contains(where: key.contains)
    }
}
