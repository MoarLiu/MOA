import Foundation

extension ConfigProfileController {
    func generateConfig(_ config: String, selecting profile: ConfigProfile) -> String {
        var output = config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultConfig : config
        let providerID = providerID(for: profile, in: output)
        let providerTable = "model_providers.\(providerID)"
        let extraProviderLines = providerExtraLines(in: output, table: providerTable)

        output = removeProviderTables(from: output)
        let remoteConnectionsEnabled = remoteConnectionsEnabled(in: output)

        output = upsertRootTomlStringValue(in: output, key: "model_provider", value: providerID)
        if let model = profile.resolvedModel {
            output = upsertRootTomlStringValue(in: output, key: "model", value: model)
        }
        output = setRemoteConnections(remoteConnectionsEnabled, in: output)
        output = insertProviderBlock(providerBlock(for: profile, providerID: providerID, extraLines: extraProviderLines), into: output)
        return collapseTomlBlankLines(output)
    }

    func providerID(for profile: ConfigProfile, in config: String) -> String {
        if profile.usesLocalProviderBridge {
            if profile.resolvedProviderKind == .deepseek && profile.name.localizedCaseInsensitiveContains("deepseek") {
                return "moa-deepseek"
            }
            let slug = Self.providerIdentifierSlug(profile.name)
            return slug.isEmpty ? "moa-bridge" : "moa-\(slug)"
        }
        return selectedProviderID(in: config)
    }

    static func providerIdentifierSlug(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
    }

    func syncedMoaConfig() throws -> String {
        var moaConfig = (try? String(contentsOf: moaConfigURL, encoding: .utf8)) ?? Self.defaultConfig
        guard fileManager.fileExists(atPath: codexConfigURL.path),
              let codexConfig = try? String(contentsOf: codexConfigURL, encoding: .utf8),
              !codexConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return moaConfig
        }

        let syncedConfig = syncConfigStructure(from: codexConfig, into: moaConfig)
        if syncedConfig != moaConfig {
            moaConfig = syncedConfig
            try writeText(moaConfig, to: moaConfigURL)
        }

        return moaConfig
    }

    func syncConfigStructure(from codexConfig: String, into moaConfig: String) -> String {
        let codexEntries = tomlEntries(in: codexConfig)
        guard !codexEntries.isEmpty else {
            return moaConfig
        }

        let moaEntries = tomlEntries(in: moaConfig)
        var output = moaConfig

        var knownPaths = Set(moaEntries.map(\.path))
        for entry in codexEntries where !knownPaths.contains(entry.path) && !isMoaManagedConfigPath(entry.path) {
            output = appendTomlEntry(entry, to: output)
            knownPaths.insert(entry.path)
        }

        let refreshedEntries = tomlEntries(in: output)
        for entry in codexEntries where isMarketplaceLastUpdated(entry.path) {
            guard let existing = refreshedEntries.first(where: { $0.path == entry.path }),
                  existing.value != entry.value
            else {
                continue
            }

            output = replaceTomlEntry(existing, with: entry.value, in: output)
        }

        return output
    }

    typealias TomlEntry = MoaTomlEditor.Entry

    func tomlEntries(in text: String) -> [TomlEntry] {
        MoaTomlEditor.entries(in: text)
    }

    func parseTomlTableName(from line: String) -> String? {
        MoaTomlEditor.tableName(from: line)
    }

    func parseTomlKeyValue(from line: String) -> (key: String, value: String)? {
        MoaTomlEditor.keyValue(from: line)
    }

    func trimTomlInlineComment(from value: String) -> String {
        MoaTomlEditor.trimInlineComment(from: value)
    }

    func appendTomlEntry(_ entry: TomlEntry, to text: String) -> String {
        var output = text
        if !output.hasSuffix("\n") {
            output.append("\n")
        }

        if entry.table.isEmpty {
            let insertion = tomlRootInsertionIndex(in: output)
            let prefix = insertion > output.startIndex && output[output.index(before: insertion)] == "\n" ? "" : "\n"
            output.insert(contentsOf: "\(prefix)\(entry.lineText)\n", at: insertion)
            return output
        }

        if !tomlHasTable(entry.table, in: output) {
            output.append("\n[\(entry.table)]\n")
            output.append("\(entry.lineText)\n")
            return output
        }

        let insertion = tomlTableInsertionIndex(for: entry.table, in: output) ?? output.endIndex
        let prefix = insertion > output.startIndex && output[output.index(before: insertion)] == "\n" ? "" : "\n"
        output.insert(contentsOf: "\(prefix)\(entry.lineText)\n", at: insertion)
        return output
    }

    func tomlRootInsertionIndex(in text: String) -> String.Index {
        var insertionIndex = text.endIndex

        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.isStructural, parseTomlTableName(from: line) != nil {
                return context.contentRange.lowerBound
            }
            insertionIndex = context.nextLineStart
        }

        return insertionIndex
    }

    func tomlHasTable(_ table: String, in text: String) -> Bool {
        tomlTableNames(in: text).contains(table)
    }

    func tomlTableInsertionIndex(for table: String, in text: String) -> String.Index? {
        var currentTable = ""
        var foundTable = false
        var insertionIndex: String.Index?
        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if context.isStructural, let tableName = parseTomlTableName(from: line) {
                if foundTable && tableName != currentTable {
                    return context.contentRange.lowerBound
                }

                currentTable = tableName
                if tableName == table {
                    foundTable = true
                    insertionIndex = context.nextLineStart
                }
            } else if foundTable {
                insertionIndex = context.nextLineStart
            }
        }

        return foundTable ? insertionIndex : nil
    }

    func replaceTomlEntry(_ entry: TomlEntry, with value: String, in text: String) -> String {
        var output = text
        if let range = Range(NSRange(entry.lineRange, in: text), in: output) {
            output.replaceSubrange(range, with: "\(entry.key) = \(value)")
        }
        return output
    }

    func isMarketplaceLastUpdated(_ path: String) -> Bool {
        path.hasPrefix("marketplaces.") && path.hasSuffix(".last_updated")
    }

    func isMoaManagedConfigPath(_ path: String) -> Bool {
        path == "model_provider"
            || path.hasPrefix("model_providers.")
            || path == "features.remote_connections"
            || path == "features.remote_control"
    }

    func rootTomlStringValue(in text: String, key: String) -> String? {
        tomlStringValue(in: text, table: "", key: key)
    }

    func tomlStringValue(in text: String, table: String, key: String) -> String? {
        guard let entry = tomlEntries(in: text).first(where: { $0.table == table && $0.key == key }) else {
            return nil
        }

        let value = entry.value
        guard (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) else {
            return nil
        }

        return unquoteTomlString(value)
    }

    func providerID(fromTable table: String) -> String? {
        let prefix = "model_providers."
        guard table.hasPrefix(prefix) else {
            return nil
        }

        let id = String(table.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    func selectedProviderID(in config: String) -> String {
        let rootProvider = rootTomlStringValue(in: config, key: "model_provider")
        let providerIDs = providerTableIDs(in: config)

        if let rootProvider, !rootProvider.isEmpty {
            let sameNameTables = providerIDs.filter { $0.caseInsensitiveCompare(rootProvider) == .orderedSame }
            if let lowerCaseTable = sameNameTables.first(where: { $0 == $0.lowercased() }) {
                return lowerCaseTable
            }
            if let exactTable = sameNameTables.first(where: { $0 == rootProvider }) {
                return exactTable
            }
        }

        if let lowerCaseTable = providerIDs.first(where: { $0 == $0.lowercased() && $0.caseInsensitiveCompare("codex") != .orderedSame }) {
            return lowerCaseTable
        }

        if let firstNonDefault = providerIDs.first(where: { $0.caseInsensitiveCompare("codex") != .orderedSame }) {
            return firstNonDefault
        }

        if let firstProvider = providerIDs.first {
            return firstProvider
        }

        if let rootProvider, !rootProvider.isEmpty {
            return rootProvider
        }

        return "Codex"
    }

    func providerTableIDs(in text: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()

        for table in tomlTableNames(in: text) {
            guard let id = providerID(fromTable: table), !seen.contains(id) else {
                continue
            }
            ids.append(id)
            seen.insert(id)
        }

        return ids
    }

    func tomlTableNames(in text: String) -> [String] {
        MoaTomlEditor.lineContexts(in: text).compactMap { context in
            guard context.isStructural else { return nil }
            return parseTomlTableName(from: context.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func providerExtraLines(in text: String, table: String) -> [String] {
        let managedKeys: Set<String> = ["name", "base_url", "experimental_bearer_token", "wire_api", "requires_openai_auth"]
        return tomlEntries(in: text)
            .filter { $0.table == table && !managedKeys.contains($0.key) }
            .map(\.lineText)
    }

    func providerBlock(for profile: ConfigProfile, providerID: String, extraLines: [String]) -> String {
        MoaCodexConfigEditor.providerBlock(
            providerID: providerID,
            displayName: profile.usesLocalProviderBridge ? providerDisplayName(for: profile) : nil,
            baseURL: profile.codexBaseURL,
            apiKey: profile.codexBearerToken,
            extraLines: extraLines
        )
    }

    func providerDisplayName(for profile: ConfigProfile) -> String {
        profile.usesLocalProviderBridge ? "Moa \(profile.name)" : profile.name
    }

    func removeProviderTables(from text: String) -> String {
        removeTomlTables(in: text) { providerID(fromTable: $0) != nil }
    }

    func removeTomlTables(in text: String, where shouldRemove: (String) -> Bool) -> String {
        var outputLines: [String] = []
        var skipping = false

        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.isStructural, let tableName = parseTomlTableName(from: trimmed) {
                skipping = shouldRemove(tableName)
            }

            if !skipping {
                outputLines.append(line)
            }
        }

        return collapseTomlBlankLines(outputLines.joined(separator: "\n"))
    }

    func remoteConnectionsEnabled(in text: String) -> Bool {
        tomlBoolValue(in: text, table: "features", key: "remote_connections") == true
            && tomlBoolValue(in: text, table: "features", key: "remote_control") == true
    }

    func setRemoteConnections(_ enabled: Bool, in text: String) -> String {
        enabled ? normalizeFeatures(in: text) : removeRemoteConnectionFeatures(in: text)
    }

    func normalizeFeatures(in text: String) -> String {
        let featureLines = [
            "[features]",
            "remote_connections = true",
            "remote_control = true"
        ]

        guard let tableRange = tomlTableBlockRange(for: "features", in: text) else {
            var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
            if !output.hasSuffix("\n\n") {
                output.append("\n")
            }
            output.append(featureLines.joined(separator: "\n"))
            return output
        }

        let existingLines = MoaTomlEditor.lineContexts(in: String(text[tableRange]))
            .dropFirst()
            .filter { context in
                let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !context.isStructural || !trimmed.isEmpty else {
                    return false
                }

                if context.isStructural,
                   let keyValue = parseTomlKeyValue(from: context.text),
                   keyValue.key == "remote_connections" || keyValue.key == "remote_control" {
                    return false
                }

                return true
            }
        let replacement = (featureLines + existingLines.map(\.text)).joined(separator: "\n")
        var output = text
        let suffix = tableRange.upperBound < output.endIndex ? "\n\n" : ""
        output.replaceSubrange(tableRange, with: replacement + suffix)
        return output
    }

    func removeRemoteConnectionFeatures(in text: String) -> String {
        var output: [String] = []
        var featureHeader: String?
        var featureLines: [MoaTomlEditor.LineContext] = []
        var inFeatures = false

        func flushFeatures() {
            guard let featureHeader else {
                return
            }

            let remaining = featureLines.filter { context in
                guard context.isStructural,
                      let keyValue = parseTomlKeyValue(from: context.text)
                else {
                    return true
                }
                return keyValue.key != "remote_connections" && keyValue.key != "remote_control"
            }
            let hasNonEmptyContent = remaining.contains { context in
                let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }

            if hasNonEmptyContent {
                output.append(featureHeader)
                output.append(contentsOf: remaining.map(\.text))
            }
        }

        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if context.isStructural, let table = parseTomlTableName(from: trimmed) {
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
                featureLines.append(context)
            } else {
                output.append(line)
            }
        }

        if inFeatures {
            flushFeatures()
        }

        return collapseTomlBlankLines(output.joined(separator: "\n"))
    }

    func tomlBoolValue(in text: String, table: String, key: String) -> Bool? {
        var currentTable = ""

        for context in MoaTomlEditor.lineContexts(in: text) where context.isStructural {
            let line = context.text
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
    func insertProviderBlock(_ providerBlock: String, into text: String) -> String {
        guard !providerBlock.isEmpty else {
            return text
        }

        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let insertion = tomlTableInsertionIndex(for: "features", in: output) ?? output.endIndex

        if insertion == output.endIndex {
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
            if !output.hasSuffix("\n\n") {
                output.append("\n")
            }
            output.append(providerBlock)
            return output
        }

        let prefix: String
        let beforeInsertion = output[..<insertion]
        if beforeInsertion.hasSuffix("\n\n") {
            prefix = ""
        } else if beforeInsertion.hasSuffix("\n") {
            prefix = "\n"
        } else {
            prefix = "\n\n"
        }

        let suffix = output[insertion...].hasPrefix("\n") ? "" : "\n"
        output.insert(contentsOf: "\(prefix)\(providerBlock)\n\(suffix)", at: insertion)
        return output
    }

    func collapseTomlBlankLines(_ text: String) -> String {
        MoaTomlEditor.collapseBlankLinesBeforeTables(text)
    }

    func tomlTableBlockRange(for table: String, in text: String) -> Range<String.Index>? {
        var tableStart: String.Index?

        for context in MoaTomlEditor.lineContexts(in: text) where context.isStructural {
            let line = context.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if let tableName = parseTomlTableName(from: line) {
                if let start = tableStart, tableName != table {
                    return start..<context.contentRange.lowerBound
                }

                if tableName == table {
                    tableStart = context.contentRange.lowerBound
                }
            }
        }

        if let start = tableStart {
            return start..<text.endIndex
        }

        return nil
    }

    func firstTomlStringValue(in text: String, key: String) -> String? {
        guard let entry = tomlEntries(in: text).first(where: { $0.key == key }) else {
            return nil
        }
        let raw = entry.value
        guard (raw.hasPrefix("\"") && raw.hasSuffix("\""))
                || (raw.hasPrefix("'") && raw.hasSuffix("'"))
        else {
            return nil
        }
        return unquoteTomlString(raw)
    }

    func upsertRootTomlStringValue(in text: String, key: String, value: String) -> String {
        let quoted = tomlQuoted(value)
        if let entry = tomlEntries(in: text).first(where: { $0.table.isEmpty && $0.key == key }) {
            return replaceTomlEntry(entry, with: quoted, in: text)
        }

        var output = text
        if !output.hasSuffix("\n") {
            output.append("\n")
        }

        let insertion = tomlRootInsertionIndex(in: output)
        let prefix = insertion > output.startIndex && output[output.index(before: insertion)] == "\n" ? "" : "\n"
        output.insert(contentsOf: "\(prefix)\(key) = \(quoted)\n", at: insertion)
        return output
    }

    func tomlQuoted(_ value: String) -> String {
        MoaTomlEditor.quotedString(value)
    }

    func unquoteTomlString(_ raw: String) -> String {
        MoaTomlEditor.unquoteString(raw)
    }
}
