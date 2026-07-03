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
            ("legacy Moa-Lite local data migrates without overwrite", testLegacyMoaLiteLocalDataMigration),
            ("legacy Moa-Lite iCloud data migrates to Moa", testLegacyMoaLiteICloudDataMigration),
            ("provider bridge defaults use Moa port", testProviderBridgeDefaultPort),
            ("Codex bridge provider IDs use Moa prefix", testCodexBridgeProviderIDs),
            ("official restore keeps selected provider identity", testOfficialRestoreKeepsSelectedProviderIdentity),
            ("official restore strips selected direct provider credentials", testOfficialRestoreStripsSelectedDirectProviderCredentials),
            ("Codex session provider migration requires current provider", testCodexSessionProviderMigrationRequiresCurrentProvider),
            ("Codex session provider migration updates JSONL and SQLite", testCodexSessionProviderMigrationUpdatesJSONLAndSQLite),
            ("Codex session provider migration rolls back on failure", testCodexSessionProviderMigrationRollsBackOnFailure),
            ("official account displays email from auth token", testOfficialAccountDisplaysEmailFromAuthToken),
            ("official no-account mode preserves third-party config without login", testOfficialNoAccountPreservesThirdPartyConfigWithoutLogin),
            ("official no-account mode captures current login without selecting it", testOfficialNoAccountCapturesCurrentLoginWithoutSelectingIt),
            ("official no-account mode selects first direct config when none selected", testOfficialNoAccountSelectsFirstDirectConfigWhenNoneSelected),
            ("official no-account mode deduplicates current login by email", testOfficialNoAccountDeduplicatesCurrentLoginByEmail),
            ("official account list syncs selected account email", testOfficialAccountListSyncsSelectedAccountEmail),
            ("LiteLLM preset no longer uses original Moa model name", testLiteLLMPresetName),
            ("ZCode GLM pricing is estimated from usage tokens", testZCodePricing),
            ("ZCode usage scanner aggregates local SQLite usage", testZCodeUsageScanner)
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

        let migrated = try MoaDataRoot.migrateLegacyMoaLiteRootsIfNeeded(environment: environment)
        let newSupport = MoaDataRoot.supportDirectory(environment: environment)
        let newICloud = MoaDataRoot.iCloudURL(environment: environment)
        try expect(migrated, "legacy iCloud data should migrate")
        try expect(fileManager.fileExists(atPath: newSupport.appendingPathComponent("icloud-data-root-enabled").path), "iCloud state should migrate to Moa support directory")
        let migratedICloudProfileData = try String(contentsOf: newICloud.appendingPathComponent("profiles.json"), encoding: .utf8)
        try expect(migratedICloudProfileData == "icloud", "legacy iCloud data should copy to iCloud Drive/Moa")
        try expect(MoaDataRoot.currentURL(environment: environment).lastPathComponent == "Moa", "current root should use migrated Moa iCloud folder")
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
        let email = "cooloosy@outlook.com"
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

        let email = "cooloosy@outlook.com"
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

        let email = "cooloosy@outlook.com"
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
