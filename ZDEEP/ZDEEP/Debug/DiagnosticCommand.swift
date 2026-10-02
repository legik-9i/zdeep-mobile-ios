import Foundation

nonisolated enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(anyValue: Any) throws {
        guard Self.isJSONCompatible(anyValue) else {
            throw DiagnosticError.nonSerializableResult("Unsupported JSON value: \(type(of: anyValue))")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: anyValue,
                options: [.fragmentsAllowed, .sortedKeys]
            )
            self = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw DiagnosticError.nonSerializableResult(String(describing: error))
        }
    }

    private static func isJSONCompatible(_ value: Any) -> Bool {
        switch value {
        case is NSNull, is String:
            return true
        case let number as NSNumber:
            return number.doubleValue.isFinite
        case let values as [Any]:
            return values.allSatisfy(isJSONCompatible)
        case let values as [String: Any]:
            return values.values.allSatisfy(isJSONCompatible)
        default:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? value.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DiagnosticError.nonSerializableResult("Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null:
            try value.encodeNil()
        case .bool(let bool):
            try value.encode(bool)
        case .number(let number):
            try value.encode(number)
        case .string(let string):
            try value.encode(string)
        case .array(let array):
            try value.encode(array)
        case .object(let object):
            try value.encode(object)
        }
    }
}

nonisolated enum DiagnosticError: Error, Equatable, LocalizedError {
    case noActiveSession
    case javascriptExecutionFailed(String)
    case nonSerializableResult(String)
    case timedOut(lastValue: JSONValue?)
    case sessionClosed
    case pageChanged
    case navigationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            "No active WebView session"
        case .javascriptExecutionFailed(let message):
            "JavaScript execution failed: \(message)"
        case .nonSerializableResult(let message):
            "JavaScript result is not JSON serializable: \(message)"
        case .timedOut(let lastValue):
            "JavaScript operation timed out; last value: \(String(describing: lastValue))"
        case .sessionClosed:
            "WebView session is closed"
        case .pageChanged:
            "The page changed while JavaScript was running"
        case .navigationFailed(let message):
            "WebView navigation failed: \(message)"
        }
    }
}

nonisolated struct DiagnosticCommand: Identifiable, Sendable {
    let id: UUID
    let source: String

    init(source: String, id: UUID = UUID()) {
        self.id = id
        self.source = source
    }
}
