import Foundation
import Testing
@testable import ZDEEP

struct CarQRParserTests {
    @Test func test_parses_token_and_car_id_from_agent_url_with_prefix_path() throws {
        let token = Self.jwt(payload: #"{"carId":"car-123"}"#)
        let qr = try CarQRParser.parse("https://agent.example/base/auth/get-otp?token=\(token)")

        #expect(qr.carToken == token)
        #expect(qr.carId == "car-123")
    }

    @Test func test_rejects_duplicate_token_query() {
        let token = Self.jwt(payload: #"{"carId":"car-123"}"#)
        #expect(throws: CarQRParserError.self) {
            try CarQRParser.parse("https://agent.example/auth/get-otp?token=\(token)&token=\(token)")
        }
    }

    @Test func test_rejects_malformed_url_token_and_missing_car_id() {
        for value in ["not a url", "https://agent.example/auth/get-otp", "https://agent.example/auth/get-otp?token=", "https://agent.example/other?token=x", "https://agent.example/auth/get-otp?token=not.jwt", "https://agent.example/auth/get-otp?token=\(Self.jwt(payload: #"{"userId":"user-1"}"#))"] {
            #expect(throws: CarQRParserError.self) { try CarQRParser.parse(value) }
        }
    }

    private static func jwt(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
