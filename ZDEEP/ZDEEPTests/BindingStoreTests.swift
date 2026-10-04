import CryptoKit
import Foundation
import Security
import Testing
@testable import ZDEEP

struct BindingStoreTests {
    @Test func test_restore_missing_marker_removes_registered_before_creating_marker() async throws {
        let operationLog = BindingStoreOperationLog()
        let keychain = MemoryKeychainRecordStorage(operationLog: operationLog)
        let marker = MemoryInstallMarkerStorage(exists: true, operationLog: operationLog)
        let initialStore = BindingStore(recordStorage: keychain, markerStorage: marker)

        #expect(try await initialStore.restore() == nil)
        let pending = try await initialStore.beginRegistration()
        _ = try await initialStore.completeRegistration(bindingId: pending.bindingId, carId: "car-restore")
        #expect(keychain.currentData() != nil)

        operationLog.clear()
        keychain.clearOperations()
        marker.clearOperations()
        marker.setExists(false)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)

        #expect(try await store.restore() == nil)
        #expect(keychain.operations == ["keychain.delete"])
        #expect(marker.operations == ["marker.exists", "marker.create"])
        #expect(operationLog.snapshot() == ["marker.exists", "keychain.delete", "marker.create"])
    }

    @Test func test_marker_read_error_does_not_delete_keychain() async {
        let keychain = MemoryKeychainRecordStorage(data: Data("keep".utf8))
        let marker = MemoryInstallMarkerStorage()
        marker.failNext("marker.exists")
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)

        await #expect(throws: BindingStoreError.installMarker(operation: "exists")) { try await store.restore() }
        #expect(keychain.operations.isEmpty)
        #expect(keychain.currentData() == Data("keep".utf8))
    }

    @Test func test_marker_save_error_does_not_report_restore_success() async {
        let keychain = MemoryKeychainRecordStorage(data: Data("old".utf8))
        let marker = MemoryInstallMarkerStorage()
        marker.failNext("marker.create")
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)

        await #expect(throws: BindingStoreError.installMarker(operation: "create")) { try await store.restore() }
        #expect(keychain.operations == ["keychain.delete"])
        #expect(marker.operations == ["marker.exists", "marker.create"])
    }

    @Test func test_keychain_read_error_preserves_operation_and_status() async {
        let keychain = MemoryKeychainRecordStorage()
        keychain.failNext("keychain.read", status: errSecParam)
        let store = BindingStore(recordStorage: keychain, markerStorage: MemoryInstallMarkerStorage(exists: true))

        await #expect(throws: BindingStoreError.keychain(operation: "read", status: errSecParam)) {
            try await store.restore()
        }
        #expect(keychain.operations == ["keychain.read"])
    }

    @Test func test_pending_and_resetting_are_deleted_on_restore() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let marker = MemoryInstallMarkerStorage(exists: true)
        let firstStore = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await firstStore.restore() == nil)
        _ = try await firstStore.beginRegistration()

        let pendingStore = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await pendingStore.restore() == nil)
        #expect(keychain.currentData() == nil)

        let resettingStore = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await resettingStore.restore() == nil)
        _ = try await resettingStore.beginRegistration()
        keychain.failNext("keychain.delete")
        await #expect(throws: BindingStoreError.keychain(operation: "delete", status: errSecIO)) { try await resettingStore.reset() }
        #expect(keychain.currentData() != nil)

        let restoredStore = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await restoredStore.restore() == nil)
        #expect(keychain.currentData() == nil)
    }

    @Test func test_begin_sign_complete_and_restore_registered() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let marker = MemoryInstallMarkerStorage(exists: true)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)

        let pending = try await store.beginRegistration()
        #expect(keychain.currentData() != nil)
        let bytes = Data("exact server challenge bytes\u{0}unchanged".utf8)
        let signature = try await store.sign(bindingId: pending.bindingId, bytes: bytes)
        let certificateData = try #require(Data(base64Encoded: pending.publicCertificate))
        let publicKey = try P256.Signing.PublicKey(derRepresentation: certificateData)
        let derSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        #expect(publicKey.isValidSignature(derSignature, for: bytes))

        let registered = try await store.completeRegistration(bindingId: pending.bindingId, carId: "car-1")
        #expect(registered.bindingId == pending.bindingId)
        #expect(registered.carId == "car-1")
        #expect(try await store.completeRegistration(bindingId: pending.bindingId, carId: "car-1") == registered)
        await #expect(throws: BindingStoreError.self) {
            try await store.completeRegistration(bindingId: pending.bindingId, carId: "car-2")
        }
        await #expect(throws: BindingStoreError.self) {
            try await store.completeRegistration(bindingId: UUID(), carId: "car-1")
        }

        let restored = try await BindingStore(recordStorage: keychain, markerStorage: marker).restore()
        #expect(restored == registered)
    }

    @Test func test_restore_rejects_malformed_record_and_mismatched_public_key() async throws {
        let marker = MemoryInstallMarkerStorage(exists: true)
        let malformedKeychain = MemoryKeychainRecordStorage(data: Data("not-json".utf8))
        let malformedStore = BindingStore(recordStorage: malformedKeychain, markerStorage: marker)
        await #expect(throws: BindingStoreError.invalidRecord) { try await malformedStore.restore() }
        #expect(malformedKeychain.currentData() == Data("not-json".utf8))
        #expect(!malformedKeychain.operations.contains("keychain.delete"))

        let keychain = MemoryKeychainRecordStorage()
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)
        let pending = try await store.beginRegistration()
        _ = try await store.completeRegistration(bindingId: pending.bindingId, carId: "car-mismatch")
        let original = try #require(keychain.currentData())
        var record = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let otherKey = P256.Signing.PrivateKey()
        record["publicCertificate"] = otherKey.publicKey.derRepresentation.base64EncodedString()
        keychain.setData(try JSONSerialization.data(withJSONObject: record))
        let mismatchStore = BindingStore(recordStorage: keychain, markerStorage: marker)
        let corruptedRecord = try JSONSerialization.data(withJSONObject: record)
        await #expect(throws: BindingStoreError.invalidRecord) { try await mismatchStore.restore() }
        #expect(keychain.currentData() == corruptedRecord)
        #expect(!keychain.operations.contains("keychain.delete"))
    }

    @Test func test_reset_failure_never_reports_success() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let marker = MemoryInstallMarkerStorage(exists: true)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)
        _ = try await store.beginRegistration()
        keychain.failNext("keychain.write")
        keychain.failNext("keychain.delete")

        await #expect(throws: BindingStoreError.keychain(operation: "delete", status: errSecIO)) { try await store.reset() }
    }

    @Test func test_reset_succeeds_when_marking_fails_but_delete_succeeds() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let store = BindingStore(
            recordStorage: keychain,
            markerStorage: MemoryInstallMarkerStorage(exists: true)
        )
        #expect(try await store.restore() == nil)
        _ = try await store.beginRegistration()
        keychain.failNext("keychain.write")

        try await store.reset()
        #expect(keychain.currentData() == nil)
        #expect(Array(keychain.operations.suffix(2)) == ["keychain.write", "keychain.delete"])
    }

    @Test func test_queued_reset_follows_inflight_begin() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let marker = MemoryInstallMarkerStorage(exists: true)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        #expect(try await store.restore() == nil)

        keychain.pauseNextWrite()
        let beginTask = Task.detached { try await store.beginRegistration() }
        #expect(await keychain.waitUntilWriteIsBlocked())
        let resetTask = Task.detached { try await store.reset() }
        keychain.resumeBlockedWrite()
        _ = try await beginTask.value
        try await resetTask.value
        #expect(keychain.currentData() == nil)
        #expect(Array(keychain.operations.suffix(2)) == ["keychain.write", "keychain.delete"])
        #expect(marker.operations == ["marker.exists"])
    }

    @Test func test_begin_requires_successful_restore_and_resetting_never_signs() async throws {
        let keychain = MemoryKeychainRecordStorage()
        let marker = MemoryInstallMarkerStorage()
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)
        await #expect(throws: BindingStoreError.registrationNotAllowed) { try await store.beginRegistration() }

        #expect(try await store.restore() == nil)
        let pending = try await store.beginRegistration()
        keychain.failNext("keychain.delete")
        await #expect(throws: BindingStoreError.keychain(operation: "delete", status: errSecIO)) { try await store.reset() }
        await #expect(throws: BindingStoreError.registrationNotAllowed) {
            try await store.sign(bindingId: pending.bindingId, bytes: Data("challenge".utf8))
        }
        await #expect(throws: BindingStoreError.staleBinding) {
            try await store.sign(bindingId: UUID(), bytes: Data("challenge".utf8))
        }
    }

    @Test func test_reset_clears_record_after_initial_restore_fails() async throws {
        let keychain = MemoryKeychainRecordStorage(data: Data("malformed".utf8))
        let marker = MemoryInstallMarkerStorage(exists: true)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)

        await #expect(throws: BindingStoreError.invalidRecord) { try await store.restore() }
        try await store.reset()
        #expect(keychain.currentData() == nil)
        #expect(try await BindingStore(recordStorage: keychain, markerStorage: marker).restore() == nil)
    }

    @Test func test_security_storage_and_marker_use_isolated_test_locations() throws {
        let service = "ru.zdeep.mobile.tests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = FileInstallMarkerStorage(fileURL: directory.appendingPathComponent("install.marker"))
        defer {
            try? marker.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(try marker.exists() == false)
        try marker.create()
        #expect(try marker.exists())
        let markerURL = directory.appendingPathComponent("install.marker")
        #expect(try markerURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(KeychainBindingRecordStorage.ownedQuery(service: service)[kSecAttrService as String] as? String == service)
    }

    @Test func test_reset_invalid_record_uses_owned_keychain_query() async throws {
        let service = "ru.zdeep.mobile.tests.\(UUID().uuidString)"
        let query = KeychainBindingRecordStorage.ownedQuery(service: service)
        let keychain = MemoryKeychainRecordStorage(data: Data("invalid".utf8))
        let marker = MemoryInstallMarkerStorage(exists: true)
        let store = BindingStore(recordStorage: keychain, markerStorage: marker)

        await #expect(throws: BindingStoreError.invalidRecord) { try await store.restore() }
        try await store.reset()
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrAccount as String] as? String == "binding")
        #expect(query[kSecAttrSynchronizable as String] as? NSNumber == kCFBooleanFalse)
        #expect(keychain.operations == ["keychain.read", "keychain.delete"])
    }

    @Test func test_keychain_adapter_round_trips_and_restores_durable_data() throws {
        let service = "ru.zdeep.mobile.tests.\(UUID().uuidString)"
        let storage = KeychainBindingRecordStorage(service: service)
        defer { try? storage.delete() }

        #expect(try storage.read() == nil)
        try storage.write(Data("first-record".utf8))
        #expect(try storage.read() == Data("first-record".utf8))
        try storage.write(Data("updated-record".utf8))
        let restartedStore = KeychainBindingRecordStorage(service: service)
        #expect(try restartedStore.read() == Data("updated-record".utf8))
        try restartedStore.delete()
        #expect(try storage.read() == nil)
    }
}
