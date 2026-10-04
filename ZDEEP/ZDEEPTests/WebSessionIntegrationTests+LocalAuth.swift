import Foundation
import Testing
@testable import ZDEEP

@MainActor
extension WebSessionIntegrationTests {
    @Test func test_local_pair_then_token_accepts_spki_and_der_signature() async throws {
        let service = "ru.zdeep.tests.auth.\(UUID().uuidString)"
        let keychain = KeychainBindingRecordStorage(service: service)
        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("zdeep-local-auth-\(UUID().uuidString)", isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: markerRoot.appendingPathComponent("install.marker"))
        defer {
            try? keychain.delete()
            try? marker.remove()
            try? FileManager.default.removeItem(at: markerRoot)
        }

        let carToken = try await LocalAuthFixture.fetchFreshCarToken()
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)
        let pending = try await store.beginRegistration()
        // Force one server clock rejection without changing the Simulator's system clock.
        let clock = TestSessionClock(wallTimeMs: Date().timeIntervalSince1970 * 1_000 + 600_000)
        let transport = RecordingURLSessionAuthTransport()
        let client = AuthClient(
            bindingStore: store,
            transport: transport,
            clock: clock,
            endpoints: AppEnvironment.local.endpoints
        )

        let serverTime: Double
        let firstTimestamp: Int64
        do {
            _ = try await client.pair(binding: pending, carToken: carToken)
            Issue.record("The deliberate local clock skew should be rejected")
            throw LocalAuthFixtureError.unavailable
        } catch let failure as AuthFailure {
            #expect(failure.kind == .server)
            #expect(failure.httpStatus == 401)
            #expect(failure.serverCode == "TIMESTAMP_OUT_OF_RANGE")
            #expect(transport.requestTimestamps.count == 1)
            #expect(transport.responseStatuses == [401])
            serverTime = try #require(transport.rejectedServerTimeMs)
            firstTimestamp = try #require(transport.requestTimestamps.first)
        } catch {
            throw error
        }
        #expect(abs(Double(firstTimestamp) - serverTime) > 120_000)

        // A separate caller invocation uses the accepted server-time offset.
        let paired = try await client.pair(binding: pending, carToken: carToken)
        #expect(transport.requestTimestamps.count == 2)
        #expect(transport.responseStatuses == [401, 200])
        #expect(abs(Double(try #require(transport.requestTimestamps.last)) - serverTime) < 120_000)
        let registered = try await store.completeRegistration(bindingId: pending.bindingId, carId: paired.carId)
        let refreshed = try await client.token(binding: registered)

        #expect(registered.bindingId == pending.bindingId)
        #expect(refreshed.userId == paired.userId)
        #expect(refreshed.carId == registered.carId)
        #expect(paired.deadline > clock.now)
        #expect(refreshed.deadline > clock.now)
        #expect(!paired.expiresAt.isEmpty)
        #expect(!refreshed.expiresAt.isEmpty)
    }
}
