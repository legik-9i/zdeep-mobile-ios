import Darwin
import Foundation

nonisolated protocol InstallMarkerStorage: Sendable {
    func exists() throws -> Bool
    func create() throws
    func remove() throws
}

nonisolated final class FileInstallMarkerStorage: InstallMarkerStorage, @unchecked Sendable {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = supportDirectory.appendingPathComponent("ZDEEP/install.marker")
        }
    }

    func exists() throws -> Bool {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY)
        if descriptor >= 0 {
            Darwin.close(descriptor)
            return true
        }
        let code = errno
        if code == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    func create() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ZDEEP install marker".utf8).write(to: fileURL, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
