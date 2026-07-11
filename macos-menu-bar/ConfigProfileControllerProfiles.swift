import Foundation

extension ConfigProfileController {
    func profiles() throws -> [ConfigProfile] {
        try loadDatabase().profiles
    }

    func selectedProfileID() throws -> String? {
        try loadDatabase().selectedProfileID
    }

    func selectedProfileName() -> String? {
        guard let database = try? loadDatabase(), let selectedID = database.selectedProfileID else {
            return nil
        }

        if selectedID == Self.providerBridgeModeID {
            return MoaL10n.text("Provider Bridge")
        }

        guard let profile = database.profiles.first(where: { $0.id == selectedID }) else {
            return nil
        }
        return profile.name
    }
    func isProviderBridgeModeSelected() -> Bool {
        guard let selectedID = try? loadDatabase().selectedProfileID else {
            return false
        }
        return selectedID == Self.providerBridgeModeID
    }

    func selectedProfile() throws -> ConfigProfile? {
        let database = try loadDatabase()
        guard let selectedID = database.selectedProfileID else {
            return nil
        }

        return database.profiles.first(where: { $0.id == selectedID })
    }

    func recoveredAPIKeyFromProfileJSON(for profile: ConfigProfile) -> String? {
        let rawCandidates = profileRecoveryDatabaseURLs()
            .compactMap { url -> [ConfigProfile]? in
                guard let data = try? Data(contentsOf: url),
                      let database = try? JSONDecoder().decode(ProfileDatabase.self, from: data)
                else {
                    return nil
                }
                return database.profiles
            }
            .flatMap { $0 }
            .filter { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var seenCandidates = Set<String>()
        let candidates = rawCandidates.filter { candidate in
            let key = [
                candidate.id,
                candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                Self.profileRecoveryBaseURLKey(candidate.resolvedUpstreamBaseURL),
                candidate.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            ].joined(separator: "\u{1F}")
            guard !seenCandidates.contains(key) else {
                return false
            }
            seenCandidates.insert(key)
            return true
        }

        if let exact = candidates.first(where: { $0.id == profile.id }) {
            return exact.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let targetName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetBaseURL = Self.profileRecoveryBaseURLKey(profile.resolvedUpstreamBaseURL)
        let nameAndBaseMatches = candidates.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetName
                && Self.profileRecoveryBaseURLKey($0.resolvedUpstreamBaseURL) == targetBaseURL
        }
        if nameAndBaseMatches.count == 1 {
            return nameAndBaseMatches[0].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let baseMatches = candidates.filter {
            Self.profileRecoveryBaseURLKey($0.resolvedUpstreamBaseURL) == targetBaseURL
        }
        if baseMatches.count == 1 {
            return baseMatches[0].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let nameMatches = candidates.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetName
        }
        if nameMatches.count == 1 {
            return nameMatches[0].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    func profileRecoveryDatabaseURLs() -> [URL] {
        let urls = [
            MoaDataRoot.legacyNestedICloudURL(environment: environment).appendingPathComponent("profiles.json"),
            MoaDataRoot.localURL(environment: environment).appendingPathComponent("profiles.json"),
            MoaDataRoot.iCloudURL(environment: environment).appendingPathComponent("profiles.json")
        ]
        let currentPath = databaseURL.standardizedFileURL.path
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard path != currentPath, !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    static func profileRecoveryBaseURLKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") {
            key.removeLast()
        }
        if key.hasSuffix("/v1") {
            key.removeLast(3)
        }
        return key
    }
    func addProfile(
        name: String,
        baseURL: String,
        apiKey: String,
        providerKind: MoaProviderKind? = nil,
        clientTarget: MoaProviderClientTarget? = nil,
        upstreamProtocol: MoaProviderUpstreamProtocol? = nil,
        bridgeMode: MoaProviderBridgeMode? = nil,
        upstreamBaseURL: String? = nil,
        model: String? = nil,
        testModel: String? = nil,
        models: [String]? = nil,
        reasoningMode: MoaProviderReasoningMode? = nil
    ) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            let resolvedProviderKind = providerKind ?? .custom
            let resolvedUpstreamProtocol = upstreamProtocol ?? .responses
            let resolvedBridgeMode = bridgeMode ?? .direct
            let validatedBaseURL = try Self.validatedProfileBaseURL(
                baseURL,
                providerKind: resolvedProviderKind,
                upstreamProtocol: resolvedUpstreamProtocol,
                bridgeMode: resolvedBridgeMode
            )
            let validatedUpstreamBaseURL = try Self.validatedUpstreamBaseURL(
                upstreamBaseURL ?? baseURL,
                providerKind: resolvedProviderKind,
                upstreamProtocol: resolvedUpstreamProtocol,
                bridgeMode: resolvedBridgeMode
            )
            let profile = ConfigProfile(
                id: UUID().uuidString,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: validatedBaseURL,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                schemaVersion: resolvedBridgeMode == .direct && resolvedUpstreamProtocol == .responses ? nil : 2,
                providerKind: providerKind,
                clientTarget: clientTarget,
                upstreamProtocol: upstreamProtocol,
                bridgeMode: bridgeMode,
                upstreamBaseURL: validatedUpstreamBaseURL == validatedBaseURL ? nil : validatedUpstreamBaseURL,
                model: Self.normalizedOptionalString(model),
                testModel: Self.normalizedOptionalString(testModel),
                models: models,
                reasoningMode: reasoningMode,
                bridgeToken: nil,
                bridgePort: resolvedBridgeMode == .localBridge ? MoaProviderBridgeDefaults.defaultPort : nil
            )

            database.profiles.append(profile)
            try saveDatabase(database)
            return profile
        }
    }

    func updateProfile(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String,
        providerKind: MoaProviderKind? = nil,
        clientTarget: MoaProviderClientTarget? = nil,
        upstreamProtocol: MoaProviderUpstreamProtocol? = nil,
        bridgeMode: MoaProviderBridgeMode? = nil,
        upstreamBaseURL: String? = nil,
        model: String? = nil,
        testModel: String? = nil,
        models: [String]? = nil,
        reasoningMode: MoaProviderReasoningMode? = nil
    ) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Configuration not found.")])
            }

            let current = database.profiles[index]
            let resolvedProviderKind = providerKind ?? current.providerKind ?? .custom
            let resolvedUpstreamProtocol = upstreamProtocol ?? current.upstreamProtocol ?? .responses
            let resolvedBridgeMode = bridgeMode ?? current.bridgeMode ?? .direct
            let validatedBaseURL = try Self.validatedProfileBaseURL(
                baseURL,
                providerKind: resolvedProviderKind,
                upstreamProtocol: resolvedUpstreamProtocol,
                bridgeMode: resolvedBridgeMode
            )
            let upstreamCandidate = upstreamBaseURL
                ?? (resolvedBridgeMode == .localBridge ? baseURL : current.upstreamBaseURL)
                ?? baseURL
            let validatedUpstreamBaseURL = try Self.validatedUpstreamBaseURL(
                upstreamCandidate,
                providerKind: resolvedProviderKind,
                upstreamProtocol: resolvedUpstreamProtocol,
                bridgeMode: resolvedBridgeMode
            )
            database.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            database.profiles[index].baseURL = validatedBaseURL
            database.profiles[index].apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            database.profiles[index].schemaVersion = resolvedBridgeMode == .direct && resolvedUpstreamProtocol == .responses ? current.schemaVersion : 2
            database.profiles[index].providerKind = providerKind ?? current.providerKind
            database.profiles[index].clientTarget = clientTarget ?? current.clientTarget
            database.profiles[index].upstreamProtocol = upstreamProtocol ?? current.upstreamProtocol
            database.profiles[index].bridgeMode = bridgeMode ?? current.bridgeMode
            database.profiles[index].upstreamBaseURL = validatedUpstreamBaseURL == validatedBaseURL ? nil : validatedUpstreamBaseURL
            database.profiles[index].model = Self.normalizedOptionalString(model) ?? current.model
            database.profiles[index].testModel = Self.normalizedOptionalString(testModel) ?? current.testModel
            database.profiles[index].models = models ?? current.models
            database.profiles[index].reasoningMode = reasoningMode ?? current.reasoningMode
            if resolvedBridgeMode != .localBridge {
                database.profiles[index].bridgeToken = nil
                database.profiles[index].bridgePort = nil
            } else if database.profiles[index].bridgePort == nil {
                database.profiles[index].bridgePort = MoaProviderBridgeDefaults.defaultPort
            }

            let profile = database.profiles[index]
            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func deleteProfile(id: String) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Configuration not found.")])
            }

            let profile = database.profiles.remove(at: index)
            if database.selectedProfileID == id {
                database.selectedProfileID = nil
            }

            try saveDatabase(database)
            return profile
        }
    }

    @discardableResult
    func moveLocalBridgeProfiles(to bridgeController: ProviderBridgeProfileController) throws -> Int {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            let localBridgeProfiles = database.profiles.filter { $0.usesLocalProviderBridge }
            guard !localBridgeProfiles.isEmpty else {
                return 0
            }

            let selectedLocalBridgeID = database.selectedProfileID.flatMap { selectedID in
                localBridgeProfiles.contains { $0.id == selectedID } ? selectedID : nil
            }
            try bridgeController.importLegacyProfiles(localBridgeProfiles, selectedProfileID: selectedLocalBridgeID)

            database.profiles.removeAll { $0.usesLocalProviderBridge }
            if let selectedLocalBridgeID, database.selectedProfileID == selectedLocalBridgeID {
                database.selectedProfileID = Self.providerBridgeModeID
            } else if let selectedID = database.selectedProfileID,
                      !database.profiles.contains(where: { $0.id == selectedID }) {
                database.selectedProfileID = nil
            }
            try saveDatabase(database)
            return localBridgeProfiles.count
        }
    }

    @discardableResult
    func updateBridgeRuntime(id: String, port: Int? = nil, token: String? = nil) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            var database = try loadDatabase()
            guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Configuration not found.")])
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
                throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Configuration not found.")])
            }

            let normalized = Self.normalizedModelList(models)
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
}
