import AppKit
import Foundation
import SwiftUI

extension AppDelegate {
    func rebuildCodexProviderMenus() {
        rebuildProfileMenu()
        rebuildProviderBridgeMenu()
    }

    func currentCodexSelectionName() -> String {
        if let profileName = profileController.selectedProfileName() {
            return profileName
        }

        if let accountName = profileController.selectedOfficialAccountName() {
            return "\(MoaL10n.text("Official")) · \(accountName)"
        }

        return MoaL10n.text("Official")
    }

    func rebuildClaudeProviderMenus() {
        rebuildClaudeDesktopProfilesMenu()
        rebuildProviderBridgeMenu()
    }

    func providerBridgeProfiles() throws -> [ConfigProfile] {
        try providerBridgeProfileController.profiles()
    }

    func migrateLegacyProviderBridgeProfilesIfNeeded() {
        do {
            _ = try profileController.moveLocalBridgeProfiles(to: providerBridgeProfileController)
        } catch {
            providerBridgeLastErrorSummary = error.localizedDescription
        }
    }

    func preferredProviderBridgeProfile() throws -> ConfigProfile {
        let profiles = try providerBridgeProfiles()
        guard !profiles.isEmpty else {
            throw NSError(
                domain: "Moa",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: MoaL10n.text("Add a Provider Bridge config first.")]
            )
        }

        if let selectedID = try? providerBridgeProfileController.selectedProfileID(),
           let selectedBridgeProfile = profiles.first(where: { $0.id == selectedID }) {
            return selectedBridgeProfile
        }

        let snapshot = providerBridgeServer.snapshot()
        if let runningProfileID = snapshot.profileID,
           let runningProfile = profiles.first(where: { $0.id == runningProfileID }) {
            return runningProfile
        }

        return profiles[0]
    }

    func preparedProviderBridgeRuntimeProfile() throws -> ConfigProfile {
        let profile = try preferredProviderBridgeProfile()
        return try preparedProviderBridgeRuntimeProfile(profile)
    }

    func preparedProviderBridgeRuntimeProfile(_ source: ConfigProfile) throws -> ConfigProfile {
        var profile = source
        if (try? providerBridgeProfileController.selectedProfileID()) != profile.id {
            profile = try providerBridgeProfileController.applyProfile(id: profile.id)
        }
        if profile.bridgeToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            profile = try providerBridgeProfileController.updateBridgeRuntime(id: profile.id, token: MoaProviderBridgeToken.generate())
        }
        if profile.bridgePort == nil {
            profile = try providerBridgeProfileController.updateBridgeRuntime(id: profile.id, port: MoaProviderBridgeDefaults.defaultPort)
        }
        return profile
    }

    @discardableResult
    func syncCodexProviderBridgeModeIfNeeded(_ profile: ConfigProfile, reopenCodex: Bool = false) throws -> ConfigProfile {
        guard profileController.isProviderBridgeModeSelected() else {
            return profile
        }
        let synced = try profileController.applyProviderBridgeGateway(profile: profile)
        if reopenCodex {
            controller.reopenCodex()
        }
        return synced
    }
}
