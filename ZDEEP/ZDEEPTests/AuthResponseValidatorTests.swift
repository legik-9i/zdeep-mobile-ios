import Foundation
import Testing
@testable import ZDEEP

struct AuthResponseValidatorTests {
    @Test func test_rejects_invalid_success_payloads_with_safe_bad_response() throws {
        let malformedJWT = "a.@@@.signature"
        let invalidCases: [(String, Data, String?)] = [
            ("empty token", try body(["accessToken": "", "tokenType": "Bearer", "expiresIn": 900, "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("bad base64url", try body(["accessToken": malformedJWT, "tokenType": "Bearer", "expiresIn": 900, "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("bad payload json", try body(["accessToken": "a.eyJmb28i.sig", "tokenType": "Bearer", "expiresIn": 900, "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("missing exp", try successWithClaims(["userId": "user-1", "carId": "car-1", "aud": "zdeep-webview"]), "car-1"),
            ("string exp", try successWithClaims(["userId": "user-1", "carId": "car-1", "aud": "zdeep-webview", "exp": "1900"]), "car-1"),
            ("wrong audience", try successWithClaims(["userId": "user-1", "carId": "car-1", "aud": "other", "exp": 1900]), "car-1"),
            ("wrong user", try successWithClaims(["userId": "other", "carId": "car-1", "aud": "zdeep-webview", "exp": 1900]), "car-1"),
            ("wrong jwt car", try successWithClaims(["userId": "user-1", "carId": "other", "aud": "zdeep-webview", "exp": 1900]), "car-1"),
            ("wrong response car", try LocalAuthFixture.successBody(), "other"),
            ("wrong token type", try LocalAuthFixture.successBody(tokenType: "MAC"), "car-1"),
            ("missing server time", try body(["accessToken": try validJWT(), "tokenType": "Bearer", "expiresIn": 900, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("missing expiresIn", try body(["accessToken": try validJWT(), "tokenType": "Bearer", "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("non numeric expiry", try body(["accessToken": try validJWT(), "tokenType": "Bearer", "expiresIn": "900", "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"]), "car-1"),
            ("non finite expiresIn", try nonFiniteResponse(field: "expiresIn"), "car-1"),
            ("non finite serverTime", try nonFiniteResponse(field: "serverTime"), "car-1"),
            ("non numeric exp", try successWithClaims(["userId": "user-1", "carId": "car-1", "aud": "zdeep-webview", "exp": "1900"]), "car-1"),
            ("non finite exp", try successWithRawExp("1e999"), "car-1"),
            ("non positive expiry", try LocalAuthFixture.successBody(expiresIn: -1), "car-1"),
            ("huge finite jwt expiry", try LocalAuthFixture.successBody(expiresIn: 900, exp: 1e300), "car-1"),
            ("huge finite response expiry", try LocalAuthFixture.successBody(expiresIn: 1e300, exp: 1_900), "car-1"),
            ("expired token", try LocalAuthFixture.successBody(serverTime: 2_000_000, expiresIn: 1, exp: 1_900), "car-1")
        ]

        for (name, data, expectedCarId) in invalidCases {
            do {
                _ = try AuthResponseValidator.validate(
                    data,
                    stage: .token,
                    attemptId: UUID(),
                    expectedCarId: expectedCarId,
                    expectedPairCarId: nil,
                    sentAt: .zero,
                    receivedAt: .seconds(2)
                )
                Issue.record("Expected invalid response: \(name)")
            } catch let failure as AuthFailure {
                #expect(failure.kind == .invalidResponse, "\(name)")
                #expect(failure.diagnosticCode == "BAD_RESPONSE", "\(name)")
                #expect(failure.httpStatus == 200, "\(name)")
                #expect(!failure.message.contains("signature"), "\(name)")
                #expect(!failure.message.contains("accessToken"), "\(name)")
            }
        }
    }

    @Test func test_pair_requires_response_car_to_match_car_token_context() throws {
        let data = try LocalAuthFixture.successBody(carId: "car-1")
        #expect(throws: AuthFailure.self) {
            try AuthResponseValidator.validate(
                data,
                stage: .pair,
                attemptId: UUID(),
                expectedCarId: nil,
                expectedPairCarId: "car-2",
                sentAt: .zero,
                receivedAt: .seconds(1)
            )
        }
    }

    private func validJWT() throws -> String {
        try LocalAuthFixture.makeJWT(claims: ["userId": "user-1", "carId": "car-1", "aud": "zdeep-webview", "exp": 1_900])
    }

    private func successWithClaims(_ claims: [String: Any]) throws -> Data {
        try body([
            "accessToken": LocalAuthFixture.makeJWT(claims: claims),
            "tokenType": "Bearer", "expiresIn": 900, "serverTime": 1_000_000,
            "userId": "user-1", "carId": "car-1"
        ])
    }

    private func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func nonFiniteResponse(field: String) throws -> Data {
        let accessToken = try validJWT()
        let time = field == "serverTime" ? "1e999" : "1000000"
        let expiry = field == "expiresIn" ? "1e999" : "900"
        return Data("""
        {"accessToken":"\(accessToken)","tokenType":"Bearer","expiresIn":\(expiry),"serverTime":\(time),"userId":"user-1","carId":"car-1"}
        """.utf8)
    }

    private func successWithRawExp(_ exp: String) throws -> Data {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload = Data("""
        {"userId":"user-1","carId":"car-1","aud":"zdeep-webview","exp":\(exp)}
        """.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "\(header).\(payload).signature"
        return try body(["accessToken": token, "tokenType": "Bearer", "expiresIn": 900, "serverTime": 1_000_000, "userId": "user-1", "carId": "car-1"])
    }
}
