import CryptoKit
import Foundation
import Testing
@testable import ZDEEP

@MainActor
struct AuthClientTests {
    @Test func test_timestamp_at_unrepresentable_upper_int64_boundary_is_invalid_input() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock(wallTimeMs: Double(Int64.max))
        let transport = TestAuthHTTPTransport()
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        do {
            _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
            Issue.record("2^63 cannot be represented as an Int64 timestamp")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.diagnosticCode == "BAD_RESPONSE")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func test_cancel_before_queued_network_launch_does_not_send() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)
        clock.onSchedule = { client.invalidateCurrentAttempt() }

        do {
            _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
            Issue.record("Invalidated attempts must complete with cancellation")
        } catch is CancellationError {}

        #expect(transport.requests.isEmpty)
        #expect(transport.cancelCount == 1)
        #expect(clock.activeScheduleCount == 0)
    }

    @Test func test_urlsession_transport_rejects_already_cancelled_caller() async throws {
        let transport = URLSessionAuthHTTPTransport()
        let request = URLRequest(url: URL(string: "zdeep-auth-test://local/never-send")!)
        let caller = Task { @MainActor in try await transport.send(request) }
        caller.cancel()

        do {
            _ = try await caller.value
            Issue.record("A cancelled caller must not start a URLSession data task")
        } catch is CancellationError {}
    }

    @Test func test_signs_exact_sent_body_and_sends_once() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.enqueue((try LocalAuthFixture.successBody(), LocalAuthFixture.httpResponse(status: 200)))
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())

        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/auth/mobile/pair")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == Set(["publicCertificate", "carToken"]))
        #expect(object["publicCertificate"] as? String == binding.publicCertificate)
        let timestamp = try #require(request.value(forHTTPHeaderField: "X-Timestamp"))
        let encodedSignature = try #require(request.value(forHTTPHeaderField: "X-Signature"))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: #require(Data(base64Encoded: encodedSignature)))
        let publicKey = try P256.Signing.PublicKey(derRepresentation: #require(Data(base64Encoded: binding.publicCertificate)))
        let signedBytes = Data("\(timestamp)|".utf8) + body
        #expect(publicKey.isValidSignature(signature, for: signedBytes))
    }

    @Test(arguments: [401, 403, 429, 503, 307, 308])
    func test_http_failures_and_redirects_are_not_retried(status: Int) async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.enqueue((Data(#"{"code":"UNKNOWN_SERVER_CODE"}"#.utf8), LocalAuthFixture.httpResponse(status: status)))
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        do {
            _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
            Issue.record("Expected HTTP failure")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .server)
            #expect(failure.httpStatus == status)
            #expect(failure.serverCode == "UNKNOWN_SERVER_CODE")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func test_non_json_server_error_keeps_http_status() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.enqueue((Data("service unavailable".utf8), LocalAuthFixture.httpResponse(status: 503)))
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        do {
            _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
            Issue.record("Expected HTTP 503")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .server)
            #expect(failure.httpStatus == 503)
            #expect(failure.serverCode == nil)
            #expect(failure.diagnosticCode == "HTTP_503")
            #expect(!failure.message.contains("service unavailable"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func test_900_seconds_is_not_900_milliseconds() async throws {
        for wallShift in [0.0, -86_400_000, 86_400_000] {
            let (store, binding) = try await LocalAuthFixture.makePendingBinding()
            let clock = TestSessionClock(wallTimeMs: 1_000_000 + wallShift)
            let transport = TestAuthHTTPTransport()
            transport.clock = clock
            transport.latency = .seconds(2)
            transport.enqueue((try LocalAuthFixture.successBody(), LocalAuthFixture.httpResponse(status: 200)))
            let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

            let session = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())

            #expect(session.deadline == .seconds(900))
            #expect(session.expiresAt == "1970-01-01T00:31:40Z")
            #expect(transport.requests.count == 1)
        }
    }

    @Test func test_timestamp_error_updates_next_attempt_only() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.latency = .seconds(2)
        transport.enqueue((Data(#"{"code":"TIMESTAMP_OUT_OF_RANGE","serverTime":1200000}"#.utf8), LocalAuthFixture.httpResponse(status: 400)))
        transport.enqueue((try LocalAuthFixture.successBody(serverTime: 1_200_000), LocalAuthFixture.httpResponse(status: 200)))
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        do {
            _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
            Issue.record("The current timestamp failure must remain a failure")
        } catch let failure as AuthFailure {
            #expect(failure.serverCode == "TIMESTAMP_OUT_OF_RANGE")
            #expect(failure.httpStatus == 400)
        }
        #expect(transport.requests.count == 1)

        _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "X-Timestamp") == "1200000")
    }

    @Test func test_invalidated_reply_cannot_update_offset() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.suspendNext = true
        transport.enqueue((try LocalAuthFixture.successBody(serverTime: 1_200_000), LocalAuthFixture.httpResponse(status: 200)))
        transport.enqueue((try LocalAuthFixture.successBody(serverTime: 1_000_000), LocalAuthFixture.httpResponse(status: 200)))
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)
        let pending = Task { try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken()) }
        while transport.requests.isEmpty { await Task.yield() }

        client.invalidateCurrentAttempt()
        transport.completePending(with: (try LocalAuthFixture.successBody(serverTime: 1_200_000), LocalAuthFixture.httpResponse(status: 200)))
        do {
            _ = try await pending.value
            Issue.record("Invalidated attempt must not return a session")
        } catch is CancellationError {}

        _ = try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken())
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "X-Timestamp") == "1000000")
    }

    @Test func test_full_timeout_does_not_reset_on_chunks() async throws {
        let (store, binding) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let transport = TestAuthHTTPTransport()
        transport.clock = clock
        transport.suspendNext = true
        let client = AuthClient(bindingStore: store, transport: transport, clock: clock, endpoints: AppEnvironment.local.endpoints)

        let at29Seconds = Task { try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken()) }
        while transport.requests.isEmpty { await Task.yield() }
        clock.advance(by: .seconds(10))
        clock.advance(by: .seconds(10))
        clock.advance(by: .seconds(9))
        transport.completePending(with: (try LocalAuthFixture.successBody(), LocalAuthFixture.httpResponse(status: 200)))
        let accepted = try await at29Seconds.value
        #expect(accepted.deadline == .seconds(900))

        transport.suspendNext = true
        let at30Seconds = Task { try await client.pair(binding: binding, carToken: try LocalAuthFixture.carToken()) }
        while transport.requests.count < 2 { await Task.yield() }
        clock.advance(by: .seconds(10))
        clock.advance(by: .seconds(10))
        clock.advance(by: .seconds(10))
        do {
            _ = try await at30Seconds.value
            Issue.record("A response at the total deadline must time out")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .timeout)
            #expect(failure.diagnosticCode == "TIMEOUT")
        }
        #expect(transport.requests.count == 2)
        #expect(transport.cancelCount == 1)
        transport.completePending(with: (try LocalAuthFixture.successBody(serverTime: 1_000_000), LocalAuthFixture.httpResponse(status: 200)))
    }
}
