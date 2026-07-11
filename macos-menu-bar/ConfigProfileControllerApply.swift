import Foundation

extension ConfigProfileController {
    @discardableResult
    func applyProfile(id: String) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            return try withCodexStateTransaction(
                files: [moaConfigURL, codexConfigURL, moaAuthURL, codexAuthURL, databaseURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                var database = try loadDatabase()
                guard let index = database.profiles.firstIndex(where: { $0.id == id }) else {
                    throw NSError(domain: "Moa", code: 404, userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Configuration not found.")])
                }
                var profile = database.profiles[index]
                profile = try preparedProfileForApply(profile)

                try syncMoaAuthSessionFromCodex()
                try backupCodexFiles()

                let currentConfig = try syncedMoaConfig()
                let generatedConfig = generateConfig(currentConfig, selecting: profile)
                try writeText(generatedConfig, to: moaConfigURL)
                try writeText(generatedConfig, to: codexConfigURL)
                try copyFile(from: moaAuthURL, to: codexAuthURL)

                database.profiles[index] = profile
                database.selectedProfileID = profile.id
                try saveDatabase(database)
                return profile
            }
        }
    }

    @discardableResult
    func applyProviderBridgeGateway(profile: ConfigProfile) throws -> ConfigProfile {
        try stateLock.withLock {
            try ensureStore()

            return try withCodexStateTransaction(
                files: [moaConfigURL, codexConfigURL, moaAuthURL, codexAuthURL, databaseURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                try syncMoaAuthSessionFromCodex()
                try backupCodexFiles()

                let currentConfig = try syncedMoaConfig()
                let generatedConfig = generateConfig(currentConfig, selecting: profile)
                try writeText(generatedConfig, to: moaConfigURL)
                try writeText(generatedConfig, to: codexConfigURL)
                try copyFile(from: moaAuthURL, to: codexAuthURL)

                var database = try loadDatabase()
                database.selectedProfileID = Self.providerBridgeModeID
                try saveDatabase(database)
                return profile
            }
        }
    }

    func preparedProfileForApply(_ profile: ConfigProfile) throws -> ConfigProfile {
        var prepared = profile
        if prepared.usesLocalProviderBridge {
            let normalized = try Self.validatedUpstreamBaseURL(
                prepared.resolvedUpstreamBaseURL,
                providerKind: prepared.resolvedProviderKind,
                upstreamProtocol: prepared.resolvedUpstreamProtocol,
                bridgeMode: prepared.resolvedBridgeMode
            )
            prepared.baseURL = normalized
            prepared.upstreamBaseURL = normalized
            prepared.schemaVersion = 2
            if prepared.bridgeToken?.isEmpty != false {
                prepared.bridgeToken = try MoaProviderBridgeToken.generate()
            }
            if prepared.bridgePort == nil {
                prepared.bridgePort = MoaProviderBridgeDefaults.defaultPort
            }
            _ = try MoaProviderBridgePort.validated(prepared.resolvedBridgePort)
            return prepared
        }

        prepared.baseURL = try Self.validatedProfileBaseURL(
            prepared.baseURL,
            providerKind: prepared.resolvedProviderKind,
            upstreamProtocol: prepared.resolvedUpstreamProtocol,
            bridgeMode: prepared.resolvedBridgeMode
        )
        return prepared
    }

    func restoreOfficial() throws {
        try stateLock.withLock {
            try ensureStore()

            try withCodexStateTransaction(
                files: [moaConfigURL, codexConfigURL, moaAuthURL, codexAuthURL, databaseURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                if let selectedAccount = try selectedOfficialAccount() {
                    _ = try applyOfficialAccount(id: selectedAccount.id)
                } else {
                    try syncMoaAuthSessionFromCodex(updateSelectedOfficialAccount: false)
                }

                try backupCodexFiles()
                let currentConfig = try syncedMoaConfig()
                let officialConfig = MoaCodexConfigEditor.restoringOfficialMode(from: currentConfig)
                try writeText(officialConfig, to: moaConfigURL)
                try writeText(officialConfig, to: codexConfigURL)

                var database = try loadDatabase()
                database.selectedProfileID = nil
                try saveDatabase(database)
            }
        }
    }

    func openMoaFolder() {
        _ = run("/usr/bin/open", [moaHome.path])
    }

    func openCodexFolder() {
        try? fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        _ = run("/usr/bin/open", [codexHome.path])
    }

    func bootstrap() throws {
        try ensureStore()
        try importInitialProfileIfNeeded()
    }

    func ensureStore() throws {
        try stateLock.withLock {
            try fileManager.createDirectory(at: moaHome, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)

            if !fileManager.fileExists(atPath: moaConfigURL.path) {
                if fileManager.fileExists(atPath: codexConfigURL.path) {
                    try copyFile(from: codexConfigURL, to: moaConfigURL)
                } else {
                    try writeText(Self.defaultConfig, to: moaConfigURL)
                }
            } else if try isPlaceholderConfig(at: moaConfigURL), fileManager.fileExists(atPath: codexConfigURL.path) {
                try copyFile(from: codexConfigURL, to: moaConfigURL)
            }

            if !fileManager.fileExists(atPath: moaAuthURL.path) {
                try writeAuthJSON(Self.defaultAuthJSON(), to: moaAuthURL)
            }
            try syncMoaAuthSessionFromCodex(updateSelectedOfficialAccount: false)
            try ensureOfficialAccountStore()

            if !fileManager.fileExists(atPath: databaseURL.path) {
                try saveDatabase(ProfileDatabase(selectedProfileID: nil, profiles: []))
            }
        }
    }

    func ensureOfficialAccountStore() throws {
        try fileManager.createDirectory(at: officialAuthAccountsDir, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: officialAccountsDatabaseURL.path) else {
            return
        }

        var database = CodexOfficialAccountDatabase(selectedAccountID: nil, accounts: [])
        let auth = readAuthJSON(from: moaAuthURL)
        if hasOfficialAuthSession(auth) {
            let email = officialAuthEmail(from: auth)
            var account = makeOfficialAccount(
                name: email ?? MoaL10n.text("OpenAI Current Account"),
                email: email
            )
            account.lastUsedAt = Self.isoTimestamp()
            try writeAuthJSON(auth, to: try officialAuthURL(for: account))
            database.selectedAccountID = account.id
            database.accounts = [account]
        }
        try saveOfficialAccountDatabase(database)
    }

    func importInitialProfileIfNeeded() throws {
        var database = try loadDatabase()
        guard database.profiles.isEmpty else { return }

        let config = (try? String(contentsOf: codexConfigURL, encoding: .utf8))
            ?? (try? String(contentsOf: moaConfigURL, encoding: .utf8))
            ?? ""
        let providerID = rootTomlStringValue(in: config, key: "model_provider") ?? "Current Codex"
        let providerTable = "model_providers.\(providerID)"
        let baseURL = tomlStringValue(in: config, table: providerTable, key: "base_url")
            ?? firstTomlStringValue(in: config, key: "base_url")
            ?? ""
        let apiKey = authAPIKeyValue(readAuthJSON(from: codexAuthURL)["OPENAI_API_KEY"])
            ?? tomlStringValue(in: config, table: providerTable, key: "experimental_bearer_token")
            ?? tomlStringValue(in: config, table: providerTable, key: "ANTHROPIC_AUTH_TOKEN")
            ?? firstTomlStringValue(in: config, key: "experimental_bearer_token")
            ?? ""
        guard let validatedBaseURL = try? Self.validatedProfileBaseURL(baseURL) else { return }

        let explicitName = tomlStringValue(in: config, table: providerTable, key: "name")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName: String
        if let explicitName, !explicitName.isEmpty {
            profileName = explicitName
        } else {
            profileName = Self.displayName(from: providerID)
        }
        let profile = ConfigProfile(
            id: UUID().uuidString,
            name: profileName,
            baseURL: validatedBaseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        database.selectedProfileID = profile.id
        database.profiles = [profile]
        try saveDatabase(database)
    }

    static func validatedProfileBaseURL(
        _ raw: String,
        providerKind: MoaProviderKind = .custom,
        upstreamProtocol: MoaProviderUpstreamProtocol = .responses,
        bridgeMode: MoaProviderBridgeMode = .direct
    ) throws -> String {
        if providerKind == .deepseek && upstreamProtocol == .chatCompletions && bridgeMode == .localBridge {
            return try MoaProviderBridgeEndpointNormalizer.normalizedDeepSeekChatBaseURL(raw)
        }
        return try MoaProviderBaseURLPolicy.validate(raw).normalizedString
    }

    static func validatedUpstreamBaseURL(
        _ raw: String,
        providerKind: MoaProviderKind,
        upstreamProtocol: MoaProviderUpstreamProtocol,
        bridgeMode: MoaProviderBridgeMode
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerKind == .deepseek && upstreamProtocol == .chatCompletions && bridgeMode == .localBridge {
            return try MoaProviderBridgeEndpointNormalizer.normalizedDeepSeekChatBaseURL(trimmed)
        }
        return try MoaProviderBaseURLPolicy.validate(trimmed).normalizedString
    }

    static func normalizedOptionalString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedModelList(_ models: [String]) -> [String] {
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
