import Foundation
import Security
import WebKit

nonisolated protocol OwnedDataCategoryCleaning: Sendable {
    func clean() async throws
    func isEmpty() async throws -> Bool
}

struct OwnedClientDataCleaner {
    private let adapters: [OwnedDataCategory: any OwnedDataCategoryCleaning]

    init(adapters: [OwnedDataCategory: any OwnedDataCategoryCleaning]) {
        self.adapters = adapters
    }

    init(
        keychainServices: Set<String>? = nil,
        fileRoots: [URL]? = nil,
        defaultsDomain: String? = nil
    ) {
        let services = keychainServices ?? Self.applicationKeychainServices
        adapters = [
            .keychain: KeychainOwnedDataCleaner(services: services),
            .files: AppFilesCleaner(roots: fileRoots ?? Self.appOwnedFileRoots),
            .preferences: UserDefaultsCleaner(domain: defaultsDomain ?? Bundle.main.bundleIdentifier),
            .webData: PersistentWebsiteDataCleaner()
        ]
    }

    static let allCategories: Set<OwnedDataCategory> = [.keychain, .files, .preferences, .webData]

    func clean(remaining: Set<OwnedDataCategory>) async -> OwnedCleanupProgress {
        var pending = remaining
        var failures: [OwnedDataCategory: AuthFailure] = [:]
        for category in Self.cleanupOrder where pending.contains(category) {
            guard let adapter = adapters[category] else {
                failures[category] = Self.failure(for: category)
                continue
            }
            do {
                try await adapter.clean()
                guard try await adapter.isEmpty() else {
                    failures[category] = Self.failure(for: category)
                    continue
                }
                pending.remove(category)
            } catch {
                failures[category] = Self.failure(for: category)
            }
        }
        return OwnedCleanupProgress(remaining: pending, failures: failures)
    }

    private static let cleanupOrder: [OwnedDataCategory] = [.keychain, .preferences, .webData, .files]

    private static var applicationKeychainServices: Set<String> {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        return ["\(bundleIdentifier).auth"]
    }

    private static var appOwnedFileRoots: [URL] {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return [
            support.appendingPathComponent("ZDEEP", isDirectory: true),
            caches,
            documents,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]
    }

    private static func failure(for category: OwnedDataCategory) -> AuthFailure {
        let code: String
        switch category {
        case .keychain: code = "CLEANUP_KEYCHAIN"
        case .files: code = "CLEANUP_FILES"
        case .preferences: code = "CLEANUP_PREFERENCES"
        case .webData: code = "CLEANUP_WEBDATA"
        }
        return AuthFailure(
            kind: .local, stage: .storage, attemptId: UUID(),
            message: "Application data cleanup is incomplete.", diagnosticCode: code
        )
    }
}

private struct KeychainOwnedDataCleaner: OwnedDataCategoryCleaning {
    let services: Set<String>

    func clean() async throws {
        guard !services.isEmpty else { throw OwnedDataCleanupError.missingKeychainServices }
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStorageError.status(status)
            }
        }
    }

    func isEmpty() async throws -> Bool {
        guard !services.isEmpty else { throw OwnedDataCleanupError.missingKeychainServices }
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: false
            ]
            // Avoid fetching any item data; only record metadata is requested.
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
            if let records = result as? [[String: Any]], !records.isEmpty { return false }
        }
        return true
    }
}

private struct AppFilesCleaner: OwnedDataCategoryCleaning {
    let roots: [URL]

    func clean() async throws {
        let manager = FileManager.default
        for root in roots {
            guard manager.fileExists(atPath: root.path) else { continue }
            for item in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: item)
            }
        }
    }

    func isEmpty() async throws -> Bool {
        let manager = FileManager.default
        for root in roots where manager.fileExists(atPath: root.path) {
            let contents = try manager.contentsOfDirectory(atPath: root.path)
            if !contents.isEmpty { return false }
        }
        return true
    }
}

private struct UserDefaultsCleaner: OwnedDataCategoryCleaning {
    let domain: String?

    func clean() async throws {
        guard let domain else { throw OwnedDataCleanupError.missingApplicationDomain }
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    func isEmpty() async throws -> Bool {
        guard let domain else { throw OwnedDataCleanupError.missingApplicationDomain }
        return UserDefaults.standard.persistentDomain(forName: domain)?.isEmpty ?? true
    }
}

private actor PersistentWebsiteDataCleaner: OwnedDataCategoryCleaning {
    func clean() async throws {
        let records = await Self.records()
        guard !records.isEmpty else { return }
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    for: records
                ) { continuation.resume() }
            }
        }
    }

    func isEmpty() async throws -> Bool {
        await Self.records().isEmpty
    }

    private static func records() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }
}

private enum OwnedDataCleanupError: Error {
    case missingApplicationDomain
    case missingKeychainServices
}
