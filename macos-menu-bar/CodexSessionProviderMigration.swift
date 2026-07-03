import Foundation

struct CodexSessionProviderMigrationResult {
    let providerID: String
    let jsonlFilesUpdated: Int
    let sqliteRowsUpdated: Int
    let backupURL: URL
}

enum CodexSessionProviderMigrationError: LocalizedError {
    case missingModelProvider
    case sqliteUpdateFailed(path: String)
    case migrationFailedAndRestored(reason: String, backupPath: String)
    case migrationFailedRollbackFailed(reason: String, backupPath: String, rollbackReason: String)

    var errorDescription: String? {
        switch self {
        case .missingModelProvider:
            return MoaL10n.text("The current model_provider field is missing. Migration failed.")
        case .sqliteUpdateFailed(let path):
            return MoaL10n.format("Failed to update Codex SQLite history index: %@", path)
        case .migrationFailedAndRestored(let reason, let backupPath):
            return MoaL10n.format(
                "Migration failed and the previous Codex history was restored.\nReason: %@\nBackup: %@",
                reason,
                backupPath
            )
        case .migrationFailedRollbackFailed(let reason, let backupPath, let rollbackReason):
            return MoaL10n.format(
                "Migration failed and automatic rollback failed.\nReason: %@\nBackup: %@\nRollback error: %@",
                reason,
                backupPath,
                rollbackReason
            )
        }
    }
}

extension ConfigProfileController {
    func currentCodexRootModelProvider() throws -> String {
        guard fileManager.fileExists(atPath: codexConfigURL.path),
              let config = try? String(contentsOf: codexConfigURL, encoding: .utf8),
              let provider = rootTomlStringValue(in: config, key: "model_provider")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty
        else {
            throw CodexSessionProviderMigrationError.missingModelProvider
        }

        return provider
    }

    func migrateCodexSessionModelProviderToCurrentConfig() throws -> CodexSessionProviderMigrationResult {
        let providerID = try currentCodexRootModelProvider()
        return try migrateCodexSessionModelProvider(to: providerID)
    }

    func migrateCodexSessionModelProvider(to providerID: String) throws -> CodexSessionProviderMigrationResult {
        try stateLock.withLock {
            let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedProviderID.isEmpty else {
                throw CodexSessionProviderMigrationError.missingModelProvider
            }

            let backupURL = try backupCodexSessionProviderMigrationFiles()
            let jsonlFilesUpdated: Int
            let sqliteRowsUpdated: Int

            do {
                jsonlFilesUpdated = try migrateCodexSessionJSONLFiles(to: trimmedProviderID)
                sqliteRowsUpdated = try migrateCodexSessionSQLiteIndexes(to: trimmedProviderID)
            } catch {
                let originalReason = error.localizedDescription
                do {
                    try restoreCodexSessionProviderMigrationFiles(from: backupURL)
                } catch {
                    throw CodexSessionProviderMigrationError.migrationFailedRollbackFailed(
                        reason: originalReason,
                        backupPath: backupURL.path,
                        rollbackReason: error.localizedDescription
                    )
                }
                throw CodexSessionProviderMigrationError.migrationFailedAndRestored(
                    reason: originalReason,
                    backupPath: backupURL.path
                )
            }

            return CodexSessionProviderMigrationResult(
                providerID: trimmedProviderID,
                jsonlFilesUpdated: jsonlFilesUpdated,
                sqliteRowsUpdated: sqliteRowsUpdated,
                backupURL: backupURL
            )
        }
    }

    private func backupCodexSessionProviderMigrationFiles() throws -> URL {
        let destinationRoot = backupDir
            .appendingPathComponent("codex-session-provider-migration-\(Self.timestamp())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for directory in codexSessionHistoryDirectories() where fileManager.fileExists(atPath: directory.path) {
            let destination = destinationRoot.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: directory, to: destination)
        }

        for database in codexSessionStateDatabaseURLs() where fileManager.fileExists(atPath: database.path) {
            let destination = destinationRoot.appendingPathComponent(databaseBackupName(for: database))
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: database, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: database.path + suffix)
                guard fileManager.fileExists(atPath: sidecar.path) else { continue }
                let sidecarDestination = destinationRoot.appendingPathComponent(databaseBackupName(for: database) + suffix)
                try? fileManager.removeItem(at: sidecarDestination)
                try fileManager.copyItem(at: sidecar, to: sidecarDestination)
            }
        }

        return destinationRoot
    }

    private func restoreCodexSessionProviderMigrationFiles(from backupURL: URL) throws {
        for directory in codexSessionHistoryDirectories() {
            let backup = backupURL.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            guard fileManager.fileExists(atPath: backup.path) else { continue }
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: backup, to: directory)
        }

        for database in codexSessionStateDatabaseURLs() {
            let backupName = databaseBackupName(for: database)
            let backup = backupURL.appendingPathComponent(backupName)
            guard fileManager.fileExists(atPath: backup.path) else { continue }

            try? fileManager.removeItem(at: database)
            for suffix in ["-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: database.path + suffix))
            }

            try fileManager.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: backup, to: database)
            for suffix in ["-wal", "-shm"] {
                let sidecarBackup = backupURL.appendingPathComponent(backupName + suffix)
                guard fileManager.fileExists(atPath: sidecarBackup.path) else { continue }
                try fileManager.copyItem(at: sidecarBackup, to: URL(fileURLWithPath: database.path + suffix))
            }
        }
    }

    private func migrateCodexSessionJSONLFiles(to providerID: String) throws -> Int {
        var updated = 0

        for directory in codexSessionHistoryDirectories() where fileManager.fileExists(atPath: directory.path) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                if try migrateCodexSessionJSONLFile(fileURL, to: providerID) {
                    updated += 1
                }
            }
        }

        return updated
    }

    private func migrateCodexSessionJSONLFile(_ fileURL: URL, to providerID: String) throws -> Bool {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let firstLineEnd = text.firstIndex(of: "\n") else {
            return try migrateCodexSessionJSONLText(text, rest: "", fileURL: fileURL, providerID: providerID)
        }

        let firstLine = String(text[..<firstLineEnd])
        let rest = String(text[firstLineEnd...])
        return try migrateCodexSessionJSONLText(firstLine, rest: rest, fileURL: fileURL, providerID: providerID)
    }

    private func migrateCodexSessionJSONLText(_ firstLine: String, rest: String, fileURL: URL, providerID: String) throws -> Bool {
        guard let data = firstLine.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var object = parsed as? [String: Any]
        else {
            return false
        }

        guard var payload = object["payload"] as? [String: Any],
              payload["model_provider"] is String
        else {
            return false
        }

        if (payload["model_provider"] as? String) == providerID {
            return false
        }

        payload["model_provider"] = providerID
        object["payload"] = payload

        let outputData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let outputLine = String(data: outputData, encoding: .utf8) else {
            return false
        }

        try "\(outputLine)\(rest)".write(to: fileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return true
    }

    private func migrateCodexSessionSQLiteIndexes(to providerID: String) throws -> Int {
        var updated = 0

        for database in codexSessionStateDatabaseURLs() where fileManager.fileExists(atPath: database.path) {
            updated += try updateCodexSessionSQLiteIndex(database, to: providerID)
        }

        return updated
    }

    private func updateCodexSessionSQLiteIndex(_ databaseURL: URL, to providerID: String) throws -> Int {
        guard try sqliteThreadsTableHasModelProvider(in: databaseURL) else {
            return 0
        }

        let escapedProvider = providerID.replacingOccurrences(of: "'", with: "''")
        let sql = """
        BEGIN IMMEDIATE;
        UPDATE threads SET model_provider = '\(escapedProvider)' WHERE model_provider IS NOT '\(escapedProvider)';
        SELECT changes();
        COMMIT;
        """
        let output = try runSQLite(databaseURL: databaseURL, sql: sql)
        return Int(output.components(separatedBy: .whitespacesAndNewlines).last(where: { !$0.isEmpty }) ?? "0") ?? 0
    }

    private func sqliteThreadsTableHasModelProvider(in databaseURL: URL) throws -> Bool {
        let output = try runSQLite(databaseURL: databaseURL, sql: "PRAGMA table_info(threads);")
        return output.components(separatedBy: "\n").contains { line in
            line.components(separatedBy: "|").dropFirst().first == "model_provider"
        }
    }

    private func runSQLite(databaseURL: URL, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CodexSessionProviderMigrationError.sqliteUpdateFailed(path: databaseURL.path)
        }

        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            NSLog("Moa Codex SQLite migration failed for \(databaseURL.path): \(errorOutput)")
            throw CodexSessionProviderMigrationError.sqliteUpdateFailed(path: databaseURL.path)
        }

        return output
    }

    private func codexSessionHistoryDirectories() -> [URL] {
        [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }

    private func codexSessionStateDatabaseURLs() -> [URL] {
        [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("sqlite", isDirectory: true).appendingPathComponent("state_5.sqlite")
        ]
    }

    private func databaseBackupName(for databaseURL: URL) -> String {
        if databaseURL.deletingLastPathComponent().lastPathComponent == "sqlite" {
            return "sqlite-\(databaseURL.lastPathComponent)"
        }
        return databaseURL.lastPathComponent
    }
}
