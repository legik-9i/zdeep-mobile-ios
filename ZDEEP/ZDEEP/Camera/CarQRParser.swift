import Foundation

struct CarQR: Equatable, Sendable {
    let carToken: String
    let carId: String
}

enum CarQRParserError: Error {
    case unsupported
}

enum CarQRParser {
    static func parse(_ value: String) throws -> CarQR {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil,
              components.path.hasSuffix("/auth/get-otp"),
              let queryItems = components.queryItems else { throw CarQRParserError.unsupported }

        let tokens = queryItems.filter { $0.name == "token" }
        guard tokens.count == 1,
              let token = tokens[0].value,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CarQRParserError.unsupported
        }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payload = decodeBase64URL(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let carId = object["carId"] as? String,
              !carId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CarQRParserError.unsupported
        }

        return CarQR(carToken: token, carId: carId)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
