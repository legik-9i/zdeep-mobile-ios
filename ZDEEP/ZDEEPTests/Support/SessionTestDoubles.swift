import Foundation
import Security
@testable import ZDEEP

enum BindingStoreTestError: Error, Equatable {
    case injected
}

nonisolated final class BindingStoreOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperations: [String] = []

    func append(_ operation: String) {
        lock.lock()
        defer { lock.unlock() }
        storedOperations.append(operation)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storedOperations.removeAll()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }
}

nonisolated final class MemoryKeychainRecordStorage: KeychainRecordStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let operationLog: BindingStoreOperationLog?
    private var storedData: Data?
    private var failures: [String: (count: Int, status: OSStatus)] = [:]
    private var blockedWrite: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    private var observedWrite: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    private(set) var operations: [String] = []

    init(data: Data? = nil, operationLog: BindingStoreOperationLog? = nil) {
        storedData = data
        self.operationLog = operationLog
    }

    func failNext(_ operation: String, count: Int = 1, status: OSStatus = errSecIO) {
        lock.lock()
        defer { lock.unlock() }
        failures[operation] = (count, status)
    }

    func currentData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func setData(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        storedData = data
    }

    func clearOperations() {
        lock.lock()
        defer { lock.unlock() }
        operations.removeAll()
    }

    func pauseNextWrite() {
        lock.lock()
        defer { lock.unlock() }
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        blockedWrite = gate
        observedWrite = gate
    }

    func waitUntilWriteIsBlocked() async -> Bool {
        let entered = observedWriteSemaphore()
        guard let entered else { return false }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private func observedWriteSemaphore() -> DispatchSemaphore? {
        lock.lock()
        defer { lock.unlock() }
        return observedWrite?.entered
    }

    func resumeBlockedWrite() {
        lock.lock()
        let release = observedWrite?.release
        lock.unlock()
        release?.signal()
    }

    func read() throws -> Data? {
        try perform("keychain.read")
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func write(_ data: Data) throws {
        try perform("keychain.write")
        lock.lock()
        let gate = blockedWrite
        blockedWrite = nil
        lock.unlock()
        gate?.entered.signal()
        if gate != nil { _ = gate?.release.wait(timeout: .now() + 2) }
        lock.lock()
        defer { lock.unlock() }
        storedData = data
    }

    func delete() throws {
        try perform("keychain.delete")
        lock.lock()
        defer { lock.unlock() }
        storedData = nil
    }

    private func perform(_ operation: String) throws {
        lock.lock()
        defer { lock.unlock() }
        operations.append(operation)
        operationLog?.append(operation)
        if let failure = failures[operation], failure.count > 0 {
            failures[operation] = (failure.count - 1, failure.status)
            throw KeychainStorageError.status(failure.status)
        }
    }
}

nonisolated final class MemoryInstallMarkerStorage: InstallMarkerStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let operationLog: BindingStoreOperationLog?
    private var markerExists: Bool
    private var failures: [String: Int] = [:]
    private(set) var operations: [String] = []

    init(exists: Bool = false, operationLog: BindingStoreOperationLog? = nil) {
        markerExists = exists
        self.operationLog = operationLog
    }

    func setExists(_ exists: Bool) {
        lock.lock()
        defer { lock.unlock() }
        markerExists = exists
    }

    func clearOperations() {
        lock.lock()
        defer { lock.unlock() }
        operations.removeAll()
    }

    func failNext(_ operation: String, count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        failures[operation] = count
    }

    func exists() throws -> Bool {
        try perform("marker.exists")
        lock.lock()
        defer { lock.unlock() }
        return markerExists
    }

    func create() throws {
        try perform("marker.create")
        lock.lock()
        defer { lock.unlock() }
        markerExists = true
    }

    func remove() throws {
        try perform("marker.remove")
        lock.lock()
        defer { lock.unlock() }
        markerExists = false
    }

    private func perform(_ operation: String) throws {
        lock.lock()
        defer { lock.unlock() }
        operations.append(operation)
        operationLog?.append(operation)
        if let remaining = failures[operation], remaining > 0 {
            failures[operation] = remaining - 1
            throw BindingStoreTestError.injected
        }
    }
}
