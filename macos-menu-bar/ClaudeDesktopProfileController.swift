import AppKit
import Foundation

struct ClaudeDesktopProviderProfile: Codable, Equatable {
    let id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var models: [String]
    var oneMModels: [String]? = nil

    init(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String,
        models: [String],
        oneMModels: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.oneMModels = oneMModels
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiKey
        case models
        case oneMModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        oneMModels = try container.decodeIfPresent([String].self, forKey: .oneMModels)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(models, forKey: .models)
        try container.encodeIfPresent(oneMModels, forKey: .oneMModels)
    }

    var enabledOneMModels: [String] {
        oneMModels ?? []
    }
}

private struct ClaudeDesktopProviderDatabase: Codable {
    var selectedProfileID: String?
    var profiles: [ClaudeDesktopProviderProfile]
}

private enum ClaudeDesktopProfileControllerError: LocalizedError {
    case profileNotFound
    case invalidBaseURL
    case invalidModel(String)
    case missingRequiredFields

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return MoaL10n.text("Claude Desktop provider not found.")
        case .invalidBaseURL:
            return MoaL10n.text("Claude Desktop API Base URL must use https://; only localhost, 127.0.0.1, and ::1 may use http://.")
        case .invalidModel(let model):
            return MoaL10n.format("Claude Desktop direct models must use Claude-safe names such as claude-* or anthropic/claude-*: %@", model)
        case .missingRequiredFields:
            return MoaL10n.text("Name, base URL, and API key are required.")
        }
    }
}

final class ClaudeDesktopProfileController {
    private struct FileSnapshot {
        let url: URL
        let content: Data?
    }

    private static let profileID = "00000000-0000-4000-8000-000000157211"
    private static let profileName = "Moa"
    private static let configFileName = "claude_desktop_config.json"

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let normalClaudeDir: URL
    private let threePClaudeDir: URL
    private let configLibraryURL: URL
    private let normalConfigURL: URL
    private let threePConfigURL: URL
    private let profileURL: URL
    private let metaURL: URL
    private let stateLock = NSRecursiveLock()

    #if MOA_TESTING
    static var testingDatabaseSaveFailuresRemaining = 0
    #endif

    private var moaHome: URL {
        MoaDataRoot.currentURL(environment: environment)
    }

    private var databaseURL: URL {
        moaHome.appendingPathComponent("claude_desktop_profiles.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let appSupport = URL(fileURLWithPath: "\(home)/Library/Application Support").standardizedFileURL

        normalClaudeDir = appSupport.appendingPathComponent("Claude")
        threePClaudeDir = appSupport.appendingPathComponent("Claude-3p")
        configLibraryURL = threePClaudeDir.appendingPathComponent("configLibrary")
        normalConfigURL = normalClaudeDir.appendingPathComponent(Self.configFileName)
        threePConfigURL = threePClaudeDir.appendingPathComponent(Self.configFileName)
        profileURL = configLibraryURL.appendingPathComponent("\(Self.profileID).json")
        metaURL = configLibraryURL.appendingPathComponent("_meta.json")

        try? ensureStore()
    }

    func profiles() throws -> [ClaudeDesktopProviderProfile] {
        try loadDatabase().profiles
    }

    func selectedProfileID() throws -> String? {
        try loadDatabase().selectedProfileID
    }

    func selectedProfileName() -> String? {
        guard
            let database = try? loadDatabase(),
            let selectedID = database.selectedProfileID,
            let profile = database.profiles.first(where: { $0.id == selectedID })
        else {
            return nil
        }

        return profile.name
    }

    func selectedProfile() throws -> ClaudeDesktopProviderProfile? {
        let database = try loadDatabase()
        guard let selectedID = database.selectedProfileID else {
            return nil
        }

        return database.profiles.first(where: { $0.id == selectedID })
    }

    func addProfile(name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String]) throws -> ClaudeDesktopProviderProfile {
        try stateLock.withLock {
            try ensureStore()
            let validatedBaseURL = try validate(name: name, baseURL: baseURL, apiKey: apiKey, models: models, oneMModels: oneMModels)

            var database = try loadDatabase()
            let profile = ClaudeDesktopProviderProfile(
                id: UUID().uuidString,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: validatedBaseURL,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                models: models,
                oneMModels: oneMModels.isEmpty ? nil : oneMModels
            )

            database.profiles.append(profile)
            try saveDatabase(database)
            return profile
        }
    }

    func updateProfile(id: String, name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String]) throws -> ClaudeDesktopProviderProfile {
        try stateLock.withLock {
            try ensureStore()
            let validatedBaseURL = try validate(name: name, baseURL: baseURL, apiKey: apiKey, models: models, oneMModels: oneMModels)

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw ClaudeDesktopProfileControllerError.profileNotFound
            }

            database.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            database.profiles[index].baseURL = validatedBaseURL
            database.profiles[index].apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            database.profiles[index].models = models
            database.profiles[index].oneMModels = oneMModels.isEmpty ? nil : oneMModels

            let profile = database.profiles[index]
            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func deleteProfile(id: String) throws -> ClaudeDesktopProviderProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw ClaudeDesktopProfileControllerError.profileNotFound
            }

            let profile = database.profiles.remove(at: index)
            let wasSelected = database.selectedProfileID == id
            if wasSelected {
                database.selectedProfileID = nil
            }

            try withStateTransaction(database: database) {
                if wasSelected {
                    try writeOfficialFiles()
                }
            }
            return profile
        }
    }

    func exportProfiles(includingAPIKeys: Bool) throws -> Data {
        try ensureStore()
        let entries = try loadDatabase().profiles.map { profile in
            ProviderProfileExportEntry(
                name: profile.name,
                baseURL: profile.baseURL,
                apiKey: includingAPIKeys ? profile.apiKey : nil,
                models: profile.models,
                oneMModels: profile.enabledOneMModels.isEmpty ? nil : profile.enabledOneMModels,
                providerKind: nil,
                clientTarget: nil,
                upstreamProtocol: nil,
                bridgeMode: nil,
                upstreamBaseURL: nil,
                model: nil,
                testModel: nil,
                reasoningMode: nil)
        }
        let document = ProviderProfileExportDocument(
            schemaVersion: 1,
            provider: Self.exportProviderID,
            exportedAt: Self.isoTimestamp(),
            profiles: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    @discardableResult
    func importProfiles(from data: Data) throws -> Int {
        try stateLock.withLock {
            try ensureStore()
            let document = try JSONDecoder().decode(ProviderProfileExportDocument.self, from: data)
            guard document.provider == Self.exportProviderID else {
                throw ProviderProfileExportError.providerMismatch(expected: "Claude Desktop", actual: document.provider)
            }
            guard !document.profiles.isEmpty else {
                throw ProviderProfileExportError.emptyDocument
            }

            var database = try loadDatabase()
            for entry in document.profiles {
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseURL = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let validatedBaseURL = try? Self.validatedProfileBaseURL(baseURL) else {
                    throw ProviderProfileExportError.invalidProfile(entry.name)
                }

                let parsedModels = try Self.normalizedModels(from: (entry.models ?? []).joined(separator: ","))
                let exportedOneMModels = entry.oneMModels ?? []
                for model in exportedOneMModels where !Self.isClaudeSafeModelID(model) {
                    throw ClaudeDesktopProfileControllerError.invalidModel(model)
                }
                let oneMModelSet = Set(parsedModels.oneMModels + exportedOneMModels)
                let profile = ClaudeDesktopProviderProfile(
                    id: UUID().uuidString,
                    name: name,
                    baseURL: validatedBaseURL,
                    apiKey: entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    models: parsedModels.models,
                    oneMModels: oneMModelSet.isEmpty ? nil : parsedModels.models.filter { oneMModelSet.contains($0) })
                database.profiles.append(profile)
            }

            try saveDatabase(database)
            return document.profiles.count
        }
    }

    @discardableResult
    func applyProfile(id: String) throws -> ClaudeDesktopProviderProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw ClaudeDesktopProfileControllerError.profileNotFound
            }
            var profile = database.profiles[index]

            profile.baseURL = try validate(
                name: profile.name,
                baseURL: profile.baseURL,
                apiKey: profile.apiKey,
                models: profile.models,
                oneMModels: profile.enabledOneMModels
            )
            database.profiles[index] = profile
            database.selectedProfileID = profile.id
            try withStateTransaction(database: database) {
                try writeDeploymentMode(to: normalConfigURL, mode: "3p")
                try writeDeploymentMode(to: threePConfigURL, mode: "3p")
                try writeGatewayProfile(profile)
                try writeMeta(appliedProfileID: Self.profileID)
            }
            return profile
        }
    }

    func restoreOfficial() throws {
        try stateLock.withLock {
            try ensureStore()
            var database = try loadDatabase()
            database.selectedProfileID = nil
            try withStateTransaction(database: database) {
                try writeOfficialFiles()
            }
        }
    }

    func openClaudeDesktopFolder() {
        try? fileManager.createDirectory(at: normalClaudeDir, withIntermediateDirectories: true)
        _ = run("/usr/bin/open", [normalClaudeDir.path])
    }

    func openClaudeDesktop3PFolder() {
        try? fileManager.createDirectory(at: configLibraryURL, withIntermediateDirectories: true)
        _ = run("/usr/bin/open", [configLibraryURL.path])
    }

    func openClaudeDesktop() {
        _ = run("/usr/bin/open", ["-a", "Claude"])
    }

    func reopenClaudeDesktop() {
        if isClaudeDesktopRunning() {
            _ = run("/usr/bin/osascript", ["-e", "tell application \"Claude\" to quit"])
            _ = waitForClaudeDesktopRunning(false, timeout: 4)
        }
        openClaudeDesktop()
    }

    static func normalizedModels(from text: String) throws -> (models: [String], oneMModels: [String]) {
        let separators = CharacterSet(charactersIn: ",\n;")
        var seen = Set<String>()
        var models: [String] = []
        var oneMModelSet = Set<String>()

        for rawModel in text.components(separatedBy: separators) {
            let parsed = parseModelInput(rawModel)
            let model = parsed.model
            guard !model.isEmpty else {
                continue
            }

            guard isClaudeSafeModelID(model) else {
                throw ClaudeDesktopProfileControllerError.invalidModel(model)
            }

            if !seen.contains(model) {
                models.append(model)
                seen.insert(model)
            }

            if parsed.supports1M {
                oneMModelSet.insert(model)
            }
        }

        return (models, models.filter { oneMModelSet.contains($0) })
    }

    private func ensureStore() throws {
        try stateLock.withLock {
            try fileManager.createDirectory(at: moaHome, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: databaseURL.path) {
                try saveDatabase(ClaudeDesktopProviderDatabase(selectedProfileID: nil, profiles: []))
            }
        }
    }

    private var cachedDatabase: ClaudeDesktopProviderDatabase?
    private var cachedDatabaseModified: Date?
    private var cachedDatabaseURLPath: String?

    private func loadDatabase() throws -> ClaudeDesktopProviderDatabase {
        try stateLock.withLock {
            try ensureStoreIfMissingOnly()
            let modified = (try? fileManager.attributesOfItem(atPath: databaseURL.path))?[.modificationDate] as? Date
            if let cachedDatabase, let cachedDatabaseModified, let modified,
               cachedDatabaseModified == modified,
               cachedDatabaseURLPath == databaseURL.standardizedFileURL.path {
                return cachedDatabase
            }
            let data = try Data(contentsOf: databaseURL)
            let database = try JSONDecoder().decode(ClaudeDesktopProviderDatabase.self, from: data)
            cachedDatabase = database
            cachedDatabaseModified = modified
            cachedDatabaseURLPath = databaseURL.standardizedFileURL.path
            return database
        }
    }

    private func saveDatabase(_ database: ClaudeDesktopProviderDatabase) throws {
        try stateLock.withLock {
            #if MOA_TESTING
            if Self.testingDatabaseSaveFailuresRemaining > 0 {
                Self.testingDatabaseSaveFailuresRemaining -= 1
                throw NSError(
                    domain: "MoaTests",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Injected Claude profile database save failure."]
                )
            }
            #endif
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(database)
            try data.write(to: databaseURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            cachedDatabase = database
            cachedDatabaseModified = (try? fileManager.attributesOfItem(atPath: databaseURL.path))?[.modificationDate] as? Date
            cachedDatabaseURLPath = databaseURL.standardizedFileURL.path
        }
    }

    private func ensureStoreIfMissingOnly() throws {
        if !fileManager.fileExists(atPath: databaseURL.path) {
            try ensureStore()
        }
    }

    private func writeOfficialFiles() throws {
        try writeDeploymentMode(to: normalConfigURL, mode: "1p")
        try writeDeploymentMode(to: threePConfigURL, mode: "1p")
        try removeMoaEnterpriseConfig(from: threePConfigURL)
        if fileManager.fileExists(atPath: profileURL.path) {
            try fileManager.removeItem(at: profileURL)
        }
        try writeMeta(appliedProfileID: nil)
    }

    @discardableResult
    private func validate(name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String]) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !baseURL.isEmpty, !apiKey.isEmpty else {
            throw ClaudeDesktopProfileControllerError.missingRequiredFields
        }

        let validatedBaseURL: String
        do {
            validatedBaseURL = try Self.validatedProfileBaseURL(baseURL)
        } catch {
            throw ClaudeDesktopProfileControllerError.invalidBaseURL
        }

        for model in models where !Self.isClaudeSafeModelID(model) {
            throw ClaudeDesktopProfileControllerError.invalidModel(model)
        }

        for model in oneMModels where !Self.isClaudeSafeModelID(model) {
            throw ClaudeDesktopProfileControllerError.invalidModel(model)
        }

        return validatedBaseURL
    }

    private static func validatedProfileBaseURL(_ raw: String) throws -> String {
        try MoaProviderBaseURLPolicy.validate(raw).normalizedString
    }

    private func withStateTransaction(
        database: ClaudeDesktopProviderDatabase,
        operation: () throws -> Void
    ) throws {
        let snapshots = try snapshotStateFiles()
        let cachedDatabaseBefore = cachedDatabase
        let cachedDatabaseModifiedBefore = cachedDatabaseModified
        let cachedDatabaseURLPathBefore = cachedDatabaseURLPath
        do {
            try operation()
            try saveDatabase(database)
        } catch let operationError {
            do {
                try restoreSnapshots(snapshots)
                cachedDatabase = cachedDatabaseBefore
                cachedDatabaseModified = cachedDatabaseModifiedBefore
                cachedDatabaseURLPath = cachedDatabaseURLPathBefore
            } catch let rollbackError {
                throw NSError(
                    domain: "Moa",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: MoaL10n.format(
                        "Claude Desktop state update failed (%@), and rollback also failed: %@",
                        operationError.localizedDescription,
                        rollbackError.localizedDescription
                    )]
                )
            }

            throw operationError
        }
    }

    private func snapshotStateFiles() throws -> [FileSnapshot] {
        try [normalConfigURL, threePConfigURL, profileURL, metaURL, databaseURL].map { url in
            let content = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            return FileSnapshot(url: url, content: content)
        }
    }

    private func restoreSnapshots(_ snapshots: [FileSnapshot]) throws {
        for snapshot in snapshots {
            if let content = snapshot.content {
                try writeData(content, to: snapshot.url)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try fileManager.removeItem(at: snapshot.url)
            }
        }
    }

    private func writeDeploymentMode(to url: URL, mode: String) throws {
        var object = try readJSONObject(from: url)
        object["deploymentMode"] = mode
        try writeJSONObject(object, to: url)
    }

    private func writeGatewayProfile(_ profile: ClaudeDesktopProviderProfile) throws {
        var object: [String: Any] = [
            "coworkEgressAllowedHosts": ["*"],
            "disableDeploymentModeChooser": true,
            "inferenceGatewayApiKey": profile.apiKey,
            "inferenceGatewayAuthScheme": "bearer",
            "inferenceGatewayBaseUrl": profile.baseURL,
            "inferenceProvider": "gateway"
        ]

        if !profile.models.isEmpty {
            let oneMModelSet = Set(profile.enabledOneMModels)
            object["inferenceModels"] = profile.models.map { model -> Any in
                if oneMModelSet.contains(model) {
                    return [
                        "name": model,
                        "supports1m": true
                    ]
                }

                return model
            }
        }

        try writeJSONObject(object, to: profileURL)
    }

    private func removeMoaEnterpriseConfig(from url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        var object = try readJSONObject(from: url)
        guard var enterpriseConfig = object["enterpriseConfig"] as? [String: Any] else {
            return
        }

        for key in [
            "disableDeploymentModeChooser",
            "inferenceGatewayApiKey",
            "inferenceGatewayAuthScheme",
            "inferenceGatewayBaseUrl",
            "inferenceProvider"
        ] {
            enterpriseConfig.removeValue(forKey: key)
        }

        if enterpriseConfig.isEmpty {
            object.removeValue(forKey: "enterpriseConfig")
        } else {
            object["enterpriseConfig"] = enterpriseConfig
        }

        try writeJSONObject(object, to: url)
    }

    private func writeMeta(appliedProfileID: String?) throws {
        var object = try readJSONObject(from: metaURL)
        var entries = object["entries"] as? [[String: Any]] ?? []
        entries.removeAll { entry in
            entry["id"] as? String == Self.profileID
        }

        if let appliedProfileID {
            entries.append([
                "id": Self.profileID,
                "name": Self.profileName
            ])
            object["appliedId"] = appliedProfileID
        } else if object["appliedId"] as? String == Self.profileID {
            if let nextID = entries.compactMap({ $0["id"] as? String }).first {
                object["appliedId"] = nextID
            } else {
                object.removeValue(forKey: "appliedId")
            }
        }

        object["entries"] = entries
        try writeJSONObject(object, to: metaURL)
    }

    private func readJSONObject(from url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        let value = try JSONSerialization.jsonObject(with: data)
        return value as? [String: Any] ?? [:]
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeData(data, to: url)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        if let parent = url.deletingLastPathComponent().path.isEmpty ? nil : url.deletingLastPathComponent() {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
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

    private func isClaudeDesktopRunning() -> Bool {
        run("/usr/bin/pgrep", ["-x", "Claude"]) == 0
    }

    private func waitForClaudeDesktopRunning(_ running: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isClaudeDesktopRunning() == running {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isClaudeDesktopRunning() == running
    }

    private static func isClaudeSafeModelID(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDeepSeekModel = normalized.hasPrefix("deepseek-") && normalized.count > "deepseek-".count
        let allowedShape = (normalized.hasPrefix("claude-") && normalized.count > "claude-".count)
            || (normalized.hasPrefix("anthropic/claude-") && normalized.count > "anthropic/claude-".count)
            || normalized == "sonnet"
            || normalized == "opus"
            || normalized == "haiku"
            || (normalized.hasPrefix("sonnet-") && normalized.count > "sonnet-".count)
            || (normalized.hasPrefix("opus-") && normalized.count > "opus-".count)
            || (normalized.hasPrefix("haiku-") && normalized.count > "haiku-".count)
            || isDeepSeekModel

        guard allowedShape, !normalized.contains("[1m]") else {
            return false
        }

        if isDeepSeekModel {
            return true
        }

        return !nonAnthropicRouteMarkers.contains { normalized.contains($0) }
    }

    private static func parseModelInput(_ rawModel: String) -> (model: String, supports1M: Bool) {
        var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var supports1M = false

        for suffix in ["[1m]", "(1m)", "+1m"] {
            if model.lowercased().hasSuffix(suffix) {
                model = String(model.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                supports1M = true
                break
            }
        }

        return (model, supports1M)
    }

    private static let nonAnthropicRouteMarkers = [
        "ark-code",
        "astron",
        "command-r",
        "deepseek",
        "doubao",
        "gemini",
        "gemma",
        "glm",
        "gpt",
        "grok",
        "hermes",
        "hy3",
        "kimi",
        "lfm",
        "llama",
        "longcat",
        "mimo",
        "minimax",
        "mistral",
        "mixtral",
        "moonshot",
        "nemotron",
        "openai",
        "qianfan",
        "qwen",
        "stepfun",
        "seed-",
        "hunyuan",
        "nova-",
        "ernie",
        "codex",
        "abab",
        "jamba",
        "arctic",
        "solar",
        "mercury"
    ]

    private static let exportProviderID = "claudeDesktop"

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
