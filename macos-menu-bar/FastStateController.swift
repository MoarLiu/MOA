import AppKit
import Foundation

private enum FastModeError: LocalizedError {
    case invalidStateFile(URL)

    var errorDescription: String? {
        switch self {
        case .invalidStateFile(let url):
            return MoaL10n.format("Invalid JSON state file: %@", url.path)
        }
    }
}

final class FastStateController {
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let codexHome: URL
    private let codexApp: URL
    private let backupDir: URL

    private var stateURL: URL {
        codexHome.appendingPathComponent(".codex-global-state.json")
    }

    private var stateBackupURL: URL {
        codexHome.appendingPathComponent(".codex-global-state.json.bak")
    }

    private var codexConfigURL: URL {
        codexHome.appendingPathComponent("config.toml")
    }

    private var moaConfigURL: URL {
        moaHome.appendingPathComponent("config.toml")
    }

    private var moaHome: URL {
        MoaDataRoot.currentURL(environment: environment)
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let codexHomePath = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.codex"
        let codexAppPath = environment["CODEX_APP"].flatMap { $0.isEmpty ? nil : $0 } ?? "/Applications/Codex.app"

        codexHome = URL(fileURLWithPath: codexHomePath).standardizedFileURL
        codexApp = URL(fileURLWithPath: codexAppPath).standardizedFileURL
        backupDir = codexHome.appendingPathComponent("fast-toggle-backups")
    }

    func serviceTier() -> String? {
        guard
            let root = try? loadState(from: stateURL),
            let atom = root["electron-persisted-atom-state"] as? [String: Any],
            let tier = atom["default-service-tier"] as? String
        else {
            return nil
        }

        return tier
    }

    func isFastEnabled() -> Bool {
        serviceTier() == "fast"
    }

    func applyFastMode(_ enabled: Bool) throws {
        quitCodexIfNeeded()
        try backupExistingFiles()
        try rewriteStateFile(stateURL, enabled: enabled)
        try rewriteStateFile(stateBackupURL, enabled: enabled)
        openCodexIfAvailable()
    }

    func isRemoteConnectionsEnabled() -> Bool {
        guard let config = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            return false
        }

        return remoteConnectionsEnabled(in: config)
    }

    func applyRemoteConnections(_ enabled: Bool) throws {
        quitCodexIfNeeded()
        try backupConfigFiles()
        try rewriteRemoteConnectionsConfig(codexConfigURL, enabled: enabled, createIfMissing: enabled)
        if fileManager.fileExists(atPath: moaConfigURL.path) {
            try rewriteRemoteConnectionsConfig(moaConfigURL, enabled: enabled, createIfMissing: false)
        }
        openCodexIfAvailable()
    }

    func reopenCodex() {
        quitCodexIfNeeded()
        openCodexIfAvailable()
    }

    func quitCodex() {
        quitCodexIfNeeded()
    }

    func openCodex() {
        openCodexIfAvailable()
    }

    private func backupExistingFiles() throws {
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for url in [stateURL, stateBackupURL] where fileManager.fileExists(atPath: url.path) {
            let stamp = Self.timestamp()
            let backupName = "\(url.lastPathComponent).\(stamp)"
            let destination = backupDir.appendingPathComponent(backupName)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: url, to: destination)
        }
    }

    private func backupConfigFiles() throws {
        let existingFiles = [
            (label: "codex", url: codexConfigURL),
            (label: "moa", url: moaConfigURL)
        ].filter { fileManager.fileExists(atPath: $0.url.path) }

        guard !existingFiles.isEmpty else {
            return
        }

        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = Self.timestamp()

        for file in existingFiles {
            let destination = backupDir.appendingPathComponent("\(file.label)-\(file.url.lastPathComponent).\(stamp)")
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: file.url, to: destination)
        }
    }

    private func rewriteStateFile(_ url: URL, enabled: Bool) throws {
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)

        var root = try loadState(from: url)
        var atom = root["electron-persisted-atom-state"] as? [String: Any] ?? [:]

        if enabled {
            atom["has-user-changed-service-tier"] = true
            atom["default-service-tier"] = "fast"
            atom["has-seen-fast-mode-announcement"] = true
        } else {
            atom.removeValue(forKey: "has-user-changed-service-tier")
            atom.removeValue(forKey: "default-service-tier")
            atom.removeValue(forKey: "has-seen-fast-mode-announcement")
        }

        root["electron-persisted-atom-state"] = atom
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        var output = Data(data)
        output.append(0x0a)
        try output.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func rewriteRemoteConnectionsConfig(_ url: URL, enabled: Bool, createIfMissing: Bool) throws {
        guard fileManager.fileExists(atPath: url.path) || createIfMissing else {
            return
        }

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let config = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let output = setRemoteConnections(enabled, in: config)
        var text = output
        if !text.hasSuffix("\n") {
            text.append("\n")
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func remoteConnectionsEnabled(in text: String) -> Bool {
        tomlBoolValue(in: text, table: "features", key: "remote_connections") == true
            && tomlBoolValue(in: text, table: "features", key: "remote_control") == true
    }

    private func setRemoteConnections(_ enabled: Bool, in text: String) -> String {
        enabled ? enableRemoteConnections(in: text) : disableRemoteConnections(in: text)
    }

    private func enableRemoteConnections(in text: String) -> String {
        let featureLines = [
            "[features]",
            "remote_connections = true",
            "remote_control = true"
        ]
        var output: [String] = []
        var inFeatures = false
        var foundFeatures = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let table = parseTomlTableName(from: trimmed) {
                inFeatures = table == "features"
                if inFeatures {
                    foundFeatures = true
                    output.append(contentsOf: featureLines)
                } else {
                    output.append(line)
                }
                continue
            }

            if inFeatures,
               let keyValue = parseTomlKeyValue(from: line),
               keyValue.key == "remote_connections" || keyValue.key == "remote_control" {
                continue
            }

            output.append(line)
        }

        if !foundFeatures {
            if !output.isEmpty, output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                output.append("")
            }
            output.append(contentsOf: featureLines)
        }

        return collapseBlankLines(output.joined(separator: "\n"))
    }

    private func disableRemoteConnections(in text: String) -> String {
        var output: [String] = []
        var featureHeader: String?
        var featureLines: [String] = []
        var inFeatures = false

        func flushFeatures() {
            guard let featureHeader else {
                return
            }

            let remaining = featureLines.filter { line in
                guard let keyValue = parseTomlKeyValue(from: line) else {
                    return true
                }
                return keyValue.key != "remote_connections" && keyValue.key != "remote_control"
            }
            let hasNonEmptyContent = remaining.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }

            if hasNonEmptyContent {
                output.append(featureHeader)
                output.append(contentsOf: remaining)
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let table = parseTomlTableName(from: trimmed) {
                if inFeatures {
                    flushFeatures()
                    featureHeader = nil
                    featureLines = []
                }

                inFeatures = table == "features"
                if inFeatures {
                    featureHeader = line
                } else {
                    output.append(line)
                }
                continue
            }

            if inFeatures {
                featureLines.append(line)
            } else {
                output.append(line)
            }
        }

        if inFeatures {
            flushFeatures()
        }

        return collapseBlankLines(output.joined(separator: "\n"))
    }

    private func tomlBoolValue(in text: String, table: String, key: String) -> Bool? {
        var currentTable = ""

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tableName = parseTomlTableName(from: trimmed) {
                currentTable = tableName
                continue
            }

            guard currentTable == table,
                  let keyValue = parseTomlKeyValue(from: line),
                  keyValue.key == key
            else {
                continue
            }

            switch keyValue.value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        return nil
    }

    private func parseTomlTableName(from line: String) -> String? {
        MoaTomlEditor.tableName(from: line)
    }

    private func parseTomlKeyValue(from line: String) -> (key: String, value: String)? {
        MoaTomlEditor.keyValue(from: line)
    }

    private func collapseBlankLines(_ text: String) -> String {
        MoaTomlEditor.collapseBlankLines(text)
    }

    private func loadState(from url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return ["electron-persisted-atom-state": [String: Any]()]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return ["electron-persisted-atom-state": [String: Any]()]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw FastModeError.invalidStateFile(url)
        }

        return root
    }

    private func quitCodexIfNeeded() {
        guard isCodexRunning() else { return }

        _ = run("/usr/bin/osascript", ["-e", "tell application id \"com.openai.codex\" to quit"])
        _ = waitForCodexRunning(false, timeout: 4)

        if isCodexRunning() {
            _ = run("/usr/bin/pkill", ["-f", codexExecutableMatchPattern()])
            _ = waitForCodexRunning(false, timeout: 3)
        }
    }

    private func openCodexIfAvailable() {
        guard fileManager.fileExists(atPath: codexApp.path) else { return }
        _ = run("/usr/bin/open", [codexApp.path])
    }

    private func isCodexRunning() -> Bool {
        run("/usr/bin/pgrep", ["-f", codexExecutableMatchPattern()]) == 0
    }

    private func codexExecutableMatchPattern() -> String {
        NSRegularExpression.escapedPattern(
            for: codexApp.appendingPathComponent("Contents/MacOS/Codex").path
        )
    }

    private func waitForCodexRunning(_ running: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCodexRunning() == running {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isCodexRunning() == running
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
