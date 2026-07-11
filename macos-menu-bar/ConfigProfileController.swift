import AppKit
import Foundation

final class ConfigProfileController {
    struct StateFileSnapshot {
        let url: URL
        let data: Data?
    }

    struct StateDirectorySnapshot {
        let url: URL
        let existed: Bool
        let files: [String: Data]
    }

    let fileManager = FileManager.default
    let environment: [String: String]
    let codexHome: URL
    let codexApp: URL
    let stateLock = NSRecursiveLock()

    #if MOA_TESTING
    static var testingProfileDatabaseSaveFailuresRemaining = 0
    static var testingOfficialAccountDatabaseSaveFailuresRemaining = 0
    #endif

    var codexConfigURL: URL {
        codexHome.appendingPathComponent("config.toml")
    }

    var codexAuthURL: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    var moaHome: URL {
        MoaDataRoot.currentURL(environment: environment)
    }

    var databaseURL: URL {
        moaHome.appendingPathComponent("profiles.json")
    }

    var officialAccountsDatabaseURL: URL {
        moaHome.appendingPathComponent("codex_official_accounts.json")
    }

    var officialAuthAccountsDir: URL {
        moaHome
            .appendingPathComponent("codex-auth", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
    }

    var moaConfigURL: URL {
        moaHome.appendingPathComponent("config.toml")
    }

    var moaAuthURL: URL {
        moaHome.appendingPathComponent("auth.json")
    }

    var backupDir: URL {
        moaHome.appendingPathComponent("backups")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let codexHomePath = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.codex"
        let codexAppPath = environment["CODEX_APP"].flatMap { $0.isEmpty ? nil : $0 } ?? "/Applications/Codex.app"

        codexHome = URL(fileURLWithPath: codexHomePath).standardizedFileURL
        codexApp = URL(fileURLWithPath: codexAppPath).standardizedFileURL

        try? bootstrap()
    }

    var cachedDatabase: ProfileDatabase?
    var cachedDatabaseModified: Date?
    var cachedDatabaseURLPath: String?
    var cachedOfficialAccountDatabase: CodexOfficialAccountDatabase?
    var cachedOfficialAccountDatabaseModified: Date?
    var cachedOfficialAccountDatabaseURLPath: String?

    static let defaultConfig = """
	model_provider = "Codex"
	model = "gpt-5.5"
	model_reasoning_effort = "high"
	disable_response_storage = true

	[features]
	remote_connections = true
	remote_control = true

	[model_providers.Codex]
	name = "Codex"
	base_url = "base_url"
	experimental_bearer_token = ""
	wire_api = "responses"
	requires_openai_auth = true
	"""

    static let exportProviderID = "codex"
    static let providerBridgeModeID = "moa-provider-bridge"
    static let officialAuthAccountsRelativePath = "codex-auth/accounts"
}
