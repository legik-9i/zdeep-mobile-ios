import Foundation
import Security
import Testing
@testable import ZDEEP

struct OwnedClientDataCleanerTests {
    @Test func test_partial_failure_retries_only_remaining_categories() async {
        let adapters = OwnedDataCategory.allTestCategories.map { category in
            (category, FakeOwnedDataCategoryAdapter(failuresRemaining: category == .keychain ? 1 : 0))
        }
        let cleaner = OwnedClientDataCleaner(adapters: Dictionary(uniqueKeysWithValues: adapters))

        let first = await cleaner.clean(remaining: Set(OwnedDataCategory.allTestCategories))
        #expect(first.remaining == [.keychain])
        #expect(first.failures[.keychain] != nil)
        for (category, adapter) in adapters {
            #expect(await adapter.cleanCount == 1, "Expected one cleanup attempt for \(category)")
        }

        let second = await cleaner.clean(remaining: first.remaining)
        #expect(second.remaining.isEmpty)
        #expect(second.failures.isEmpty)
        for (category, adapter) in adapters {
            #expect(await adapter.cleanCount == (category == .keychain ? 2 : 1))
        }
    }

    @Test func test_clean_checks_adapter_is_empty_before_reporting_success() async {
        let adapter = FakeOwnedDataCategoryAdapter(leavesDataAfterCleanup: true)
        let cleaner = OwnedClientDataCleaner(adapters: [.keychain: adapter])

        let progress = await cleaner.clean(remaining: [.keychain])

        #expect(progress.remaining == [.keychain])
        #expect(progress.failures[.keychain] != nil)
    }

    @Test func test_keychain_cleanup_removes_only_records_for_explicit_app_service() async throws {
        let service = "ru.zdeep.tests.owned-cleaner.\(UUID().uuidString)"
        let unrelatedService = "ru.zdeep.tests.unrelated.\(UUID().uuidString)"
        defer {
            _ = SecItemDelete(keychainQuery(service: service) as CFDictionary)
            _ = SecItemDelete(keychainQuery(service: unrelatedService) as CFDictionary)
        }
        try addKeychainItem(service: service, account: "binding")
        try addKeychainItem(service: service, account: "future-app-owned-account")
        try addKeychainItem(service: unrelatedService, account: "other-app-account")

        let cleaner = OwnedClientDataCleaner(keychainServices: [service])
        let progress = await cleaner.clean(remaining: [.keychain])

        #expect(progress.remaining.isEmpty)
        #expect(try keychainRecordCount(service: service) == 0)
        #expect(try keychainRecordCount(service: unrelatedService) == 1)
    }

    @Test func test_file_and_defaults_cleanup_removes_only_injected_app_owned_roots() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let domain = "ru.zdeep.tests.cleanup.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
            try? FileManager.default.removeItem(at: unrelated)
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("install marker fixture".utf8).write(to: support.appendingPathComponent("install.marker"))
        try Data("diagnostic fixture".utf8).write(to: caches.appendingPathComponent("diagnostic-events.jsonl"))
        try Data("unrelated".utf8).write(to: unrelated.appendingPathComponent("keep.txt"))
        let suite = try #require(UserDefaults(suiteName: domain))
        suite.set("owned-value", forKey: "owned-fixture")

        let cleaner = OwnedClientDataCleaner(
            keychainServices: ["ru.zdeep.tests.cleanup.\(UUID().uuidString)"],
            fileRoots: [support, caches],
            defaultsDomain: domain
        )
        let progress = await cleaner.clean(remaining: [.files, .preferences])

        #expect(progress.remaining.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: caches.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.txt").path))
        #expect(suite.persistentDomain(forName: domain)?.isEmpty ?? true)
    }
}

private extension OwnedDataCategory {
    static let allTestCategories: [OwnedDataCategory] = [.keychain, .files, .preferences, .webData]
}

private actor FakeOwnedDataCategoryAdapter: OwnedDataCategoryCleaning {
    private(set) var cleanCount = 0
    private var failuresRemaining: Int
    private let leavesDataAfterCleanup: Bool

    init(failuresRemaining: Int = 0, leavesDataAfterCleanup: Bool = false) {
        self.failuresRemaining = failuresRemaining
        self.leavesDataAfterCleanup = leavesDataAfterCleanup
    }

    func clean() async throws {
        cleanCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeCleanupError.injected
        }
    }

    func isEmpty() async throws -> Bool { !leavesDataAfterCleanup }
}

private enum FakeCleanupError: Error {
    case injected
}

private func addKeychainItem(service: String, account: String) throws {
    var query = keychainQuery(service: service)
    query[kSecAttrAccount as String] = account
    query[kSecValueData as String] = Data("fixture".utf8)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
}

private func keychainRecordCount(service: String) throws -> Int {
    var query = keychainQuery(service: service)
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = false
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return 0 }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
    return (result as? [[String: Any]])?.count ?? 0
}

private func keychainQuery(service: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any
    ]
}
