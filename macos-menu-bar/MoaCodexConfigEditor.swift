import Foundation

enum MoaCodexConfigEditor {
    static func removingExperimentalBearerTokens(from text: String) -> String {
        var outputLines: [String] = []
        var currentTable = ""
        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.isStructural, let tableName = MoaTomlEditor.tableName(from: trimmed) {
                currentTable = tableName
            }
            if context.isStructural, isManagedRemovalLine(line, currentTable: currentTable) {
                continue
            }
            outputLines.append(line)
        }
        return MoaTomlEditor.collapseBlankLines(outputLines.joined(separator: "\n"))
    }

    static func restoringOfficialMode(from text: String) -> String {
        let selectedProviderID = rootTomlStringValue(in: text, key: "model_provider")
        var outputLines: [String] = []
        var currentTable = ""
        var skippingProviderTable = false

        for context in MoaTomlEditor.lineContexts(in: text) {
            let line = context.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if context.isStructural, let tableName = MoaTomlEditor.tableName(from: trimmed) {
                currentTable = tableName
                skippingProviderTable = isUnselectedMoaManagedProviderTable(
                    tableName,
                    selectedProviderID: selectedProviderID
                )
                if skippingProviderTable {
                    continue
                }
            }

            if skippingProviderTable {
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    outputLines.append(line)
                }
                continue
            }

            if context.isStructural, isOfficialRestoreRemovalLine(
                line,
                currentTable: currentTable,
                selectedProviderID: selectedProviderID
            ) {
                continue
            }

            outputLines.append(line)
        }

        return MoaTomlEditor.collapseBlankLines(outputLines.joined(separator: "\n"))
    }

    static func providerBlock(
        providerID: String,
        displayName: String? = nil,
        baseURL: String,
        apiKey: String,
        extraLines: [String]
    ) -> String {
        ([
            "[model_providers.\(providerID)]",
            "name = \(MoaTomlEditor.quotedString(displayName ?? providerID))",
            "base_url = \(MoaTomlEditor.quotedString(baseURL))",
            "experimental_bearer_token = \(MoaTomlEditor.quotedString(apiKey))",
            #"wire_api = "responses""#,
            "requires_openai_auth = true"
        ] + extraLines).joined(separator: "\n")
    }

    private static func isManagedRemovalLine(_ line: String, currentTable: String) -> Bool {
        if currentTable.isEmpty {
            return isOfficialModeRootRemovedLine(line)
        }
        guard isMoaManagedProviderTable(currentTable) else {
            return false
        }
        return isMoaProviderRemovedLine(line)
    }

    private static func isMoaProviderRemovedLine(_ line: String) -> Bool {
        let trimmed = MoaTomlEditor.trimInlineComment(from: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.firstIndex(of: "=") else {
            return false
        }

        let key = trimmed[..<equals]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key == "experimental_bearer_token" || key == "base_url"
    }

    private static func isMoaManagedProviderTable(_ tableName: String) -> Bool {
        tableName.hasPrefix("model_providers.moa-")
    }

    private static func isUnselectedMoaManagedProviderTable(_ tableName: String, selectedProviderID: String?) -> Bool {
        guard isMoaManagedProviderTable(tableName) else {
            return false
        }
        guard let selectedProviderID,
              let providerID = providerID(fromTable: tableName)
        else {
            return true
        }
        return providerID.caseInsensitiveCompare(selectedProviderID) != .orderedSame
    }

    private static func isOfficialRestoreRemovalLine(
        _ line: String,
        currentTable: String,
        selectedProviderID: String?
    ) -> Bool {
        if currentTable.isEmpty {
            return isOfficialModeRootRemovedLine(line)
        }
        if isMoaManagedProviderTable(currentTable) {
            return isMoaProviderRemovedLine(line)
        }
        guard isSelectedProviderTable(currentTable, selectedProviderID: selectedProviderID) else {
            return false
        }
        return isMoaProviderRemovedLine(line)
    }

    private static func isSelectedProviderTable(_ tableName: String, selectedProviderID: String?) -> Bool {
        guard let providerID = providerID(fromTable: tableName) else {
            return false
        }
        guard let selectedProviderID else {
            return false
        }
        return providerID.caseInsensitiveCompare(selectedProviderID) == .orderedSame
    }

    private static func providerID(fromTable tableName: String) -> String? {
        let prefix = "model_providers."
        guard tableName.hasPrefix(prefix) else {
            return nil
        }
        let providerID = String(tableName.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return providerID.isEmpty ? nil : providerID
    }

    private static func rootTomlStringValue(in text: String, key: String) -> String? {
        guard let entry = MoaTomlEditor.entries(in: text).first(where: { $0.table.isEmpty && $0.key == key }) else {
            return nil
        }
        let value = entry.value
        guard (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) else {
            return nil
        }
        return MoaTomlEditor.unquoteString(value)
    }

    private static func isOfficialModeRootRemovedLine(_ line: String) -> Bool {
        let trimmed = MoaTomlEditor.trimInlineComment(from: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.firstIndex(of: "=") else {
            return false
        }

        let key = trimmed[..<equals]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "model",
            "experimental_bearer_token",
            "base_url"
        ].contains(key)
    }

}
