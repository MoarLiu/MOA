import Foundation

extension ConfigProfileController {
    func officialAccounts() throws -> [CodexOfficialAccount] {
        _ = try syncMoaAuthSessionFromCodex(updateSelectedOfficialAccount: true)
        return try loadOfficialAccountDatabaseHydratingEmails().accounts
    }

    func selectedOfficialAccountID() throws -> String? {
        try loadOfficialAccountDatabase().selectedAccountID
    }

    func selectedOfficialAccountName() -> String? {
        try? selectedOfficialAccount()?.displayTitle
    }

    func selectedOfficialAccount() throws -> CodexOfficialAccount? {
        let database = try loadOfficialAccountDatabaseHydratingEmails()
        guard let selectedID = database.selectedAccountID else {
            return nil
        }
        return database.accounts.first(where: { $0.id == selectedID })
    }

    func currentOfficialLoginSaveStatus() throws -> (hasLogin: Bool, savedAccountName: String?) {
        let auth = preferredCurrentOfficialAuth()
        guard hasOfficialAuthSession(auth) else {
            return (false, nil)
        }
        return (true, try matchingOfficialAccount(for: auth)?.displayTitle)
    }

    @discardableResult
    func applyOfficialNoAccountMode() throws -> CodexOfficialAccount? {
        try stateLock.withLock {
            try ensureStore()

            return try withCodexStateTransaction(
                files: [moaConfigURL, codexConfigURL, moaAuthURL, codexAuthURL, databaseURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                let codexAuth = readAuthJSON(from: codexAuthURL)
                if hasOfficialAuthSession(codexAuth) {
                    _ = try saveCurrentOfficialLogin(activate: false)
                }

                try backupCodexFiles()
                try writeAuthJSON(Self.noAccountAuthJSON(), to: moaAuthURL)
                try writeAuthJSON(Self.noAccountAuthJSON(), to: codexAuthURL)

                var officialDatabase = try loadOfficialAccountDatabaseHydratingEmails()
                officialDatabase.selectedAccountID = nil
                try saveOfficialAccountDatabase(officialDatabase)

                let currentConfig = try syncedMoaConfig()
                var profileDatabase = try loadDatabase()
                let nextConfig = try noAccountConfig(from: currentConfig, profileDatabase: &profileDatabase)
                try writeText(nextConfig, to: moaConfigURL)
                try writeText(nextConfig, to: codexConfigURL)
                try saveDatabase(profileDatabase)
                return nil
            }
        }
    }

    @discardableResult
    func saveCurrentOfficialLoginAsSelectedAccount() throws -> CodexOfficialAccount {
        try saveCurrentOfficialLogin(activate: true)
    }

    @discardableResult
    func saveCurrentOfficialLogin(activate: Bool) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            try ensureStore()

            let auth = preferredCurrentOfficialAuth()
            guard hasOfficialAuthSession(auth) else {
                throw CodexOfficialAccountError.noCurrentLogin
            }

            if let existing = try matchingOfficialAccount(for: auth) {
                return try saveOfficialAccount(auth: auth, selecting: existing.id, activate: activate)
            }

            return try saveNewOfficialAccount(auth: auth, name: MoaL10n.text("OpenAI Current Account"), activate: activate)
        }
    }

    @discardableResult
    func saveOfficialAccount(auth: [String: Any], selecting id: String, activate: Bool = true) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            return try withCodexStateTransaction(
                files: [moaAuthURL, codexAuthURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                try backupCodexFiles()
                var officialDatabase = try loadOfficialAccountDatabase()
                guard let index = officialDatabase.accounts.firstIndex(where: { $0.id == id }) else {
                    throw CodexOfficialAccountError.accountNotFound
                }

                var account = officialDatabase.accounts[index]
                account.email = officialAuthEmail(from: auth) ?? account.email
                account.lastUsedAt = Self.isoTimestamp()
                officialDatabase.accounts[index] = account
                if activate {
                    officialDatabase.selectedAccountID = account.id
                }

                try writeAuthJSON(auth, to: try officialAuthURL(for: account))
                if activate {
                    try writeAuthJSON(auth, to: moaAuthURL)
                    try copyFile(from: moaAuthURL, to: codexAuthURL)
                }
                try saveOfficialAccountDatabase(officialDatabase)
                return account
            }
        }
    }

    @discardableResult
    func saveNewOfficialAccount(auth: [String: Any], name: String, activate: Bool = true) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            return try withCodexStateTransaction(
                files: [moaAuthURL, codexAuthURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                try backupCodexFiles()
                var officialDatabase = try loadOfficialAccountDatabase()
                let email = officialAuthEmail(from: auth)
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let accountName = CodexOfficialAccount.isDefaultDisplayName(trimmedName) ? (email ?? trimmedName) : trimmedName
                var account = makeOfficialAccount(name: accountName, email: email)

                try writeAuthJSON(auth, to: try officialAuthURL(for: account))
                account.lastUsedAt = Self.isoTimestamp()
                officialDatabase.accounts.append(account)
                if activate {
                    try writeAuthJSON(auth, to: moaAuthURL)
                    try copyFile(from: moaAuthURL, to: codexAuthURL)
                    officialDatabase.selectedAccountID = account.id
                }
                try saveOfficialAccountDatabase(officialDatabase)
                return account
            }
        }
    }

    @discardableResult
    func addOfficialAccountFromCurrentLogin(name: String) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            try ensureStore()

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw CodexOfficialAccountError.invalidAccountName
            }

            let auth = preferredCurrentOfficialAuth()
            guard hasOfficialAuthSession(auth) else {
                throw CodexOfficialAccountError.noCurrentLogin
            }
            if let existing = try matchingOfficialAccount(for: auth) {
                throw CodexOfficialAccountError.duplicateCurrentLogin(existing.displayTitle)
            }

            return try saveNewOfficialAccount(auth: auth, name: trimmedName)
        }
    }

    @discardableResult
    func applyOfficialAccount(id: String) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            try ensureStore()
            return try withCodexStateTransaction(
                files: [moaAuthURL, codexAuthURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                try syncMoaAuthSessionFromCodex(updateSelectedOfficialAccount: true)
                var officialDatabase = try loadOfficialAccountDatabase()
                guard let index = officialDatabase.accounts.firstIndex(where: { $0.id == id }) else {
                    throw CodexOfficialAccountError.accountNotFound
                }
                try backupCodexFiles()

                var account = officialDatabase.accounts[index]
                let authURL = try officialAuthURL(for: account)
                let auth = readAuthJSON(from: authURL)
                guard fileManager.fileExists(atPath: authURL.path), hasOfficialAuthSession(auth) else {
                    throw CodexOfficialAccountError.noCurrentLogin
                }

                try copyFile(from: authURL, to: moaAuthURL)
                try copyFile(from: authURL, to: codexAuthURL)
                account.email = officialAuthEmail(from: auth) ?? account.email
                account.lastUsedAt = Self.isoTimestamp()
                officialDatabase.accounts[index] = account
                officialDatabase.selectedAccountID = account.id
                try saveOfficialAccountDatabase(officialDatabase)
                return account
            }
        }
    }

    @discardableResult
    func renameSelectedOfficialAccount(name: String) throws -> CodexOfficialAccount {
        try stateLock.withLock {
            try ensureStore()

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw CodexOfficialAccountError.invalidAccountName
            }

            var database = try loadOfficialAccountDatabaseHydratingEmails()
            guard let selectedID = database.selectedAccountID else {
                throw CodexOfficialAccountError.noSelectedAccount
            }
            guard let index = database.accounts.firstIndex(where: { $0.id == selectedID }) else {
                throw CodexOfficialAccountError.accountNotFound
            }

            database.accounts[index].name = trimmedName
            let account = database.accounts[index]
            try saveOfficialAccountDatabase(database)
            return account
        }
    }

    struct DeletedOfficialAccountResult {
        var deleted: CodexOfficialAccount
        var activated: CodexOfficialAccount?
    }

    @discardableResult
    func deleteSelectedOfficialAccount() throws -> DeletedOfficialAccountResult {
        try stateLock.withLock {
            try ensureStore()
            return try withCodexStateTransaction(
                files: [moaAuthURL, codexAuthURL, officialAccountsDatabaseURL],
                includeOfficialAuthDirectory: true
            ) {
                try syncMoaAuthSessionFromCodex(updateSelectedOfficialAccount: true)
                var database = try loadOfficialAccountDatabaseHydratingEmails()
                guard let selectedID = database.selectedAccountID else {
                    throw CodexOfficialAccountError.noSelectedAccount
                }
                guard let index = database.accounts.firstIndex(where: { $0.id == selectedID }) else {
                    throw CodexOfficialAccountError.accountNotFound
                }

                try backupCodexFiles()
                let deleted = database.accounts.remove(at: index)
                let deletedAuthURL = try officialAuthURL(for: deleted)
                try? fileManager.removeItem(at: deletedAuthURL)

                let activated: CodexOfficialAccount?
                if database.accounts.isEmpty {
                    database.selectedAccountID = nil
                    activated = nil
                } else {
                    let nextIndex = min(index, database.accounts.count - 1)
                    var next = database.accounts[nextIndex]
                    next.lastUsedAt = Self.isoTimestamp()
                    database.accounts[nextIndex] = next
                    database.selectedAccountID = next.id
                    let nextAuthURL = try officialAuthURL(for: next)
                    try copyFile(from: nextAuthURL, to: moaAuthURL)
                    try copyFile(from: nextAuthURL, to: codexAuthURL)
                    activated = next
                }

                try saveOfficialAccountDatabase(database)
                return DeletedOfficialAccountResult(deleted: deleted, activated: activated)
            }
        }
    }
    func makeOfficialAccount(name: String, email: String? = nil) -> CodexOfficialAccount {
        let id = UUID().uuidString
        let now = Self.isoTimestamp()
        return CodexOfficialAccount(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email,
            authPath: "\(Self.officialAuthAccountsRelativePath)/\(id).json",
            createdAt: now,
            lastUsedAt: now
        )
    }

    func officialAuthURL(for account: CodexOfficialAccount) throws -> URL {
        let expectedPath = "\(Self.officialAuthAccountsRelativePath)/\(account.id).json"
        guard account.authPath == expectedPath,
              UUID(uuidString: account.id) != nil
        else {
            throw CodexOfficialAccountError.invalidAuthPath(account.authPath)
        }

        let codexAuthDirectory = moaHome.appendingPathComponent("codex-auth", isDirectory: true).standardizedFileURL
        let base = officialAuthAccountsDir.standardizedFileURL
        for directory in [codexAuthDirectory, base] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw CodexOfficialAccountError.invalidAuthPath(account.authPath)
            }
        }
        let candidate = moaHome
            .appendingPathComponent(account.authPath)
            .standardizedFileURL
        if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw CodexOfficialAccountError.invalidAuthPath(account.authPath)
        }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.deletingLastPathComponent() == base,
              candidate.path.hasPrefix(basePath)
        else {
            throw CodexOfficialAccountError.invalidAuthPath(account.authPath)
        }
        return candidate
    }

    func preferredCurrentOfficialAuth() -> [String: Any] {
        let codexAuth = readAuthJSON(from: codexAuthURL)
        if hasOfficialAuthSession(codexAuth) {
            return codexAuth
        }
        return readAuthJSON(from: moaAuthURL)
    }

    func hasOfficialAuthSession(_ auth: [String: Any]) -> Bool {
        auth["tokens"] != nil
    }

    func matchingOfficialAccount(for auth: [String: Any]) throws -> CodexOfficialAccount? {
        guard hasOfficialAuthSession(auth) else {
            return nil
        }

        let database = try loadOfficialAccountDatabase()
        let refreshToken = officialAuthRefreshToken(from: auth)
        let comparableAuth = officialAuthComparableData(from: auth)
        let currentEmail = officialAuthEmail(from: auth)

        for account in database.accounts {
            let savedAuth = readAuthJSON(from: try officialAuthURL(for: account))
            if let refreshToken, officialAuthRefreshToken(from: savedAuth) == refreshToken {
                return account.withEmailIfAvailable(officialAuthEmail(from: savedAuth) ?? currentEmail)
            }
            guard let comparableAuth,
                  let savedComparableAuth = officialAuthComparableData(from: savedAuth)
            else {
                continue
            }
            if comparableAuth == savedComparableAuth {
                return account.withEmailIfAvailable(officialAuthEmail(from: savedAuth) ?? currentEmail)
            }
        }

        if let currentEmail {
            for account in database.accounts {
                let savedAuth = readAuthJSON(from: try officialAuthURL(for: account))
                let savedEmail = officialAuthEmail(from: savedAuth) ?? account.email
                if savedEmail?.caseInsensitiveCompare(currentEmail) == .orderedSame {
                    return account.withEmailIfAvailable(currentEmail)
                }
            }
        }

        return nil
    }

    func officialAuthRefreshToken(from auth: [String: Any]) -> String? {
        guard let tokens = auth["tokens"] as? [String: Any] else {
            return nil
        }
        return authStringValue(tokens["refresh_token"])
            ?? authStringValue(tokens["refreshToken"])
    }

    func officialAuthComparableData(from auth: [String: Any]) -> Data? {
        var comparable = normalizedMoaAuth(auth)
        comparable["last_refresh"] = nil
        return normalizedJSONData(for: comparable)
    }

    func loadOfficialAccountDatabaseHydratingEmails() throws -> CodexOfficialAccountDatabase {
        var database = try loadOfficialAccountDatabase()
        var changed = false

        for index in database.accounts.indices {
            let auth = readAuthJSON(from: try officialAuthURL(for: database.accounts[index]))
            guard let email = officialAuthEmail(from: auth),
                  database.accounts[index].email != email
            else {
                continue
            }

            database.accounts[index].email = email
            changed = true
        }

        if changed {
            try saveOfficialAccountDatabase(database)
        }

        return database
    }

    func officialAuthEmail(from auth: [String: Any]) -> String? {
        guard let tokens = auth["tokens"] as? [String: Any] else {
            return nil
        }

        for key in ["email", "preferred_username", "upn"] {
            if let email = normalizedOfficialAuthEmail(tokens[key]) {
                return email
            }
        }

        guard let idToken = authStringValue(tokens["id_token"]) ?? authStringValue(tokens["idToken"]) else {
            return nil
        }

        return officialAuthEmail(fromJWT: idToken)
    }

    func officialAuthEmail(fromJWT idToken: String) -> String? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let payloadData = base64URLDecodedData(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        for key in ["email", "preferred_username", "upn"] {
            if let email = normalizedOfficialAuthEmail(payload[key]) {
                return email
            }
        }

        return nil
    }

    func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }

        return Data(base64Encoded: base64)
    }

    func normalizedOfficialAuthEmail(_ value: Any?) -> String? {
        guard let email = authStringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.contains("@")
        else {
            return nil
        }

        return email
    }

    func noAccountConfig(from currentConfig: String, profileDatabase: inout ProfileDatabase) throws -> String {
        if let selectedID = profileDatabase.selectedProfileID,
           let selectedIndex = profileDatabase.profiles.firstIndex(where: { $0.id == selectedID && !$0.usesLocalProviderBridge }) {
            let prepared = try preparedProfileForApply(profileDatabase.profiles[selectedIndex])
            profileDatabase.profiles[selectedIndex] = prepared
            return generateConfig(currentConfig, selecting: prepared)
        }

        guard let firstDirectProfileIndex = profileDatabase.profiles.firstIndex(where: { !$0.usesLocalProviderBridge }) else {
            profileDatabase.selectedProfileID = nil
            return currentConfig
        }

        let prepared = try preparedProfileForApply(profileDatabase.profiles[firstDirectProfileIndex])
        profileDatabase.profiles[firstDirectProfileIndex] = prepared
        profileDatabase.selectedProfileID = prepared.id
        return generateConfig(currentConfig, selecting: prepared)
    }
}

private extension CodexOfficialAccount {
    func withEmailIfAvailable(_ email: String?) -> CodexOfficialAccount {
        guard let email, self.email != email else {
            return self
        }

        var account = self
        account.email = email
        return account
    }
}
