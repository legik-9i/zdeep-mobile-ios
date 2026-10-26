import Foundation
import Testing
@testable import ZDEEP

@MainActor
@Suite(.serialized)
struct NativeBridgeTests {
    @Test func test_bridge_bootstrap_exposes_only_contract_methods() throws {
        let source = try #require(NativeBridge.bootstrapSource)
        #expect(NativeBridge.version == "0.0.2")
        #expect(source.contains("getSession"))
        #expect(source.contains("recoverUnauthorized"))
        #expect(source.contains("getHostState"))
        #expect(source.contains("reportReady"))
        #expect(source.contains("unlinkCar"))
        #expect(!source.contains("protocolVersion"))
        #expect(!source.contains("attemptId"))
    }

    @Test func test_bridge_request_rejects_malformed_method_and_params() {
        #expect(NativeBridgeRequest(documentId: "doc", method: "unknown", params: NSNull()) == nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "getSession", params: ["screen": "content"]) == nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "reportReady", params: ["screen": "other"]) == nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "reportReady", params: ["screen": "content", "extra": 1]) == nil)
    }

    @Test func test_unlink_request_accepts_only_null_params() {
        #expect(NativeBridgeRequest(documentId: "doc", method: "unlinkCar", params: NSNull()) != nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "unlinkCar", params: [String: Any]()) == nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "unlinkCar", params: "") == nil)
        #expect(NativeBridgeRequest(documentId: "doc", method: "unlinkCar", params: [Any]()) == nil)
    }

    @Test func test_session_wire_dto_does_not_expose_native_identity_or_deadline() throws {
        let session = AuthSession(
            accessToken: "fixture-token", userId: "fixture-user", carId: "fixture-car",
            expiresAt: "2030-01-01T00:00:00Z", deadline: .seconds(500), serverTimeMs: 1,
            attemptId: UUID()
        )
        let data = try JSONEncoder().encode(WebviewSession(session))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("accessToken"))
        #expect(json.contains("carId"))
        #expect(json.contains("expiresAt"))
        #expect(!json.contains("userId"))
        #expect(!json.contains("deadline"))
        #expect(!json.contains("attemptId"))
    }

    @Test func test_reply_envelopes_have_only_the_contract_shape() throws {
        let ok = String(data: try JSONEncoder().encode(BridgeReply.success(BridgeNullFixture.value)), encoding: .utf8)!
        let error = String(data: try JSONEncoder().encode(BridgeReply.failure(BridgeAuthError(message: "safe"))), encoding: .utf8)!
        let cancelled = String(data: try JSONEncoder().encode(BridgeReply.cancelledReply), encoding: .utf8)!
        #expect(ok.contains("\"value\""))
        #expect(!ok.contains("\"error\""))
        #expect(error.contains("\"error\""))
        #expect(!error.contains("\"value\""))
        #expect(cancelled.contains("\"cancelled\":true"))
        #expect(!cancelled.contains("\"error\""))
    }
}

private enum BridgeNullFixture: Encodable { case value }
