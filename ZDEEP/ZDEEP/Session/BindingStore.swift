import CryptoKit
import Foundation

nonisolated private struct PersistedBindingRecord: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case registered
        case resetting
    }

    let bindingId: UUID
    let privateKey: Data
    let publicCertificate: String
    var state: State
    var carId: String?
}

nonisolated final class BindingStore: BindingStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ru.zdeep.binding-store")
    private let recordStorage: any KeychainRecordStorage
    private let markerStorage: any InstallMarkerStorage

    // Accessed only from queue.
    private var hasRestored = false
    private var currentRecord: PersistedBindingRecord?

    init(
        recordStorage: any KeychainRecordStorage = KeychainBindingRecordStorage(),
        markerStorage: any InstallMarkerStorage = FileInstallMarkerStorage()
    ) {
        self.recordStorage = recordStorage
        self.markerStorage = markerStorage
    }

    func restore() async throws -> RegisteredBinding? {
        try await enqueue {
            let markerExists: Bool
            do {
                markerExists = try self.markerStorage.exists()
            } catch {
                throw BindingStoreError.installMarkerFailure
            }

            if !markerExists {
                do {
                    try self.recordStorage.delete()
                } catch {
                    throw BindingStoreError.storageFailure
                }
                do {
                    try self.markerStorage.create()
                } catch {
                    throw BindingStoreError.installMarkerFailure
                }
                self.currentRecord = nil
                self.hasRestored = true
                return nil
            }

            let data: Data?
            do {
                data = try self.recordStorage.read()
            } catch {
                throw BindingStoreError.storageFailure
            }
            guard let data else {
                self.currentRecord = nil
                self.hasRestored = true
                return nil
            }

            guard let record = try? JSONDecoder().decode(PersistedBindingRecord.self, from: data),
                  record.state == .registered,
                  let carId = record.carId, !carId.isEmpty,
                  (try? self.makePrivateKey(for: record)) != nil else {
                do {
                    try self.recordStorage.delete()
                } catch {
                    throw BindingStoreError.storageFailure
                }
                self.currentRecord = nil
                self.hasRestored = true
                return nil
            }

            self.currentRecord = record
            self.hasRestored = true
            return RegisteredBinding(
                bindingId: record.bindingId,
                publicCertificate: record.publicCertificate,
                carId: carId
            )
        }
    }

    func beginRegistration() async throws -> PendingBinding {
        try await enqueue {
            guard self.hasRestored else { throw BindingStoreError.restoreRequired }
            guard self.currentRecord == nil else { throw BindingStoreError.invalidTransition }
            let privateKey = P256.Signing.PrivateKey()
            let record = PersistedBindingRecord(
                bindingId: UUID(),
                privateKey: privateKey.rawRepresentation,
                publicCertificate: privateKey.publicKey.derRepresentation.base64EncodedString(),
                state: .pending,
                carId: nil
            )
            try self.persist(record)
            self.currentRecord = record
            return PendingBinding(bindingId: record.bindingId, publicCertificate: record.publicCertificate)
        }
    }

    func sign(bindingId: UUID, bytes: Data) async throws -> Data {
        try await enqueue {
            guard let record = self.currentRecord,
                  record.bindingId == bindingId,
                  record.state == .pending || record.state == .registered else {
                throw BindingStoreError.invalidTransition
            }
            do {
                return try self.makePrivateKey(for: record).signature(for: bytes).derRepresentation
            } catch let error as BindingStoreError {
                throw error
            } catch {
                throw BindingStoreError.invalidRecord
            }
        }
    }

    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding {
        try await enqueue {
            guard !carId.isEmpty, let record = self.currentRecord, record.bindingId == bindingId else {
                throw BindingStoreError.invalidTransition
            }
            if record.state == .registered, record.carId == carId {
                return RegisteredBinding(bindingId: bindingId, publicCertificate: record.publicCertificate, carId: carId)
            }
            guard record.state == .pending else { throw BindingStoreError.invalidTransition }

            var registeredRecord = record
            registeredRecord.state = .registered
            registeredRecord.carId = carId
            try self.persist(registeredRecord)
            self.currentRecord = registeredRecord
            return RegisteredBinding(bindingId: bindingId, publicCertificate: record.publicCertificate, carId: carId)
        }
    }

    func reset() async throws {
        try await enqueue {
            guard self.hasRestored else { throw BindingStoreError.restoreRequired }
            var resettingRecord: PersistedBindingRecord?
            var markSucceeded = true
            if var record = self.currentRecord {
                record.state = .resetting
                resettingRecord = record
                do {
                    try self.persist(record)
                    self.currentRecord = record
                } catch {
                    markSucceeded = false
                }
            }

            do {
                try self.recordStorage.delete()
                self.currentRecord = nil
                return
            } catch {
                if markSucceeded, let resettingRecord {
                    self.currentRecord = resettingRecord
                }
                throw BindingStoreError.storageFailure
            }
        }
    }

    private func persist(_ record: PersistedBindingRecord) throws {
        do {
            try recordStorage.write(JSONEncoder().encode(record))
        } catch {
            throw BindingStoreError.storageFailure
        }
    }

    private func makePrivateKey(for record: PersistedBindingRecord) throws -> P256.Signing.PrivateKey {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(rawRepresentation: record.privateKey)
            let storedPublicKey = try Data(base64Encoded: record.publicCertificate).unwrapInvalidRecord()
            guard storedPublicKey == key.publicKey.derRepresentation else { throw BindingStoreError.invalidRecord }
        } catch let error as BindingStoreError {
            throw error
        } catch {
            throw BindingStoreError.invalidRecord
        }
        return key
    }

    private func enqueue<T: Sendable>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension Optional where Wrapped == Data {
    nonisolated func unwrapInvalidRecord() throws -> Data {
        guard let value = self else { throw BindingStoreError.invalidRecord }
        return value
    }
}
