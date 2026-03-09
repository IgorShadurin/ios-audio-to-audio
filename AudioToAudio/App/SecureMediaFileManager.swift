import Foundation

enum SecureMediaFileError: LocalizedError {
    case localFilesOnly
    case unreadableInput
    case symbolicLinksNotAllowed
    case fileTooLarge(maxBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .localFilesOnly:
            return "Only local files can be imported."
        case .unreadableInput:
            return "The selected file could not be accessed."
        case .symbolicLinksNotAllowed:
            return "Symbolic links are not allowed."
        case .fileTooLarge(let maxBytes):
            let formatted = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            return "The selected file is larger than \(formatted)."
        }
    }
}

struct SecureMediaFileManager {
    nonisolated static let shared = SecureMediaFileManager()

    private let managedDirectoryName = "audio-to-audio-managed-media"
    private let maxImportedFileSizeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let maxManagedFileAge: TimeInterval = 24 * 60 * 60
    private let protectionClass: FileProtectionType = .complete

    nonisolated private var managedDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(managedDirectoryName, isDirectory: true)
    }

    nonisolated func prepareManagedTempDirectory() {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: managedDirectoryURL.path) {
                try fileManager.createDirectory(
                    at: managedDirectoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: protectionClass]
                )
            }
            try applyFileProtection(to: managedDirectoryURL)
            pruneExpiredFiles()
        } catch {
            // Do not block app flow if cleanup or hardening fails.
        }
    }

    nonisolated func validateReadableLocalFile(_ sourceURL: URL) throws {
        guard sourceURL.isFileURL else {
            throw SecureMediaFileError.localFilesOnly
        }

        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
        )
        guard values.isSymbolicLink != true else {
            throw SecureMediaFileError.symbolicLinksNotAllowed
        }
        guard values.isRegularFile == true else {
            throw SecureMediaFileError.unreadableInput
        }

        let size = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)
        guard size > 0 else {
            throw SecureMediaFileError.unreadableInput
        }
        guard size <= maxImportedFileSizeBytes else {
            throw SecureMediaFileError.fileTooLarge(maxBytes: maxImportedFileSizeBytes)
        }
    }

    nonisolated func copyToManagedTemp(from sourceURL: URL, accessSecurityScopedResource: Bool) throws -> URL {
        prepareManagedTempDirectory()
        let didAccess = accessSecurityScopedResource ? sourceURL.startAccessingSecurityScopedResource() : false
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try validateReadableLocalFile(sourceURL)

        let destinationURL = makeManagedTemporaryFileURL(
            prefix: "audio-source",
            preferredExtension: sourceURL.pathExtension
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try validateReadableLocalFile(destinationURL)
        try hardenFile(at: destinationURL)
        return destinationURL
    }

    nonisolated func makeManagedOutputURL(preferredExtension: String, prefix: String) throws -> URL {
        prepareManagedTempDirectory()
        let url = makeManagedTemporaryFileURL(prefix: prefix, preferredExtension: preferredExtension)
        try removeManagedFileIfPresent(url)
        return url
    }

    nonisolated func hardenFile(at fileURL: URL) throws {
        guard fileURL.isFileURL else { return }
        try applyFileProtection(to: fileURL)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableFileURL = fileURL
        try? mutableFileURL.setResourceValues(values)
    }

    nonisolated func removeManagedFileIfPresent(_ fileURL: URL?) throws {
        guard let fileURL else { return }
        guard isManagedFileURL(fileURL) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    nonisolated func isManagedFileURL(_ fileURL: URL) -> Bool {
        guard fileURL.isFileURL else { return false }

        let managedBasePath = managedDirectoryURL.standardizedFileURL.path
        let candidatePath = fileURL.standardizedFileURL.path
        return candidatePath.hasPrefix(managedBasePath + "/")
    }

    nonisolated private func makeManagedTemporaryFileURL(prefix: String, preferredExtension: String) -> URL {
        managedDirectoryURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(sanitizeFileExtension(preferredExtension))
    }

    nonisolated private func sanitizeFileExtension(_ ext: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let filteredScalars = ext.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        if filtered.isEmpty {
            return "m4a"
        }
        return String(filtered.prefix(10)).lowercased()
    }

    nonisolated private func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: protectionClass],
            ofItemAtPath: url.path
        )
    }

    nonisolated private func pruneExpiredFiles() {
        let fileManager = FileManager.default
        let now = Date()
        guard let files = try? fileManager.contentsOfDirectory(
            at: managedDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in files {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                continue
            }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > maxManagedFileAge {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}
