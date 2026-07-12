import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestError.failure(message)
    }
}

private func expectClose(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.000001) throws {
    guard abs(actual - expected) <= tolerance else {
        throw TestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func temporaryHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("moa-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@main
private enum MoaCoreTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("data root paths are Moa scoped", testDataRootPaths),
            ("profile caches distinguish data root paths", testProfileCacheDistinguishesDataRoots),
            ("legacy Moa-Lite local data migrates without overwrite", testLegacyMoaLiteLocalDataMigration),
            ("legacy Moa-Lite iCloud data migrates to Moa", testLegacyMoaLiteICloudDataMigration),
            ("legacy nested iCloud directories merge recursively", testLegacyNestedICloudDirectoryMigration),
            ("recursive migration does not follow destination symlinks", testRecursiveMigrationRejectsDestinationSymlinks),
            ("provider bridge defaults use Moa port", testProviderBridgeDefaultPort),
            ("Codex bridge provider IDs use Moa prefix", testCodexBridgeProviderIDs),
            ("TOML multiline strings survive structural edits", testTomlMultilineStringsSurviveStructuralEdits),
            ("Fast state TOML edits preserve multiline strings", testFastStateTomlMultilineStrings),
            ("official restore keeps selected provider identity", testOfficialRestoreKeepsSelectedProviderIdentity),
            ("official restore strips selected direct provider credentials", testOfficialRestoreStripsSelectedDirectProviderCredentials),
            ("Codex session provider migration requires current provider", testCodexSessionProviderMigrationRequiresCurrentProvider),
            ("Codex session provider migration updates JSONL and SQLite", testCodexSessionProviderMigrationUpdatesJSONLAndSQLite),
            ("Codex session provider migration rolls back on failure", testCodexSessionProviderMigrationRollsBackOnFailure),
            ("official account displays email from auth token", testOfficialAccountDisplaysEmailFromAuthToken),
            ("official account auth paths stay contained", testOfficialAccountAuthPathValidation),
            ("official no-account mode preserves third-party config without login", testOfficialNoAccountPreservesThirdPartyConfigWithoutLogin),
            ("official no-account mode captures current login without selecting it", testOfficialNoAccountCapturesCurrentLoginWithoutSelectingIt),
            ("official no-account mode selects first direct config when none selected", testOfficialNoAccountSelectsFirstDirectConfigWhenNoneSelected),
            ("official no-account mode deduplicates current login by email", testOfficialNoAccountDeduplicatesCurrentLoginByEmail),
            ("official account list syncs selected account email", testOfficialAccountListSyncsSelectedAccountEmail),
            ("LiteLLM preset no longer uses original Moa model name", testLiteLLMPresetName),
            ("updater compares versions and parses release feed", testUpdaterVersionComparisonAndFeedParsing),
            ("updater prunes old backups", testUpdaterBackupPruning),
            ("GPT-5.6 family uses current local pricing", testGPT56Pricing),
            ("Codex usage ignores inherited model-less token history", testCodexUsageIgnoresInheritedHistory),
            ("remote pricing catalog parses, merges, and overrides fallback", testRemotePricingCatalog),
            ("pricing updater schedules the daily local check", testPricingUpdateSchedule),
            ("ZCode GLM pricing is estimated from usage tokens", testZCodePricing),
            ("ZCode usage scanner aggregates local SQLite usage", testZCodeUsageScanner),
            ("provider bridge ports reject invalid boundaries", testProviderBridgePortValidation),
            ("provider bridge streaming usage precedes completion", testProviderBridgeStreamingUsageOrder),
            ("Claude live files and selected state roll back together", testClaudeStateTransactionRollback),
            ("Codex profile state rolls back together", testCodexStateTransactionRollback),
            ("Codex official account state rolls back together", testCodexOfficialAccountTransactionRollback),
            ("data packages round trip without temporary leaks", testDataPackageRoundTripAndCleanup),
            ("ZCode scanner drains large subprocess output", testZCodeUsageScannerLargeOutput)
        ]

        var failures: [String] = []
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL \(name): \(error)")
            }
        }

        if !failures.isEmpty {
            fputs(failures.joined(separator: "\n") + "\n", stderr)
            exit(1)
        }
    }

    private static func testDataRootPaths() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = ["HOME": home.path]
        try expect(MoaDataRoot.localURL(environment: environment).lastPathComponent == ".moa", "local data root should be ~/.moa")
        try expect(MoaDataRoot.supportDirectory(environment: environment).lastPathComponent == "Moa", "Application Support root should be Moa")
        try expect(MoaDataRoot.iCloudURL(environment: environment).lastPathComponent == "Moa", "iCloud folder should be Moa")
        try expect(MoaDataRoot.legacyNestedICloudURL(environment: environment).lastPathComponent == ".moa", "legacy nested iCloud folder should be .moa")
        try expect(MoaDataRoot.currentURL(environment: environment).path.hasSuffix("/.moa"), "default current root should stay local")
    }

    private static func testProfileCacheDistinguishesDataRoots() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let environment = [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex", isDirectory: true).path
        ]
        let controller = ConfigProfileController(environment: environment)
        _ = try controller.profiles()

        let localRoot = MoaDataRoot.localURL(environment: environment)
        let cloudRoot = MoaDataRoot.iCloudURL(environment: environment)
        try fileManager.createDirectory(at: cloudRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: localRoot, to: cloudRoot)
        let cloudProfile = ConfigProfile(
            id: UUID().uuidString,
            name: "Cloud Profile",
            baseURL: "https://cloud.example/v1",
            apiKey: "cloud-key"
        )
        let cloudDatabase = ProfileDatabase(selectedProfileID: cloudProfile.id, profiles: [cloudProfile])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cloudDatabaseURL = cloudRoot.appendingPathComponent("profiles.json")
        try encoder.encode(cloudDatabase).write(to: cloudDatabaseURL, options: .atomic)
        let sharedModified = Date(timeIntervalSince1970: 1_700_000_000)
        try fileManager.setAttributes([.modificationDate: sharedModified], ofItemAtPath: controller.databaseURL.path)
        _ = try controller.profiles()
        try fileManager.setAttributes([.modificationDate: sharedModified], ofItemAtPath: cloudDatabaseURL.path)

        let support = MoaDataRoot.supportDirectory(environment: environment)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try Data().write(to: support.appendingPathComponent("icloud-data-root-enabled"))
        let cloudProfiles = try controller.profiles()
        try expect(cloudProfiles.map(\.id) == [cloudProfile.id], "cache lookup must include the active data-root path, not only mtime")
    }

    private static func testLegacyMoaLiteLocalDataMigration() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fileManager = FileManager.default
        let environment = ["HOME": home.path]
        let oldLocal = home.appendingPathComponent(".moa", isDirectory: true)
        let newLocal = MoaDataRoot.localURL(environment: environment)
        let legacyLocal = home.appendingPathComponent(".moa-lite", isDirectory: true)
        try fileManager.createDirectory(at: legacyLocal, withIntermediateDirectories: true)
        try "legacy".write(to: legacyLocal.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)

        let migrated = try MoaDataRoot.migrateLegacyMoaLiteRootsIfNeeded(environment: environment)
        try expect(migrated, "legacy local data should migrate")
        let migratedProfileData = try String(contentsOf: newLocal.appendingPathComponent("profiles.json"), encoding: .utf8)
        try expect(migratedProfileData == "legacy", "legacy profile data should copy to ~/.moa")
        try expect(fileManager.fileExists(atPath: legacyLocal.path), "migration should leave ~/.moa-lite in place")

        try fileManager.removeItem(at: newLocal)
        try fileManager.createDirectory(at: oldLocal, withIntermediateDirectories: true)
        try "existing".write(to: oldLocal.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        try "changed-legacy".write(to: legacyLocal.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)

        _ = try MoaDataRoot.migrateLegacyMoaLiteRootsIfNeeded(environment: environment)
        let existingProfileData = try String(contentsOf: newLocal.appendingPathComponent("profiles.json"), encoding: .utf8)
        try expect(existingProfileData == "existing", "migration should not overwrite existing ~/.moa data")
    }

    private static func testLegacyMoaLiteICloudDataMigration() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fileManager = FileManager.default
        let environment = ["HOME": home.path]
        let oldSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Moa-Lite", isDirectory: true)
        let oldICloud = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Moa-Lite", isDirectory: true)
        try fileManager.createDirectory(at: oldSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: oldICloud, withIntermediateDirectories: true)
        try Data().write(to: oldSupport.appendingPathComponent("icloud-data-root-enabled"))
        try "icloud".write(to: oldICloud.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        let existingAccounts = oldICloud.appendingPathComponent("codex-auth/accounts", isDirectory: true)
        let nestedAccounts = oldICloud.appendingPathComponent(".moa-lite/codex-auth/accounts", isDirectory: true)
        try fileManager.createDirectory(at: existingAccounts, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedAccounts, withIntermediateDirectories: true)
        try "existing".write(to: existingAccounts.appendingPathComponent("existing.json"), atomically: true, encoding: .utf8)
        try "missing".write(to: nestedAccounts.appendingPathComponent("missing.json"), atomically: true, encoding: .utf8)

        let migrated = try MoaDataRoot.migrateLegacyMoaLiteRootsIfNeeded(environment: environment)
        let newSupport = MoaDataRoot.supportDirectory(environment: environment)
        let newICloud = MoaDataRoot.iCloudURL(environment: environment)
        try expect(migrated, "legacy iCloud data should migrate")
        try expect(fileManager.fileExists(atPath: newSupport.appendingPathComponent("icloud-data-root-enabled").path), "iCloud state should migrate to Moa support directory")
        let migratedICloudProfileData = try String(contentsOf: newICloud.appendingPathComponent("profiles.json"), encoding: .utf8)
        try expect(migratedICloudProfileData == "icloud", "legacy iCloud data should copy to iCloud Drive/Moa")
        let copiedAfterMigration = try MoaDataRoot.copyMissingContents(
            from: newICloud.appendingPathComponent(".moa-lite", isDirectory: true),
            to: newICloud,
            fileManager: fileManager
        )
        try expect(
            fileManager.fileExists(atPath: newICloud.appendingPathComponent("codex-auth/accounts/missing.json").path),
            "legacy nested migration should descend into existing destination directories"
        )
        try expect(!copiedAfterMigration, "the migration itself should merge nested content without a second pass")
        try expect(MoaDataRoot.currentURL(environment: environment).lastPathComponent == "Moa", "current root should use migrated Moa iCloud folder")
    }

    private static func testLegacyNestedICloudDirectoryMigration() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let environment = ["HOME": home.path]
        let cloudRoot = MoaDataRoot.iCloudURL(environment: environment)
        let nestedRoot = MoaDataRoot.legacyNestedICloudURL(environment: environment)
        try fileManager.createDirectory(at: cloudRoot.appendingPathComponent("codex-auth/accounts"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedRoot.appendingPathComponent("codex-auth/accounts"), withIntermediateDirectories: true)
        try "authoritative".write(
            to: cloudRoot.appendingPathComponent("codex-auth/accounts/existing.json"),
            atomically: true,
            encoding: .utf8
        )
        try "legacy".write(
            to: nestedRoot.appendingPathComponent("codex-auth/accounts/missing.json"),
            atomically: true,
            encoding: .utf8
        )
        let support = MoaDataRoot.supportDirectory(environment: environment)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try Data().write(to: support.appendingPathComponent("icloud-data-root-enabled"))

        let controller = MoaDataPackageController(environment: environment)
        let repaired = try controller.repairLegacyICloudDataSplitIfNeeded()
        try expect(repaired, "legacy nested directory data should be merged")
        try expect(
            fileManager.fileExists(atPath: cloudRoot.appendingPathComponent("codex-auth/accounts/missing.json").path),
            "nested account files should be copied recursively"
        )
        let existing = try String(
            contentsOf: cloudRoot.appendingPathComponent("codex-auth/accounts/existing.json"),
            encoding: .utf8
        )
        try expect(existing == "authoritative", "recursive merge must not overwrite current cloud files")
    }

    private static func testRecursiveMigrationRejectsDestinationSymlinks() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let source = home.appendingPathComponent("source", isDirectory: true)
        let destination = home.appendingPathComponent("destination", isDirectory: true)
        let external = home.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        try "legacy".write(
            to: source.appendingPathComponent("accounts/missing.json"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createSymbolicLink(
            atPath: destination.appendingPathComponent("accounts").path,
            withDestinationPath: external.path
        )

        let copied = try MoaDataRoot.copyMissingContents(from: source, to: destination, fileManager: fileManager)
        try expect(!copied, "a symlinked destination directory should not be treated as a merge target")
        try expect(
            !fileManager.fileExists(atPath: external.appendingPathComponent("missing.json").path),
            "recursive migration must not copy files through destination symlinks"
        )
    }

    private static func testProviderBridgeDefaultPort() throws {
        let profile = ConfigProfile(
            id: "bridge",
            name: "DeepSeek Bridge",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-test",
            providerKind: .deepseek,
            upstreamProtocol: .chatCompletions,
            bridgeMode: .localBridge
        )

        try expect(MoaProviderBridgeDefaults.defaultPort == 19360, "Moa provider bridge should use the Moa port")
        try expect(profile.resolvedBridgePort == 19360, "local bridge profiles should inherit the Moa port")
        try expect(profile.codexBaseURL == "http://127.0.0.1:19360/v1", "Codex base URL should use the Moa bridge port")
    }

    private static func testCodexBridgeProviderIDs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex").path
        ])
        let deepSeek = ConfigProfile(
            id: "deepseek",
            name: "DeepSeek Bridge",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-test",
            providerKind: .deepseek,
            upstreamProtocol: .chatCompletions,
            bridgeMode: .localBridge
        )
        let custom = ConfigProfile(
            id: "custom",
            name: "Kimi Chat",
            baseURL: "https://api.moonshot.ai/v1",
            apiKey: "sk-test",
            providerKind: .custom,
            upstreamProtocol: .chatCompletions,
            bridgeMode: .localBridge
        )

        try expect(ConfigProfileController.providerBridgeModeID == "moa-provider-bridge", "provider bridge mode ID should be Moa scoped")
        try expect(controller.providerID(for: deepSeek, in: "") == "moa-deepseek", "DeepSeek bridge provider ID should use Moa prefix")
        try expect(controller.providerID(for: custom, in: "") == "moa-kimi_chat", "custom bridge provider ID should use Moa prefix")
    }

    private static func testTomlMultilineStringsSurviveStructuralEdits() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex", isDirectory: true).path
        ])
        let multilineBlock = #"""
        instructions = """
        Keep this text exactly.


        [model_providers.moa-not-a-real-table]
        experimental_bearer_token = "keep-inside-basic-string"
        """
        literal_instructions = '''
        [features]
        remote_connections = false
        base_url = "keep-inside-literal-string"
        '''
        """#
        let featureMultilineBlock = #"""
        feature_note = """
        remote_connections = false


        remote_control = false
        """
        """#
        let config = #"""
        model_provider = "one"
        model = "gpt-test"

        """# + multilineBlock + #"""

        [features]
        remote_connections = true
        remote_control = true
        """# + featureMultilineBlock + #"""

        [model_providers.one]
        name = "One"
        base_url = "https://one.example/v1"
        experimental_bearer_token = "remove-real-token"
        wire_api = "responses"
        """#

        let profile = ConfigProfile(
            id: UUID().uuidString,
            name: "Replacement",
            baseURL: "https://replacement.example/v1",
            apiKey: "replacement-token"
        )
        let generated = controller.generateConfig(config, selecting: profile)
        try expect(generated.contains(multilineBlock), "profile generation must preserve multiline basic and literal strings byte-for-byte")
        try expect(generated.contains(featureMultilineBlock), "feature normalization must preserve multiline content and blank lines")
        try expect(!generated.contains("https://one.example/v1"), "profile generation should still replace the real provider table")

        let restored = MoaCodexConfigEditor.restoringOfficialMode(from: config)
        try expect(restored.contains(multilineBlock), "official restore must not interpret table-like multiline content as TOML structure")
        try expect(!restored.contains("remove-real-token"), "official restore should still remove the real selected provider credential")
        try expect(restored.contains("keep-inside-basic-string"), "official restore should preserve managed-looking keys inside basic multiline strings")
        try expect(restored.contains("keep-inside-literal-string"), "official restore should preserve managed-looking keys inside literal multiline strings")

        let remoteConnectionsRemoved = controller.setRemoteConnections(false, in: config)
        try expect(remoteConnectionsRemoved.contains(featureMultilineBlock), "disabling remote connections must preserve same-named keys inside feature multiline strings")
        try expect(!remoteConnectionsRemoved.contains("remote_connections = true"), "disabling remote connections should remove the real feature key")
    }

    private static func testFastStateTomlMultilineStrings() throws {
        let controller = FastStateController(environment: ["HOME": "/tmp/moa-fast-state-test"])
        let multilineBlock = #"""
        instructions = """
        [features]
        remote_connections = false
        remote_control = false
        """
        literal = '''
        [features]
        remote_connections = true
        '''
        """#
        let config = multilineBlock + #"""

        [features]
        remote_connections = true
        remote_control = true
        """#

        let disabled = controller.setRemoteConnections(false, in: config)
        try expect(disabled.contains(multilineBlock), "FastStateController must preserve table-like content inside multiline strings")
        try expect(controller.remoteConnectionsEnabled(in: disabled) == false, "FastStateController should remove the real remote feature keys")

        let enabled = controller.setRemoteConnections(true, in: disabled)
        try expect(enabled.contains(multilineBlock), "enabling remote connections must also preserve multiline strings")
        try expect(controller.remoteConnectionsEnabled(in: enabled), "FastStateController should restore both real remote feature keys")
    }

    private static func testOfficialRestoreKeepsSelectedProviderIdentity() throws {
        let config = """
        model = "deepseek-chat"
        model_provider = "moa-deepseek"

        [model_providers.moa-deepseek]
        name = "Moa DeepSeek"
        base_url = "http://127.0.0.1:19360/v1"
        experimental_bearer_token = "moa-token"
        wire_api = "responses"
        """

        let restored = MoaCodexConfigEditor.restoringOfficialMode(from: config)
        try expect(restored.contains(#"model_provider = "moa-deepseek""#), "official restore should preserve root provider selection")
        try expect(restored.contains("[model_providers.moa-deepseek]"), "selected provider table should stay available for session continuity")
        try expect(restored.contains(#"name = "Moa DeepSeek""#), "selected provider display name should be preserved")
        try expect(!restored.contains("http://127.0.0.1:19360/v1"), "selected provider base URL should be removed")
        try expect(!restored.contains("moa-token"), "selected provider token should be removed")
    }

    private static func testOfficialRestoreStripsSelectedDirectProviderCredentials() throws {
        let config = """
        model_reasoning_effort = "xhigh"
        disable_response_storage = true
        model_provider = "one"

        [model_providers.one]
        name = "one"
        base_url = "https://one.novnc.cc"
        experimental_bearer_token = "sk-test"
        wire_api = "responses"
        requires_openai_auth = true

        [model_providers.backup]
        name = "backup"
        base_url = "https://backup.example.com"
        experimental_bearer_token = "backup-token"
        wire_api = "responses"
        requires_openai_auth = true
        """

        let restored = MoaCodexConfigEditor.restoringOfficialMode(from: config)
        try expect(restored.contains(#"model_provider = "one""#), "official restore should keep the selected provider id")
        try expect(restored.contains("[model_providers.one]"), "official restore should keep the selected provider table")
        try expect(restored.contains(#"name = "one""#), "official restore should keep the selected provider name")
        try expect(restored.contains(#"wire_api = "responses""#), "official restore should keep non-secret provider metadata")
        try expect(restored.contains("requires_openai_auth = true"), "official restore should keep OpenAI auth mode metadata")
        try expect(!restored.contains("https://one.novnc.cc"), "official restore should remove the selected provider base URL")
        try expect(!restored.contains("sk-test"), "official restore should remove the selected provider token")
        try expect(restored.contains("https://backup.example.com"), "official restore should leave unselected custom providers alone")
        try expect(restored.contains("backup-token"), "official restore should not alter unselected custom provider tokens")
    }

    private static func testCodexSessionProviderMigrationRequiresCurrentProvider() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        model = "gpt-test"

        [model_providers.one]
        name = "one"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])

        do {
            _ = try controller.currentCodexRootModelProvider()
            throw TestError.failure("missing root model_provider should fail")
        } catch CodexSessionProviderMigrationError.missingModelProvider {
            return
        }
    }

    private static func testCodexSessionProviderMigrationUpdatesJSONLAndSQLite() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fileManager = FileManager.default
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions/2026/06/29", isDirectory: true)
        let archivedSessions = codexHome.appendingPathComponent("archived_sessions/2026/06/28", isDirectory: true)
        let nestedSQLite = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archivedSessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedSQLite, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let activeJSONL = sessions.appendingPathComponent("rollout-active.jsonl")
        try """
        {"timestamp":"2026-06-29T00:00:00Z","payload":{"model_provider":"codex_local_access","id":"active"}}
        {"type":"message","payload":{"text":"keep codex_local_access in body text"}}
        """.write(to: activeJSONL, atomically: true, encoding: .utf8)

        let archivedJSONL = archivedSessions.appendingPathComponent("rollout-archived.jsonl")
        try """
        {"timestamp":"2026-06-28T00:00:00Z","payload":{"model_provider":"openai","id":"archived"}}
        """.write(to: archivedJSONL, atomically: true, encoding: .utf8)

        let unchangedJSONL = sessions.appendingPathComponent("rollout-current.jsonl")
        try """
        {"timestamp":"2026-06-29T01:00:00Z","payload":{"model_provider":"one","id":"current"}}
        """.write(to: unchangedJSONL, atomically: true, encoding: .utf8)

        let missingPayloadJSONL = sessions.appendingPathComponent("rollout-missing-payload.jsonl")
        let missingPayloadText = """
        {"timestamp":"2026-06-29T02:00:00Z","id":"missing-payload"}
        """
        try missingPayloadText.write(to: missingPayloadJSONL, atomically: true, encoding: .utf8)

        let missingProviderJSONL = sessions.appendingPathComponent("rollout-missing-provider.jsonl")
        let missingProviderText = """
        {"timestamp":"2026-06-29T03:00:00Z","payload":{"id":"missing-provider"}}
        """
        try missingProviderText.write(to: missingProviderJSONL, atomically: true, encoding: .utf8)

        let mainDB = codexHome.appendingPathComponent("state_5.sqlite")
        let nestedDB = nestedSQLite.appendingPathComponent("state_5.sqlite")
        try createSessionProviderTestDatabase(at: mainDB, providers: ["codex_local_access", "openai", "one"])
        try createSessionProviderTestDatabase(at: nestedDB, providers: ["openai", "one"])

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        let result = try controller.migrateCodexSessionModelProviderToCurrentConfig()

        try expect(result.providerID == "one", "migration should use current root model_provider")
        try expect(result.jsonlFilesUpdated == 2, "migration should update only JSONL files with non-current providers")
        try expect(result.sqliteRowsUpdated == 3, "migration should update non-current SQLite rows in both indexes")
        try expect(fileManager.fileExists(atPath: result.backupURL.path), "migration should create a rollback backup")
        let activeProvider = try firstJSONLPayloadProvider(in: activeJSONL)
        let archivedProvider = try firstJSONLPayloadProvider(in: archivedJSONL)
        let unchangedProvider = try firstJSONLPayloadProvider(in: unchangedJSONL)
        try expect(activeProvider == "one", "active JSONL payload provider should be updated")
        try expect(archivedProvider == "one", "archived JSONL payload provider should be updated")
        try expect(unchangedProvider == "one", "current JSONL provider should remain one")
        let activeText = try String(contentsOf: activeJSONL, encoding: .utf8)
        try expect(activeText.contains("keep codex_local_access in body text"), "migration should not rewrite JSONL body text")
        let missingPayloadAfterMigration = try String(contentsOf: missingPayloadJSONL, encoding: .utf8)
        let missingProviderAfterMigration = try String(contentsOf: missingProviderJSONL, encoding: .utf8)
        try expect(missingPayloadAfterMigration == missingPayloadText, "migration should not add payloads to non-session metadata")
        try expect(missingProviderAfterMigration == missingProviderText, "migration should not add missing model_provider fields")
        let mainCounts = try sqliteProviderCounts(in: mainDB)
        let nestedCounts = try sqliteProviderCounts(in: nestedDB)
        try expect(mainCounts == ["one": 3], "main SQLite index should only contain one")
        try expect(nestedCounts == ["one": 2], "nested SQLite index should only contain one")
    }

    private static func testCodexSessionProviderMigrationRollsBackOnFailure() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fileManager = FileManager.default
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions/2026/06/29", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let activeJSONL = sessions.appendingPathComponent("rollout-active.jsonl")
        try """
        {"timestamp":"2026-06-29T00:00:00Z","payload":{"model_provider":"openai","id":"active"}}
        """.write(to: activeJSONL, atomically: true, encoding: .utf8)

        let malformedDB = codexHome.appendingPathComponent("state_5.sqlite")
        try "not a sqlite database".write(to: malformedDB, atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])

        do {
            _ = try controller.migrateCodexSessionModelProviderToCurrentConfig()
            throw TestError.failure("migration should fail when SQLite index is unreadable")
        } catch let error as CodexSessionProviderMigrationError {
            switch error {
            case .migrationFailedAndRestored(_, _):
                break
            default:
                throw TestError.failure("expected restored migration failure, got \(error.localizedDescription)")
            }
        }

        let restoredProvider = try firstJSONLPayloadProvider(in: activeJSONL)
        let restoredDB = try String(contentsOf: malformedDB, encoding: .utf8)
        try expect(restoredProvider == "openai", "failed migration should restore JSONL changes")
        try expect(restoredDB == "not a sqlite database", "failed migration should restore SQLite files")
    }

    private static func testOfficialAccountDisplaysEmailFromAuthToken() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let email = "user@example.com"
        let idToken = try testJWT(email: email)
        try """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(idToken)",
            "refresh_token": "refresh-token"
          },
          "last_refresh": "2026-06-26T00:00:00Z"
        }
        """.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        let accounts = try controller.officialAccounts()
        try expect(accounts.count == 1, "bootstrap should save the current Codex official login")
        guard let account = accounts.first else {
            throw TestError.failure("saved account should be available")
        }

        try expect(account.email == email, "saved official account should record the email from id_token")
        try expect(account.displayTitle == email, "default saved account should display the email")
        try expect(controller.selectedOfficialAccountName() == email, "selected official account should expose the email display title")

        let renamed = try controller.renameSelectedOfficialAccount(name: "Plus")
        try expect(renamed.displayTitle == "Plus(\(email))", "renamed official account should display name plus email")
        try expect(controller.selectedOfficialAccountName() == "Plus(\(email))", "selected renamed official account should expose name plus email")
    }

    private static func testOfficialAccountAuthPathValidation() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "CODEX_HOME": codexHome.path]
        let controller = ConfigProfileController(environment: environment)

        let safe = controller.makeOfficialAccount(name: "Safe")
        let safeURL = try controller.officialAuthURL(for: safe)
        try expect(safeURL.deletingLastPathComponent().lastPathComponent == "accounts", "generated auth paths should resolve inside the accounts directory")
        try expect(safeURL.lastPathComponent == "\(safe.id).json", "generated auth filename should match the account UUID")

        for invalidPath in ["../outside.json", "/tmp/outside.json", "codex-auth/accounts/other.json"] {
            var invalid = safe
            invalid.authPath = invalidPath
            do {
                _ = try controller.officialAuthURL(for: invalid)
                throw TestError.failure("invalid official auth path should be rejected: \(invalidPath)")
            } catch CodexOfficialAccountError.invalidAuthPath {
                continue
            }
        }

        let externalAccounts = home.appendingPathComponent("external-accounts", isDirectory: true)
        try fileManager.createDirectory(at: externalAccounts, withIntermediateDirectories: true)
        try fileManager.removeItem(at: controller.officialAuthAccountsDir)
        try fileManager.createSymbolicLink(
            atPath: controller.officialAuthAccountsDir.path,
            withDestinationPath: externalAccounts.path
        )
        do {
            _ = try controller.officialAuthURL(for: safe)
            throw TestError.failure("a symlinked official account directory should be rejected")
        } catch CodexOfficialAccountError.invalidAuthPath {
            try fileManager.removeItem(at: controller.officialAuthAccountsDir)
            try fileManager.createDirectory(at: controller.officialAuthAccountsDir, withIntermediateDirectories: true)
        }

        var persistedInvalid = safe
        persistedInvalid.authPath = "codex-auth/accounts/../outside.json"
        let database = CodexOfficialAccountDatabase(selectedAccountID: safe.id, accounts: [persistedInvalid])
        let data = try JSONEncoder().encode(database)
        try data.write(to: controller.officialAccountsDatabaseURL, options: .atomic)
        let reloaded = ConfigProfileController(environment: environment)
        do {
            _ = try reloaded.selectedOfficialAccountID()
            throw TestError.failure("persisted invalid official auth path should fail database loading")
        } catch CodexOfficialAccountError.invalidAuthPath {
            return
        }
    }

    private static func testOfficialNoAccountPreservesThirdPartyConfigWithoutLogin() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        let account = try controller.applyOfficialNoAccountMode()
        let config = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        let auth = try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8)
        let selectedProfileID = try controller.selectedProfileID()
        let selectedAccountID = try controller.selectedOfficialAccountID()

        try expect(account == nil, "no-account mode should not create an account when Codex is not logged in")
        try expect(selectedProfileID != nil, "no-account mode should preserve selected direct profile state")
        try expect(selectedAccountID == nil, "no-account mode should select the no-account option")
        try expect(config.contains(#"base_url = "https://one.novnc.cc""#), "no-account mode should preserve config.toml base_url")
        try expect(config.contains(#"experimental_bearer_token = "sk-test""#), "no-account mode should preserve config.toml token")
        try expect(auth == noAccountAuthJSONText, "no-account mode should write Codex auth in API key mode")
    }

    private static func testOfficialNoAccountCapturesCurrentLoginWithoutSelectingIt() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let email = "user@example.com"
        let idToken = try testJWT(email: email)
        try """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(idToken)",
            "refresh_token": "refresh-token"
          },
          "last_refresh": "2026-06-26T00:00:00Z"
        }
        """.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        let account = try controller.applyOfficialNoAccountMode()
        let config = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        let auth = try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8)
        let selectedProfileID = try controller.selectedProfileID()
        let selectedAccountID = try controller.selectedOfficialAccountID()
        let accountTitles = try controller.officialAccounts().map(\.displayTitle)

        try expect(account == nil, "logged-in no-account click should not keep using the current login")
        try expect(selectedProfileID != nil, "logged-in no-account click should preserve selected direct profile state")
        try expect(selectedAccountID == nil, "logged-in no-account click should select the no-account option")
        try expect(accountTitles.contains(email), "saved account should appear below the no-account option")
        try expect(config.contains(#"base_url = "https://one.novnc.cc""#), "logged-in no-account mode should preserve config.toml base_url")
        try expect(config.contains(#"experimental_bearer_token = "sk-test""#), "logged-in no-account mode should preserve config.toml token")
        try expect(auth == noAccountAuthJSONText, "logged-in no-account mode should write Codex auth in API key mode")
    }

    private static func testOfficialNoAccountSelectsFirstDirectConfigWhenNoneSelected() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        let profile = try controller.addProfile(
            name: "First API",
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-first"
        )
        let selectedProfileIDBeforeNoAccount = try controller.selectedProfileID()
        try expect(selectedProfileIDBeforeNoAccount == nil, "newly added direct profile should not be selected by setup")

        _ = try controller.applyOfficialNoAccountMode()
        let config = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        let auth = try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8)
        let selectedProfileID = try controller.selectedProfileID()
        let selectedAccountID = try controller.selectedOfficialAccountID()

        try expect(selectedProfileID == profile.id, "no-account mode should select the first direct Codex config when none is selected")
        try expect(selectedAccountID == nil, "no-account fallback should not select an official account")
        try expect(config.contains(#"base_url = "https://api.example.com/v1""#), "first direct config should be written to config.toml")
        try expect(config.contains(#"experimental_bearer_token = "sk-first""#), "first direct config token should be written to config.toml")
        try expect(auth == noAccountAuthJSONText, "no-account fallback should write Codex auth in API key mode")
    }

    private static func testOfficialNoAccountDeduplicatesCurrentLoginByEmail() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let email = "user@example.com"
        try authJSON(email: email, refreshToken: "refresh-token-old")
            .write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        _ = try controller.renameSelectedOfficialAccount(name: "Plus_TR")

        try authJSON(email: email, refreshToken: "refresh-token-new")
            .write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        _ = try controller.applyOfficialNoAccountMode()
        let accounts = try controller.officialAccounts()
        let selectedAccountID = try controller.selectedOfficialAccountID()

        try expect(accounts.count == 1, "no-account mode should update the existing email-matched account instead of creating a duplicate")
        try expect(accounts.first?.displayTitle == "Plus_TR(\(email))", "existing renamed account should keep its name and email")
        try expect(selectedAccountID == nil, "no-account option should remain selected after deduplication")
    }

    private static func testOfficialAccountListSyncsSelectedAccountEmail() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try thirdPartyConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token"
          },
          "last_refresh": "2026-06-26T00:00:00Z"
        }
        """.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path
        ])
        _ = try controller.renameSelectedOfficialAccount(name: "K12")

        let email = "k12@example.com"
        try authJSON(email: email, refreshToken: "refresh-token-new")
            .write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let accounts = try controller.officialAccounts()

        try expect(accounts.count == 1, "selected account sync should not create another account")
        try expect(accounts.first?.displayTitle == "K12(\(email))", "selected account should show email after Codex relogin")
    }

    private static func testJWT(email: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email], options: [])
        let payloadText = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payloadText).signature"
    }

    private static func authJSON(email: String, refreshToken: String) throws -> String {
        let idToken = try testJWT(email: email)
        return """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(idToken)",
            "refresh_token": "\(refreshToken)"
          },
          "last_refresh": "2026-06-26T00:00:00Z"
        }
        """
    }

    private static func firstJSONLPayloadProvider(in fileURL: URL) throws -> String? {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let firstLine = text.components(separatedBy: "\n").first,
              let data = firstLine.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }
        return payload["model_provider"] as? String
    }

    private static func createSessionProviderTestDatabase(at url: URL, providers: [String]) throws {
        let values = providers.enumerated().map { index, provider in
            "('thread-\(index)', '\(provider)', 0)"
        }.joined(separator: ",")
        _ = try runSQLite(
            url,
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                model_provider TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads (id, model_provider, archived) VALUES \(values);
            """
        )
    }

    private static func sqliteProviderCounts(in url: URL) throws -> [String: Int] {
        let output = try runSQLite(url, "SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider ORDER BY model_provider;")
        var counts: [String: Int] = [:]
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            counts[parts[0]] = count
        }
        return counts
    }

    private static func runSQLite(_ url: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TestError.failure("sqlite3 failed: \(errorOutput)")
        }
        return output
    }

    private static let thirdPartyConfig = """
    model_provider = "one"
    model = "gpt-5.5"

    [model_providers.one]
    name = "one"
    base_url = "https://one.novnc.cc"
    experimental_bearer_token = "sk-test"
    wire_api = "responses"
    requires_openai_auth = true
    """

    private static let noAccountAuthJSONText = """
    {
      "auth_mode": "apikey",
      "OPENAI_API_KEY": "null"
    }
    """ + "\n"

    private static func testLiteLLMPresetName() throws {
        let preset = MoaProviderPresets.responsesGateways.first { $0.id == "litellm-responses-gateway" }
        try expect(preset?.model == "moa-codex", "LiteLLM sample model should be Moa scoped")
        try expect(preset?.models == ["moa-codex"], "LiteLLM sample models should be Moa scoped")
    }

    private static func testGPT56Pricing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        MoaUsagePricing.useRemoteCatalogStoreForTesting(
            MoaUsagePricingCatalogStore(environment: ["HOME": home.path])
        )
        defer { MoaUsagePricing.resetRemoteCatalogStoreForTesting() }

        let standardCases: [(model: String, expected: Double)] = [
            ("gpt-5.6", 3.775),
            ("gpt-5.6-sol", 3.775),
            ("openai/gpt-5.6-terra", 1.8875),
            ("gpt-5.6-luna-2026-07-09", 0.755)
        ]
        for item in standardCases {
            let estimate = MoaUsagePricing.codexCostEstimate(
                model: item.model,
                inputTokens: 200_000,
                cachedInputTokens: 50_000,
                outputTokens: 100_000
            )
            try expect(estimate?.usesFallbackPricing == false, "\(item.model) should use its own GPT-5.6 price")
            try expectClose(estimate?.costUSD ?? -1, item.expected, "\(item.model) should use current standard pricing")
        }

        let longContextCases: [(model: String, expected: Double)] = [
            ("gpt-5.6-sol", 6.6),
            ("gpt-5.6-terra", 3.3),
            ("gpt-5.6-luna", 1.32)
        ]
        for item in longContextCases {
            let cost = MoaUsagePricing.codexCostUSD(
                model: item.model,
                inputTokens: 300_000,
                cachedInputTokens: 100_000,
                outputTokens: 100_000
            )
            try expectClose(cost ?? -1, item.expected, "\(item.model) should use current long-context pricing")
        }

        let priorityCases: [(model: String, expected: Double)] = [
            ("gpt-5.6", 7.55),
            ("gpt-5.6-sol", 7.55),
            ("gpt-5.6-terra", 3.775),
            ("gpt-5.6-luna", 1.51)
        ]
        for item in priorityCases {
            let cost = MoaUsagePricing.codexPriorityCostUSD(
                model: item.model,
                inputTokens: 200_000,
                cachedInputTokens: 50_000,
                outputTokens: 100_000
            )
            try expectClose(cost ?? -1, item.expected, "\(item.model) should use current priority pricing")
        }
    }

    private static func testCodexUsageIgnoresInheritedHistory() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions/2026/07/11", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-subagent.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-11T13:00:00Z","type":"session_meta","payload":{"id":"child","source":{"subagent":{}}}}"#,
            #"{"timestamp":"2026-07-11T13:00:00.001Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":900000,"output_tokens":10000}}}}"#,
            #"{"timestamp":"2026-07-11T13:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-11T13:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100}}}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let report = try CodexUsageScanner(environment: ["HOME": home.path])
            .loadReport(forceRefresh: true, now: Date(), persistCache: false)
        try expect(report.rows.count == 1, "only model-attributed usage should be reported")
        guard let row = report.rows.first else {
            throw TestError.failure("expected Codex usage row")
        }
        try expect(row.model == "gpt-5.6-sol", "usage should retain the verified turn model")
        try expect(row.input == 200, "non-cached input should exclude inherited history")
        try expect(row.cachedInput == 800, "cached input should exclude inherited history")
        try expect(row.output == 100, "output should exclude inherited history")
        try expect(!report.rows.contains { $0.model == "gpt-5" }, "unknown history must not be mislabeled as GPT-5")
    }

    private static func testRemotePricingCatalog() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let sourceURL = URL(string: "https://models.dev/api.json")!
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(remotePricingFixture.utf8)
        var snapshot = try MoaUsagePricingRemoteParser.parse(
            data: data,
            sourceURL: sourceURL,
            fetchedAt: fetchedAt
        )
        let parsed = snapshot.models[MoaUsageSource.codex.rawValue]?["gpt-5.7"]
        try expect(parsed?.thresholdTokens == 272_000, "remote context tier should preserve its threshold")
        try expectClose(parsed?.inputUSDPerMillionAboveThreshold ?? -1, 4, "remote context tier should preserve input pricing")

        let store = MoaUsagePricingCatalogStore(environment: ["HOME": home.path])
        let firstUpdate = try store.merge(snapshot)
        guard case .updated(let firstAdded, let firstChanged) = firstUpdate else {
            throw TestError.failure("first remote catalog should create a local snapshot")
        }
        try expect(firstAdded == 9, "first remote catalog should add every valid fixture model")
        try expect(firstChanged == 0, "first remote catalog should not report changed models")
        let identicalUpdate = try store.merge(snapshot)
        try expect(identicalUpdate == .unchanged, "identical remote catalogs should not rewrite the local snapshot")

        MoaUsagePricing.useRemoteCatalogStoreForTesting(store)
        defer { MoaUsagePricing.resetRemoteCatalogStoreForTesting() }
        let estimate = MoaUsagePricing.codexCostEstimate(
            model: "openai/gpt-5.7",
            inputTokens: 200_000,
            cachedInputTokens: 50_000,
            outputTokens: 100_000
        )
        try expect(estimate?.usesFallbackPricing == false, "remote-only models should not use fallback pricing")
        try expectClose(estimate?.costUSD ?? -1, 1.31, "remote-only models should use downloaded pricing")

        snapshot.models[MoaUsageSource.codex.rawValue]?["gpt-5.7"]?.inputUSDPerMillion = 3
        snapshot.models[MoaUsageSource.codex.rawValue]?["gpt-5.8"] = parsed
        let secondUpdate = try store.merge(snapshot)
        try expect(secondUpdate == .updated(added: 1, changed: 1), "catalog merge should distinguish additions from field changes")

        var sparse = snapshot
        sparse.models[MoaUsageSource.codex.rawValue]?["gpt-5.7"]?.cacheReadUSDPerMillion = nil
        let sparseUpdate = try store.merge(sparse)
        try expect(sparseUpdate == .unchanged, "missing remote fields should not erase the local incremental catalog")
        try expectClose(
            store.pricing(source: .codex, model: "gpt-5.7")?.cacheReadUSDPerMillion ?? -1,
            0.2,
            "existing optional prices should survive sparse remote responses"
        )

        var partial = snapshot
        partial.models[MoaUsageSource.codex.rawValue]?.removeValue(forKey: "gpt-5.7")
        _ = try store.merge(partial)
        try expect(store.pricing(source: .codex, model: "gpt-5.7") != nil, "incremental refresh should retain models omitted by a later response")

        try store.recordSuccessfulCheck(at: fetchedAt)
        try expect(store.lastSuccessfulCheck() == fetchedAt, "successful checks should be recorded separately from catalog changes")
    }

    private static func testPricingUpdateSchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 0, minute: 20, second: 0))!
        let scheduled = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 0, minute: 20, second: 1))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 8))!

        try expect(
            MoaUsagePricingUpdateCoordinator.nextScheduledDate(after: before, calendar: calendar) == scheduled,
            "next pricing check should be scheduled at 00:20:01 local time"
        )
        try expect(
            !MoaUsagePricingUpdateCoordinator.shouldCheck(now: before, lastSuccessfulCheck: nil, calendar: calendar),
            "launches before the daily check time should wait for the timer"
        )
        try expect(
            MoaUsagePricingUpdateCoordinator.shouldCheck(now: after, lastSuccessfulCheck: nil, calendar: calendar),
            "launches after the daily check time should catch up"
        )
        try expect(
            !MoaUsagePricingUpdateCoordinator.shouldCheck(now: after, lastSuccessfulCheck: scheduled, calendar: calendar),
            "a successful check on the same local day should not repeat"
        )
    }

    private static let remotePricingFixture = #"""
    {
      "openai": {
        "models": {
          "gpt-5.3": {"cost":{"input":1,"output":5,"cache_read":0.1}},
          "gpt-5.4": {"cost":{"input":1,"output":5,"cache_read":0.1}},
          "gpt-5.5": {"cost":{"input":1,"output":5,"cache_read":0.1}},
          "gpt-5.6": {"cost":{"input":1,"output":5,"cache_read":0.1}},
          "gpt-5.7": {"cost":{"input":2,"output":10,"cache_read":0.2,"cache_write":2.5,"tiers":[{"input":4,"output":15,"cache_read":0.4,"cache_write":5,"tier":{"type":"context","size":272000}}]}}
        }
      },
      "anthropic": {
        "models": {
          "claude-haiku": {"cost":{"input":1,"output":5,"cache_read":0.1,"cache_write":1.25}},
          "claude-sonnet": {"cost":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75}},
          "claude-opus": {"cost":{"input":5,"output":25,"cache_read":0.5,"cache_write":6.25}}
        }
      },
      "zai": {
        "models": {
          "glm-5.2": {"cost":{"input":1.4,"output":4.4,"cache_read":0.26,"cache_write":0}}
        }
      }
    }
    """#

    private static func testZCodePricing() throws {
        let estimate = MoaUsagePricing.zcodeCostEstimate(
            model: "zhipu/glm-5-turbo",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 1_000_000,
            cacheCreationInputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        try expect(estimate?.normalizedModel == "GLM-5-Turbo", "ZCode model names should normalize GLM-5-Turbo")
        try expect(estimate?.pricingModel == "GLM-5-Turbo", "known ZCode models should use their own pricing model")
        try expect(estimate?.usesFallbackPricing == false, "known ZCode models should not use fallback pricing")
        try expectClose(estimate?.costUSD ?? -1, 5.44, "GLM-5-Turbo cost should use input, cached input, free cache storage, and output prices")

        let fallback = MoaUsagePricing.zcodeCostEstimate(
            model: "glm-future",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0
        )
        try expect(fallback?.pricingModel == "GLM-5.2", "unknown ZCode models should fall back to GLM-5.2 pricing")
        try expect(fallback?.usesFallbackPricing == true, "unknown ZCode models should be marked as fallback pricing")
    }

    private static func testZCodeUsageScanner() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let dbDirectory = home
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let db = dbDirectory.appendingPathComponent("db.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = Int(now.timeIntervalSince1970 * 1000)
        try runSQLite(db: db, sql: """
        create table model_usage (
          status text,
          started_at integer,
          model_id text,
          input_tokens integer,
          output_tokens integer,
          cache_read_input_tokens integer,
          cache_creation_input_tokens integer
        );
        insert into model_usage values ('completed', \(startedAt), 'glm-5.2', 1000, 50, 200, 100);
        insert into model_usage values ('error', \(startedAt), 'glm-5.2', 9999, 9999, 9999, 9999);
        """)

        let scanner = ZCodeUsageScanner(environment: [
            "HOME": home.path,
            "ZCODE_USAGE_DB": db.path,
            "SQLITE3_PATH": "/usr/bin/sqlite3"
        ])
        let report = try scanner.loadReport(now: now, persistCache: false)
        try expect(report.rows.count == 1, "ZCode scanner should aggregate only completed rows")
        guard let row = report.rows.first else {
            throw TestError.failure("ZCode scanner should return one aggregate row")
        }

        try expect(row.source == .zcode, "ZCode scanner rows should be marked as ZCode")
        try expect(row.dayKey == MoaUsageReport.dayKey(from: now), "ZCode scanner should bucket rows by local day")
        try expect(row.model == "GLM-5.2", "ZCode scanner should normalize GLM model IDs")
        try expect(row.input == 700, "ZCode scanner should subtract cache read and storage tokens from raw input")
        try expect(row.cacheReadInput == 200, "ZCode scanner should preserve cache read tokens")
        try expect(row.cacheCreationInput == 100, "ZCode scanner should preserve cache creation/storage tokens")
        try expect(row.output == 50, "ZCode scanner should preserve output tokens")
        try expect(row.totalTokens == 1050, "ZCode scanner total tokens should include raw prompt tokens plus output")
        try expect(row.cacheHitTokens == 200, "ZCode scanner cache hit tokens should include cache read tokens")
        try expectClose(row.costUSD, 0.001252, "ZCode scanner should estimate GLM-5.2 row cost")

        let summary = try scanner.loadSummary(now: now)
        try expect(summary.todayTokens == 1050, "ZCode summary should include today's tokens")
        try expect(summary.totalTokens == 1050, "ZCode summary should include total tokens")
        try expectClose(summary.cacheHitPercent, 19.047619, "ZCode summary should calculate cache hit percentage", tolerance: 0.00001)
    }

    private static func testProviderBridgePortValidation() throws {
        let defaultPort = try MoaProviderBridgePort.validated(MoaProviderBridgeDefaults.defaultPort)
        let automaticPort = try MoaProviderBridgePort.validated(0)
        let highestPort = try MoaProviderBridgePort.validated(65535)
        try expect(defaultPort == 19360, "default provider bridge port should be valid")
        try expect(automaticPort == 0, "port zero should remain available for automatic assignment")
        try expect(highestPort == 65535, "highest TCP port should be valid")

        for invalid in [-1, 65536, Int.max] {
            do {
                _ = try MoaProviderBridgePort.validated(invalid)
                throw TestError.failure("invalid provider bridge port should be rejected: \(invalid)")
            } catch MoaProviderBridgePortError.outOfRange {
                continue
            }
        }

        for invalid in [-1, 65536, Int.max] {
            let json = """
            {"id":"test","name":"Bridge","baseURL":"https://example.com","bridgePort":\(invalid)}
            """
            do {
                _ = try JSONDecoder().decode(ConfigProfile.self, from: Data(json.utf8))
                throw TestError.failure("persisted invalid bridge port should fail decoding: \(invalid)")
            } catch DecodingError.dataCorrupted {
                continue
            }
        }

        let invalidProfile = ConfigProfile(
            id: UUID().uuidString,
            name: "Invalid Bridge",
            baseURL: "https://example.com",
            apiKey: "key",
            providerKind: .custom,
            upstreamProtocol: .chatCompletions,
            bridgeMode: .localBridge,
            model: "model",
            bridgeToken: "token",
            bridgePort: Int.max
        )
        let server = MoaProviderBridgeServer()
        do {
            _ = try server.start(configuration: MoaProviderBridgeServerConfiguration(profile: invalidProfile))
            throw TestError.failure("server should reject Int.max before probing or converting the port")
        } catch MoaProviderBridgeServerError.invalidPort(let port) {
            try expect(port == Int.max, "server should report the rejected port")
        }
    }

    private static func testProviderBridgeStreamingUsageOrder() throws {
        let converter = MoaChatSSEToResponsesSSEConverter(model: "test-model")
        let finishFrames = try converter.ingest(jsonPayload: #"{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"#)
        try expect(
            !finishFrames.joined().contains("response.completed"),
            "finish_reason must not complete the response before the trailing usage chunk"
        )

        let usageFrames = try converter.ingest(jsonPayload: #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#)
        try expect(usageFrames.joined().contains("response.usage.delta"), "the trailing usage chunk should emit usage before completion")

        let completedFrames = try converter.finish()
        try expect(completedFrames.joined().contains("response.completed"), "the stream terminator should complete the response")
        let combined = (finishFrames + usageFrames + completedFrames).joined()
        guard let usageRange = combined.range(of: "response.usage.delta"),
              let completedRange = combined.range(of: "response.completed")
        else {
            throw TestError.failure("streaming output should contain both usage and completion events")
        }
        try expect(usageRange.lowerBound < completedRange.lowerBound, "usage must be emitted before response.completed")
    }

    private static func testClaudeStateTransactionRollback() throws {
        let home = try temporaryHome()
        defer {
            ClaudeDesktopProfileController.testingDatabaseSaveFailuresRemaining = 0
            try? FileManager.default.removeItem(at: home)
        }
        let environment = ["HOME": home.path]
        let controller = ClaudeDesktopProfileController(environment: environment)
        let profile = try controller.addProfile(
            name: "Claude Test",
            baseURL: "https://claude.example.com",
            apiKey: "test-key",
            models: ["claude-sonnet-4"],
            oneMModels: []
        )
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let stateURLs = [
            appSupport.appendingPathComponent("Claude/claude_desktop_config.json"),
            appSupport.appendingPathComponent("Claude-3p/claude_desktop_config.json"),
            appSupport.appendingPathComponent("Claude-3p/configLibrary/00000000-0000-4000-8000-000000157211.json"),
            appSupport.appendingPathComponent("Claude-3p/configLibrary/_meta.json"),
            home.appendingPathComponent(".moa/claude_desktop_profiles.json")
        ]

        let beforeFailedApply = try stateURLs.map(optionalData)
        ClaudeDesktopProfileController.testingDatabaseSaveFailuresRemaining = 1
        var applyFailed = false
        do {
            _ = try controller.applyProfile(id: profile.id)
        } catch {
            applyFailed = true
        }
        try expect(applyFailed, "injected Claude apply database failure should propagate")
        let afterFailedApply = try stateURLs.map(optionalData)
        let selectedAfterFailedApply = try controller.selectedProfileID()
        try expect(afterFailedApply == beforeFailedApply, "failed apply should restore live Claude files and profile database")
        try expect(selectedAfterFailedApply == nil, "failed apply should restore the cached selected profile state")

        _ = try controller.applyProfile(id: profile.id)
        let appliedState = try stateURLs.map(optionalData)
        ClaudeDesktopProfileController.testingDatabaseSaveFailuresRemaining = 1
        var restoreFailed = false
        do {
            try controller.restoreOfficial()
        } catch {
            restoreFailed = true
        }
        try expect(restoreFailed, "injected Claude restore database failure should propagate")
        let afterFailedRestore = try stateURLs.map(optionalData)
        let selectedAfterFailedRestore = try controller.selectedProfileID()
        try expect(afterFailedRestore == appliedState, "failed restore should restore the applied live files and database")
        try expect(selectedAfterFailedRestore == profile.id, "failed restore should keep the selected profile")

        ClaudeDesktopProfileController.testingDatabaseSaveFailuresRemaining = 1
        var deleteFailed = false
        do {
            _ = try controller.deleteProfile(id: profile.id)
        } catch {
            deleteFailed = true
        }
        try expect(deleteFailed, "injected Claude delete database failure should propagate")
        let afterFailedDelete = try stateURLs.map(optionalData)
        let profilesAfterFailedDelete = try controller.profiles()
        try expect(afterFailedDelete == appliedState, "failed selected-profile deletion should restore live files and database")
        try expect(profilesAfterFailedDelete.contains(where: { $0.id == profile.id }), "failed deletion should restore the cached profile list")
    }

    private static func testCodexStateTransactionRollback() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        defer { ConfigProfileController.testingProfileDatabaseSaveFailuresRemaining = 0 }
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "CODEX_APP": home.appendingPathComponent("MissingCodex.app").path
        ])
        let profile = try controller.addProfile(
            name: "Rollback",
            baseURL: "https://rollback.example/v1",
            apiKey: "rollback-key"
        )
        let stateURLs = [
            controller.moaConfigURL,
            controller.codexConfigURL,
            controller.moaAuthURL,
            controller.codexAuthURL,
            controller.databaseURL,
            controller.officialAccountsDatabaseURL
        ]
        let before = try stateURLs.map(optionalData)

        ConfigProfileController.testingProfileDatabaseSaveFailuresRemaining = 1
        do {
            _ = try controller.applyProfile(id: profile.id)
            throw TestError.failure("injected Codex profile database failure should propagate")
        } catch let error as TestError {
            throw error
        } catch {
            // Expected injected failure.
        }

        let after = try stateURLs.map(optionalData)
        try expect(after == before, "failed Codex profile activation should restore config, auth, and database files")
        let selectedProfileID = try controller.selectedProfileID()
        try expect(selectedProfileID == nil, "failed activation should restore the cached selected profile")
    }

    private static func testCodexOfficialAccountTransactionRollback() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        defer { ConfigProfileController.testingOfficialAccountDatabaseSaveFailuresRemaining = 0 }
        let controller = ConfigProfileController(environment: [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex", isDirectory: true).path
        ])
        let stateURLs = [controller.moaAuthURL, controller.codexAuthURL, controller.officialAccountsDatabaseURL]
        let before = try stateURLs.map(optionalData)
        let accountsBefore = try Set(FileManager.default.contentsOfDirectory(atPath: controller.officialAuthAccountsDir.path))

        ConfigProfileController.testingOfficialAccountDatabaseSaveFailuresRemaining = 1
        do {
            _ = try controller.saveNewOfficialAccount(
                auth: ["tokens": ["access_token": "rollback-token"]],
                name: "Rollback Account"
            )
            throw TestError.failure("injected official account database failure should propagate")
        } catch let error as TestError {
            throw error
        } catch {
            // Expected injected failure.
        }

        let after = try stateURLs.map(optionalData)
        let accountsAfter = try Set(FileManager.default.contentsOfDirectory(atPath: controller.officialAuthAccountsDir.path))
        try expect(after == before, "failed official account save should restore auth and database files")
        try expect(accountsAfter == accountsBefore, "failed official account save should remove newly-created account files")
    }

    private static func testDataPackageRoundTripAndCleanup() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let moaHome = home.appendingPathComponent(".moa", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: moaHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try "snapshot-data".write(to: moaHome.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: moaHome.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "nested-data".write(to: moaHome.appendingPathComponent("nested/config.txt"), atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            atPath: moaHome.appendingPathComponent("profiles-current.json").path,
            withDestinationPath: "profiles.json"
        )

        let prefixes = ["MoaDataPackage-", "MoaDataImport-", "MoaImportPrevious-"]
        let beforeTemporaryEntries = try temporaryEntries(withPrefixes: prefixes)
        let controller = MoaDataPackageController(environment: ["HOME": home.path])
        let packageURL = home.appendingPathComponent("round-trip.zip")
        _ = try controller.exportDataPackage(to: packageURL)
        try expect(fileManager.fileExists(atPath: packageURL.path), "data package export should create a zip")

        let extract = home.appendingPathComponent("extract", isDirectory: true)
        try runProcess("/usr/bin/ditto", ["-x", "-k", packageURL.path, extract.path])
        let packageRoot = extract.appendingPathComponent("MoaDataPackage", isDirectory: true)
        let manifest = try JSONDecoder().decode(
            MoaDataPackageManifest.self,
            from: Data(contentsOf: packageRoot.appendingPathComponent("MoaDataPackageManifest.json"))
        )
        try expect(manifest.schemaVersion == 2, "new data packages should use the symlink-aware manifest schema")
        try expect(
            Set(manifest.files.map(\.path)) == ["profiles.json", "profiles-current.json", "nested/config.txt"],
            "manifest should describe files and symbolic links in the copied package snapshot"
        )
        try expect(manifest.files.allSatisfy { $0.sha256?.count == 64 }, "every exported file should have a SHA-256 hash")
        let linkEntry = manifest.files.first(where: { $0.path == "profiles-current.json" })
        try expect(linkEntry?.resolvedKind == .symbolicLink, "manifest should identify symbolic links")
        try expect(linkEntry?.symbolicLinkDestination == "profiles.json", "manifest should preserve the symbolic link destination")

        try "changed-after-export".write(to: moaHome.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        let rollbackURL = try controller.importDataPackage(from: packageURL)
        try expect(fileManager.fileExists(atPath: rollbackURL.path), "import should retain the user-facing rollback zip")
        let restored = try String(contentsOf: moaHome.appendingPathComponent("profiles.json"), encoding: .utf8)
        try expect(restored == "snapshot-data", "import should restore the exact exported snapshot")
        let restoredLink = try fileManager.destinationOfSymbolicLink(atPath: moaHome.appendingPathComponent("profiles-current.json").path)
        try expect(restoredLink == "profiles.json", "import should restore the validated symbolic link")
        let afterTemporaryEntries = try temporaryEntries(withPrefixes: prefixes)
        try expect(afterTemporaryEntries == beforeTemporaryEntries, "successful export/import should not leak staging or previous-data directories")
    }

    private static func testZCodeUsageScannerLargeOutput() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let db = home.appendingPathComponent("db.sqlite")
        try Data().write(to: db)
        let fakeSQLite = home.appendingPathComponent("fake-sqlite.sh")
        let script = """
        #!/bin/sh
        i=0
        while [ "$i" -lt 20000 ]; do
          printf '2023-11-14\\037glm-5.2\\0371000\\037200\\037100\\03750\\n'
          i=$((i + 1))
        done
        """
        try script.write(to: fakeSQLite, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSQLite.path)

        let scanner = ZCodeUsageScanner(environment: [
            "HOME": home.path,
            "ZCODE_USAGE_DB": db.path,
            "SQLITE3_PATH": fakeSQLite.path
        ])
        let report = try scanner.loadReport(now: Date(timeIntervalSince1970: 1_700_000_000), persistCache: false)
        try expect(report.rows.count == 1, "large sqlite output should be fully drained and aggregated")
        try expect(report.rows.first?.totalTokens == 21_000_000, "large sqlite output should not be truncated")
    }

    private static func optionalData(at url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    private static func temporaryEntries(withPrefixes prefixes: [String]) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        return Set(names.filter { name in prefixes.contains(where: name.hasPrefix) })
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? executable
            throw TestError.failure(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func testUpdaterVersionComparisonAndFeedParsing() throws {
        try expect(
            MoaUpdateController.isRemoteVersion("1.1.5", remoteBuild: nil, newerThan: "1.1.4", localBuild: 111),
            "newer patch version should be an update"
        )
        try expect(
            MoaUpdateController.isRemoteVersion("1.1.5", remoteBuild: 113, newerThan: "1.1.5", localBuild: 112),
            "newer build on the same version should be an update"
        )
        try expect(
            !MoaUpdateController.isRemoteVersion("1.1.4", remoteBuild: 111, newerThan: "1.1.5", localBuild: 112),
            "older remote version should not be an update"
        )

        let feed = """
        <feed>
          <entry>
            <title>Moa 1.2.0</title>
            <id>tag:github.com,2026:Release/v1.2.0 Build: 123</id>
            <link rel="alternate" href="https://github.com/MoarLiu/Moa/releases/tag/v1.2.0"/>
            <content>Moa-1.2.0-macos-arm64.dmg Moa-1.2.0-macos-x86_64.dmg Build: 123</content>
          </entry>
        </feed>
        """
        let update = try MoaUpdateController.releaseInfo(fromAtomFeed: feed)
        try expect(update.version == "1.2.0", "Atom feed parser should extract release version")
        try expect(update.build == 123, "Atom feed parser should extract build number")
        try expect(update.releaseURL.absoluteString == "https://github.com/MoarLiu/Moa/releases/tag/v1.2.0", "Atom feed parser should preserve release URL")
        try expect(update.dmgURL.lastPathComponent.hasPrefix("Moa-1.2.0-macos-"), "Atom feed parser should choose a Moa DMG asset")
        try expect(update.checksumURL.lastPathComponent == update.dmgURL.lastPathComponent + ".sha256", "Atom feed parser should pair DMG checksum asset")
    }

    private static func testUpdaterBackupPruning() throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let backupRoot = root.appendingPathComponent("Update Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let old = backupRoot.appendingPathComponent("Moa-1.1.0-previous-20260101-010101.app", isDirectory: true)
        let middle = backupRoot.appendingPathComponent("Moa-1.1.1-previous-20260102-010101.app", isDirectory: true)
        let newest = backupRoot.appendingPathComponent("Moa-1.1.2-previous-20260103-010101.app", isDirectory: true)
        let invalid = backupRoot.appendingPathComponent("Moa-invalid.app", isDirectory: true)

        for url in [old, middle, newest, invalid] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        try MoaUpdateController.pruneUpdateBackups(in: backupRoot, keeping: 2)
        try expect(!FileManager.default.fileExists(atPath: old.path), "oldest valid update backup should be pruned")
        try expect(FileManager.default.fileExists(atPath: middle.path), "second newest valid update backup should be kept")
        try expect(FileManager.default.fileExists(atPath: newest.path), "newest valid update backup should be kept")
        try expect(FileManager.default.fileExists(atPath: invalid.path), "invalid backup names should be ignored")
    }

    private static func runSQLite(db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
            throw TestError.failure(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
