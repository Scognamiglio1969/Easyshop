import Foundation

enum RecoveryServiceError: LocalizedError {
    case applicationSupportUnavailable
    case cannotCreateStorage(String)
    case cannotWriteSnapshot(String)
    case cannotDeleteSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Easyshop non riesce ad accedere alla cartella Application Support locale."
        case .cannotCreateStorage(let detail):
            "Easyshop non riesce a preparare il recupero automatico: \(detail)"
        case .cannotWriteSnapshot(let detail):
            "Il recupero automatico non è stato salvato: \(detail)"
        case .cannotDeleteSnapshot(let detail):
            "Il recupero automatico non può essere eliminato: \(detail)"
        }
    }
}

struct RecoverySnapshotInfo: Equatable {
    let documentName: String
    let modifiedAt: Date
    let byteCount: Int64
}

/// Maintains one crash-recovery snapshot for Easyshop's single-document workspace.
/// The snapshot is local-only, excluded from backup/sync, written atomically and
/// protected with owner-only filesystem permissions. It is deliberately separate
/// from normal Save/Save As semantics.
@MainActor
enum RecoveryService {
    private static let directoryName = "Recovery"
    private static let snapshotName = "Autosave.easyshop"

    @discardableResult
    static func autosave(_ document: EditorDocument) throws -> RecoverySnapshotInfo {
        let data = try ProjectIO.encodedProjectData(for: document)
        let destination = try snapshotURL(createDirectory: true)
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path
            )
            try excludeFromBackup(destination)
        } catch let error as ProjectIOError {
            throw error
        } catch {
            throw RecoveryServiceError.cannotWriteSnapshot(error.localizedDescription)
        }
        return RecoverySnapshotInfo(
            documentName: document.name,
            modifiedAt: Date(),
            byteCount: Int64(data.count)
        )
    }

    /// Returns nil when no recovery exists. A recovered document has no file URL,
    /// ensuring that the next normal save asks for a destination instead of
    /// overwriting the hidden recovery snapshot.
    static func recoverLatest() throws -> EditorDocument? {
        let url = try snapshotURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > ProjectSafetyLimits.maximumProjectBytes {
            throw ProjectIOError.projectTooLarge(
                actualBytes: Int64(fileSize),
                maximumBytes: ProjectSafetyLimits.maximumProjectBytes
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try ProjectIO.decodeProjectData(data, sourceURL: nil)
    }

    static func recoveryInfo() throws -> RecoverySnapshotInfo? {
        let url = try snapshotURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let document = try recoverLatest()
        guard let document else { return nil }
        return RecoverySnapshotInfo(
            documentName: document.name,
            modifiedAt: values.contentModificationDate ?? Date.distantPast,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }

    static func deleteRecovery() throws {
        let url = try snapshotURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw RecoveryServiceError.cannotDeleteSnapshot(error.localizedDescription)
        }
    }

    static var hasRecovery: Bool {
        guard let url = try? snapshotURL(createDirectory: false) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func snapshotURL(createDirectory: Bool) throws -> URL {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RecoveryServiceError.applicationSupportUnavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("Easyshop", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)

        if createDirectory {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: directory.path
                )
                try excludeFromBackup(directory)
            } catch {
                throw RecoveryServiceError.cannotCreateStorage(error.localizedDescription)
            }
        }
        return directory.appendingPathComponent(snapshotName, isDirectory: false)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
