import Foundation

final class ProviderBridgeProfileController {
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let stateLock = NSRecursiveLock()

    private var moaHome: URL {
        MoaDataRoot.currentURL(environment: environment)
    }

    private var databaseURL: URL {
        moaHome.appendingPathComponent("provider_bridge_profiles.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        try? ensureStore()
    }

    func profiles() throws -> [ConfigProfile] {
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

    func selectedProfile() throws -> ConfigProfile? {
        let database = try loadDatabase()
        guard let selectedID = database.selectedProfileID else {
            return nil
        }

        return database.profiles.first(where: { $0.id == selectedID })
    }

    func importLegacyProfiles(_ profiles: [ConfigProfile], selectedProfileID: String?) throws {
        try stateLock.withLock {
            let legacyProfiles = profiles.filter { $0.usesLocalProviderBridge }
            guard !legacyProfiles.isEmpty else {
                return
            }

            try ensureStore()
            var database = try loadDatabase()
            var existingIDs = Set(database.profiles.map(\.id))
            var importedIDs = Set<String>()

            for legacyProfile in legacyProfiles {
                var profile = legacyProfile
                profile.schemaVersion = 2
                profile.clientTarget = profile.clientTarget ?? .codex
                profile.upstreamProtocol = profile.upstreamProtocol ?? .chatCompletions
                profile.bridgeMode = profile.bridgeMode ?? .localBridge
                if profile.bridgePort == nil {
                    profile.bridgePort = MoaProviderBridgeDefaults.defaultPort
                }
                profile.bridgePort = try MoaProviderBridgePort.validated(profile.resolvedBridgePort)

                importedIDs.insert(profile.id)
                guard !existingIDs.contains(profile.id) else {
                    continue
                }

                database.profiles.append(profile)
                existingIDs.insert(profile.id)
            }

            if let selectedProfileID, importedIDs.contains(selectedProfileID) {
                database.selectedProfileID = selectedProfileID
            } else if database.selectedProfileID == nil,
                      let firstImportedID = legacyProfiles.first?.id {
                database.selectedProfileID = firstImportedID
            }

            try saveDatabase(database)
        }
    }

    @discardableResult
    func addProfile(
        name: String,
        baseURL: String,
        apiKey: String,
        preset: MoaProviderPreset
    ) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            let validatedBaseURL = try Self.validatedBridgeBaseURL(
                baseURL,
                providerKind: preset.providerKind
            )
            let profile = ConfigProfile(
                id: UUID().uuidString,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: validatedBaseURL,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                schemaVersion: 2,
                providerKind: preset.providerKind,
                clientTarget: .codex,
                upstreamProtocol: .chatCompletions,
                bridgeMode: .localBridge,
                upstreamBaseURL: nil,
                model: preset.model,
                testModel: preset.testModel,
                models: preset.models,
                reasoningMode: preset.reasoningMode,
                bridgeToken: nil,
                bridgePort: MoaProviderBridgeDefaults.defaultPort
            )

            database.profiles.append(profile)
            database.selectedProfileID = profile.id
            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func applyProfile(id: String) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let profile = database.profiles.first(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Provider Bridge profile not found.")])
            }
            _ = try MoaProviderBridgePort.validated(profile.resolvedBridgePort)

            database.selectedProfileID = id
            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func updateBridgeRuntime(id: String, port: Int? = nil, token: String? = nil) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Provider Bridge profile not found.")])
            }
            if let port {
                database.profiles[index].bridgePort = try MoaProviderBridgePort.validated(port)
            }
            if let token {
                database.profiles[index].bridgeToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            database.profiles[index].schemaVersion = 2
            let profile = database.profiles[index]
            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func updateModels(id: String, models: [String]) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Provider Bridge profile not found.")])
            }

            let normalized = normalizedModelList(models)
            guard !normalized.isEmpty else {
                throw NSError(domain: "Moa", code: 422, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("The models endpoint returned no model IDs.")])
            }

            database.profiles[index].models = normalized
            if database.profiles[index].resolvedModel == nil {
                database.profiles[index].model = normalized.first
            }
            if database.profiles[index].resolvedTestModel == nil {
                database.profiles[index].testModel = normalized.first
            }
            database.profiles[index].schemaVersion = 2
            let profile = database.profiles[index]
            try saveDatabase(database)
            return profile
        }
    }

    private func ensureStore() throws {
        try stateLock.withLock {
            try fileManager.createDirectory(at: moaHome, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: databaseURL.path) {
                try saveDatabase(ProfileDatabase(selectedProfileID: nil, profiles: []))
            }
        }
    }

    private var cachedDatabase: ProfileDatabase?
    private var cachedDatabaseModified: Date?
    private var cachedDatabaseURLPath: String?

    private func loadDatabase() throws -> ProfileDatabase {
        try stateLock.withLock {
            try ensureStoreIfMissingOnly()
            let modified = (try? fileManager.attributesOfItem(atPath: databaseURL.path))?[.modificationDate] as? Date
            if let cachedDatabase, let cachedDatabaseModified, let modified,
               cachedDatabaseModified == modified,
               cachedDatabaseURLPath == databaseURL.standardizedFileURL.path {
                return cachedDatabase
            }
            let data = try Data(contentsOf: databaseURL)
            let database = try JSONDecoder().decode(ProfileDatabase.self, from: data)
            cachedDatabase = database
            cachedDatabaseModified = modified
            cachedDatabaseURLPath = databaseURL.standardizedFileURL.path
            return database
        }
    }

    private func saveDatabase(_ database: ProfileDatabase) throws {
        try stateLock.withLock {
            try database.profiles.compactMap(\.bridgePort).forEach { _ = try MoaProviderBridgePort.validated($0) }
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

    private static func validatedBridgeBaseURL(_ raw: String, providerKind: MoaProviderKind) throws -> String {
        if providerKind == .deepseek {
            return try MoaProviderBridgeEndpointNormalizer.normalizedDeepSeekChatBaseURL(raw)
        }
        return try MoaProviderBaseURLPolicy.validate(raw).normalizedString
    }

    private func normalizedModelList(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            output.append(trimmed)
        }
        return output
    }
}
