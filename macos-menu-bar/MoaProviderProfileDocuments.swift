import Foundation

struct ProfileDatabase: Codable {
    var selectedProfileID: String?
    var profiles: [ConfigProfile]
}
struct CodexOfficialAccount: Codable, Equatable {
    var id: String
    var name: String
    var email: String?
    var authPath: String
    var createdAt: String
    var lastUsedAt: String?

    var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = normalizedEmail else {
            return trimmedName
        }

        if trimmedName.isEmpty || trimmedName == email || Self.isDefaultDisplayName(trimmedName) {
            return email
        }

        if trimmedName.hasSuffix("(\(email))") {
            return trimmedName
        }

        return "\(trimmedName)(\(email))"
    }

    static func isDefaultDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "OpenAI Current Account"
            || trimmed == MoaL10n.text("OpenAI Current Account")
    }

    private var normalizedEmail: String? {
        guard let email else {
            return nil
        }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CodexOfficialAccountDatabase: Codable {
    var selectedAccountID: String?
    var accounts: [CodexOfficialAccount]
}

enum CodexOfficialAccountError: LocalizedError {
    case accountNotFound
    case noSelectedAccount
    case noCurrentLogin
    case invalidAccountName
    case duplicateCurrentLogin(String)
    case invalidAuthPath(String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return MoaL10n.text("Codex official account not found.")
        case .noSelectedAccount:
            return MoaL10n.text("Select a Codex official account first.")
        case .noCurrentLogin:
            return MoaL10n.text("No Codex official login was found. Log in with Codex Official first, then add the account.")
        case .invalidAccountName:
            return MoaL10n.text("Account name is required.")
        case .duplicateCurrentLogin(let name):
            return MoaL10n.format("The current Codex official login is already saved as \"%@\".", name)
        case .invalidAuthPath(let path):
            return MoaL10n.format("The saved Codex official account path is invalid: %@", path)
        }
    }
}

struct ProviderProfileExportDocument: Codable {
    var schemaVersion: Int
    var provider: String
    var exportedAt: String
    var profiles: [ProviderProfileExportEntry]
}

struct ProviderProfileExportEntry: Codable {
    var name: String
    var baseURL: String
    var apiKey: String?
    var models: [String]?
    var oneMModels: [String]?
    var providerKind: MoaProviderKind?
    var clientTarget: MoaProviderClientTarget?
    var upstreamProtocol: MoaProviderUpstreamProtocol?
    var bridgeMode: MoaProviderBridgeMode?
    var upstreamBaseURL: String?
    var model: String?
    var testModel: String?
    var reasoningMode: MoaProviderReasoningMode?
}

enum ProviderProfileExportError: LocalizedError {
    case providerMismatch(expected: String, actual: String)
    case emptyDocument
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .providerMismatch(let expected, let actual):
            return MoaL10n.format("This import file belongs to %@ and cannot be imported into %@.", actual, expected)
        case .emptyDocument:
            return MoaL10n.text("The import file does not contain any available profiles.")
        case .invalidProfile(let name):
            return MoaL10n.format("\"%@\" has incomplete profile information. Check its name and API Base URL.", name)
        }
    }
}
