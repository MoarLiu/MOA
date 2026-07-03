import AppKit
import Foundation
import SwiftUI

final class MoaProfileActionCoordinator {
    unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
    }

    var profileController: ConfigProfileController { app.profileController }
    var claudeDesktopProfileController: ClaudeDesktopProfileController { app.claudeDesktopProfileController }
    var providerBridgeServer: MoaProviderBridgeServer { app.providerBridgeServer }
    var zcodeController: ZCodeController { app.zcodeController }
    var controller: FastStateController { app.controller }
    var statusItemText: NSMenuItem { app.statusItemText }
    var usageInsightsWindow: MoaUsageInsightsWindowController { app.usageInsightsWindow }

    func rebuildCodexProviderMenus() { app.rebuildCodexProviderMenus() }
    func rebuildClaudeProviderMenus() { app.rebuildClaudeProviderMenus() }
    func rebuildZCodeMenu() { app.rebuildZCodeMenu() }
    func refreshStatus() { app.refreshStatus() }
    func showError(_ message: String) { app.showError(message) }
    func copyToPasteboard(_ text: String) { app.copyToPasteboard(text) }
    func showEditProfilePanel(for profile: ConfigProfile) -> (name: String, baseURL: String, apiKey: String)? { app.showEditProfilePanel(for: profile) }
    func showAddClaudeDesktopProviderPanel() -> (name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String])? { app.showAddClaudeDesktopProviderPanel() }
    func showEditClaudeDesktopProviderPanel(for profile: ClaudeDesktopProviderProfile) -> (name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String])? {
        app.showEditClaudeDesktopProviderPanel(for: profile)
    }
    func showOfficialAccountNamePanel(title: String, message: String, buttonTitle: String, initialName: String) -> String? {
        app.showOfficialAccountNamePanel(title: title, message: message, buttonTitle: buttonTitle, initialName: initialName)
    }
    func showDailyUsageAlertPanel(kind: DailyUsageAlertKind) { app.showDailyUsageAlertPanel(kind: kind) }
    func migrateLegacyProviderBridgeProfilesIfNeeded() { app.migrateLegacyProviderBridgeProfilesIfNeeded() }
    func currentCodexSelectionName() -> String { app.currentCodexSelectionName() }
    func ensureProviderBridge(for profile: ConfigProfile) throws -> ConfigProfile { try app.ensureProviderBridge(for: profile) }
    func importProfiles(groupName: String, importer: (Data) throws -> Int, onImported: () -> Void) {
        app.importProfiles(groupName: groupName, importer: importer, onImported: onImported)
    }
    func exportProfiles(groupName: String, suggestedFileName: String, exporter: (Bool) throws -> Data) {
        app.exportProfiles(groupName: groupName, suggestedFileName: suggestedFileName, exporter: exporter)
    }

    func testClaudeActiveProviderAction() {
        guard let profile = try? claudeDesktopProfileController.selectedProfile() else {
            showError(MoaL10n.text("Select a Claude Desktop provider before testing."))
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Testing %@...", profile.name)
        Task.detached { [weak self] in
            guard let self else { return }
            let result: Result<ProviderConnectionTestResult, Error>
            do {
                result = .success(try await ProviderConnectionTester.testClaude(
                    baseURL: profile.baseURL,
                    apiKey: profile.apiKey,
                    models: profile.models
                ))
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                switch result {
                case .success(let testResult):
                    self.statusItemText.title = AppDelegate.statusTitle("Connection works: %@", testResult.model)
                    MoaNonBlockingAlert.present(
                        messageText: MoaL10n.text("Connection works"),
                        informativeText: MoaL10n.format("Model: %@\nEndpoint: %@", testResult.model, testResult.endpoint),
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Connection test failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func copyClaudeCodeConfigAction() {
        guard let profile = try? claudeDesktopProfileController.selectedProfile() else {
            showError(MoaL10n.text("Select a Claude Desktop provider before copying."))
            return
        }

        let model = profile.models.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? profile.models[0].trimmingCharacters(in: .whitespacesAndNewlines)
            : MoaProviderBridgeDefaults.deepSeekChatModel
        let snippet = """
        # Claude Code
        export ANTHROPIC_BASE_URL="\(AppDelegate.shellEscaped(profile.baseURL))"
        export ANTHROPIC_AUTH_TOKEN="\(AppDelegate.shellEscaped(profile.apiKey))"
        export ANTHROPIC_MODEL="\(AppDelegate.shellEscaped(model))"
        export ANTHROPIC_SMALL_FAST_MODEL="\(AppDelegate.shellEscaped(model))"
        """

        copyToPasteboard(snippet)
        statusItemText.title = AppDelegate.statusTitle("Claude Code config copied")
        MoaNonBlockingAlert.present(
            messageText: MoaL10n.text("Claude Code config copied"),
            informativeText: MoaL10n.text("The selected Claude Code environment snippet is on the clipboard."),
            tone: .success
        )
    }
    func editProfileAction(_ sender: NSMenuItem) {
        guard let profile = try? profileController.selectedProfile() else {
            showError(MoaL10n.text("Select a configuration before editing."))
            return
        }

        guard let input = showEditProfilePanel(for: profile) else {
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Saving %@...", input.name)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let updated = try self.profileController.updateProfile(
                    id: profile.id,
                    name: input.name,
                    baseURL: input.baseURL,
                    apiKey: input.apiKey
                )
                let applied = try self.profileController.applyProfile(id: updated.id)
                return try self.ensureProviderBridge(for: applied)
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let updated):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    self.statusItemText.title = AppDelegate.statusTitle("Updated %@", updated.name)
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func deleteProfileAction(_ sender: NSMenuItem) {
        guard let profile = try? profileController.selectedProfile() else {
            showError(MoaL10n.text("Select a configuration before deleting."))
            return
        }

        guard MoaNonBlockingAlert.confirm(
            messageText: MoaL10n.text("Delete Codex Config?"),
            informativeText: String(format: MoaL10n.text("Delete \"%@\" from Moa. Current Codex files will not be changed."), profile.name),
            primaryButtonTitle: MoaL10n.text("Delete"),
            tone: .danger
        ) else {
            return
        }

        do {
            let deleted = try profileController.deleteProfile(id: profile.id)
            if deleted.usesLocalProviderBridge {
                providerBridgeServer.stop()
            }
            rebuildCodexProviderMenus()
            refreshStatus()
            statusItemText.title = AppDelegate.statusTitle("Deleted %@", deleted.name)
        } catch {
            NSSound.beep()
            statusItemText.title = AppDelegate.statusTitle("Failed")
            showError(error.localizedDescription)
        }
    }

    func importCodexProfilesAction() {
        importProfiles(groupName: "Codex") { data in
            try self.profileController.importProfiles(from: data)
        } onImported: {
            self.migrateLegacyProviderBridgeProfilesIfNeeded()
            self.rebuildCodexProviderMenus()
        }
    }

    func exportCodexProfilesAction() {
        exportProfiles(groupName: "Codex", suggestedFileName: "moa-codex-profiles.json") { includeAPIKeys in
            try self.profileController.exportProfiles(includingAPIKeys: includeAPIKeys)
        }
    }

    func showCodexDailyUsageAlertAction() {
        showDailyUsageAlertPanel(kind: .codex)
        rebuildCodexProviderMenus()
    }

    func showCodexUsageDetailsAction() {
        usageInsightsWindow.show(initialSource: .codex)
    }

    func migrateCodexSessionModelProviderAction() {
        let providerID: String
        do {
            providerID = try profileController.currentCodexRootModelProvider()
        } catch {
            NSSound.beep()
            statusItemText.title = AppDelegate.statusTitle("Migration failed")
            MoaNonBlockingAlert.present(
                messageText: MoaL10n.text("Migration failed"),
                informativeText: MoaL10n.text("The current model_provider field is missing. Migration failed."),
                tone: .warning
            )
            return
        }

        guard MoaNonBlockingAlert.confirm(
            messageText: MoaL10n.text("Migrate Codex History?"),
            informativeText: MoaL10n.format("Change all historical Codex session data to model_provider = \"%@\"?", providerID),
            primaryButtonTitle: MoaL10n.text("Migrate"),
            tone: .warning
        ) else {
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Migrating Codex history...")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                self.controller.quitCodex()
                return try self.profileController.migrateCodexSessionModelProvider(to: providerID)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let migration):
                    self.statusItemText.title = AppDelegate.statusTitle("Codex history migrated")
                    MoaNonBlockingAlert.present(
                        messageText: MoaL10n.text("Codex History Migrated"),
                        informativeText: MoaL10n.format(
                            "All historical session data has been updated to model_provider = \"%@\".\nPlease restart Codex.",
                            migration.providerID
                        ),
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Migration failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func addClaudeDesktopProviderAction() {
        guard let input = showAddClaudeDesktopProviderPanel() else {
            return
        }

        do {
            _ = try claudeDesktopProfileController.addProfile(
                name: input.name,
                baseURL: input.baseURL,
                apiKey: input.apiKey,
                models: input.models,
                oneMModels: input.oneMModels
            )
            rebuildClaudeProviderMenus()
            statusItemText.title = AppDelegate.statusTitle("Added %@", input.name)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func editClaudeDesktopProviderAction(_ sender: NSMenuItem) {
        guard let profile = try? claudeDesktopProfileController.selectedProfile() else {
            showError(MoaL10n.text("Select a Claude Desktop provider before editing."))
            return
        }

        guard let input = showEditClaudeDesktopProviderPanel(for: profile) else {
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Saving %@...", input.name)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let updated = try self.claudeDesktopProfileController.updateProfile(
                    id: profile.id,
                    name: input.name,
                    baseURL: input.baseURL,
                    apiKey: input.apiKey,
                    models: input.models,
                    oneMModels: input.oneMModels
                )
                _ = try self.claudeDesktopProfileController.applyProfile(id: updated.id)
                self.claudeDesktopProfileController.reopenClaudeDesktop()
                return updated
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let updated):
                    self.rebuildClaudeProviderMenus()
                    self.statusItemText.title = AppDelegate.statusTitle("Claude Desktop using %@ · Reopened", updated.name)
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func deleteClaudeDesktopProviderAction(_ sender: NSMenuItem) {
        guard let profile = try? claudeDesktopProfileController.selectedProfile() else {
            showError(MoaL10n.text("Select a Claude Desktop provider before deleting."))
            return
        }

        guard MoaNonBlockingAlert.confirm(
            messageText: MoaL10n.text("Delete Claude Desktop Provider?"),
            informativeText: String(format: MoaL10n.text("Delete \"%@\" from Moa. If it is active, Claude Desktop will be restored to official mode."), profile.name),
            primaryButtonTitle: MoaL10n.text("Delete"),
            tone: .danger
        ) else {
            return
        }

        do {
            let deleted = try claudeDesktopProfileController.deleteProfile(id: profile.id)
            rebuildClaudeProviderMenus()
            statusItemText.title = AppDelegate.statusTitle("Deleted %@", deleted.name)
        } catch {
            NSSound.beep()
            statusItemText.title = AppDelegate.statusTitle("Failed")
            showError(error.localizedDescription)
        }
    }

    func importClaudeDesktopProfilesAction() {
        importProfiles(groupName: "Claude Desktop") { data in
            try self.claudeDesktopProfileController.importProfiles(from: data)
        } onImported: {
            self.rebuildClaudeProviderMenus()
        }
    }

    func exportClaudeDesktopProfilesAction() {
        exportProfiles(groupName: "Claude Desktop", suggestedFileName: "moa-claude-desktop-profiles.json") { includeAPIKeys in
            try self.claudeDesktopProfileController.exportProfiles(includingAPIKeys: includeAPIKeys)
        }
    }

    func showClaudeDailyUsageAlertAction() {
        showDailyUsageAlertPanel(kind: .claude)
        rebuildClaudeProviderMenus()
    }

    func showClaudeUsageDetailsAction() {
        usageInsightsWindow.show(initialSource: .claude)
    }

    func showZCodeDailyUsageAlertAction() {
        showDailyUsageAlertPanel(kind: .zcode)
        rebuildZCodeMenu()
    }

    func showZCodeUsageDetailsAction() {
        usageInsightsWindow.show(initialSource: .zcode)
    }

    func applyZCodeOfficialModeAction() {
        rebuildZCodeMenu()
    }

    func openZCodeAction() {
        zcodeController.openZCode()
    }

    func reopenZCodeAction() {
        statusItemText.title = AppDelegate.statusTitle("Reopening ZCode...")

        DispatchQueue.global(qos: .userInitiated).async {
            self.zcodeController.reopenZCode()

            DispatchQueue.main.async {
                self.statusItemText.title = AppDelegate.statusTitle("ZCode reopened")
            }
        }
    }

    func openZCodeFolderAction() {
        zcodeController.openZCodeFolder()
    }

    func applyClaudeDesktopProviderAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        statusItemText.title = AppDelegate.statusTitle("Switching Claude Desktop...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let profile = try self.claudeDesktopProfileController.applyProfile(id: id)
                self.claudeDesktopProfileController.reopenClaudeDesktop()
                return profile
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    self.rebuildClaudeProviderMenus()
                    self.statusItemText.title = AppDelegate.statusTitle("Claude Desktop using %@ · Reopened", profile.name)
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func restoreClaudeDesktopOfficialAction() {
        statusItemText.title = AppDelegate.statusTitle("Restoring Claude Desktop...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.claudeDesktopProfileController.restoreOfficial()
                self.claudeDesktopProfileController.reopenClaudeDesktop()
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.rebuildClaudeProviderMenus()
                    self.statusItemText.title = AppDelegate.statusTitle("Claude Desktop Official · Reopened")
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func openClaudeDesktopAction() {
        claudeDesktopProfileController.openClaudeDesktop()
    }

    func reopenClaudeDesktopAction() {
        statusItemText.title = AppDelegate.statusTitle("Reopening Claude Desktop...")

        DispatchQueue.global(qos: .userInitiated).async {
            self.claudeDesktopProfileController.reopenClaudeDesktop()

            DispatchQueue.main.async {
                self.statusItemText.title = AppDelegate.statusTitle("Claude Desktop reopened")
            }
        }
    }

    func openClaudeDesktopFolderAction() {
        claudeDesktopProfileController.openClaudeDesktopFolder()
    }

    func openClaudeDesktop3PFolderAction() {
        claudeDesktopProfileController.openClaudeDesktop3PFolder()
    }

    func restoreCodexOfficialAction() {
        statusItemText.title = AppDelegate.statusTitle("Restoring Codex...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.profileController.restoreOfficial()
                return self.profileController.selectedOfficialAccountName()
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let accountName):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    if let accountName {
                        self.statusItemText.title = AppDelegate.statusTitle("Codex Official · %@ · Reopened", accountName)
                    } else {
                        self.statusItemText.title = AppDelegate.statusTitle("Codex Official · Reopened")
                    }
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func applyCodexOfficialNoAccountAction() {
        statusItemText.title = AppDelegate.statusTitle("Switching Codex Official...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.profileController.applyOfficialNoAccountMode()
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let account):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    if let account {
                        self.statusItemText.title = AppDelegate.statusTitle("Codex Official · %@ · Reopened", account.displayTitle)
                    } else {
                        self.statusItemText.title = AppDelegate.statusTitle("Codex Official · %@ · Reopened", MoaL10n.text("Do Not Use Account"))
                    }
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func applyCodexOfficialAccountAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        statusItemText.title = AppDelegate.statusTitle("Switching Codex Official...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.profileController.applyOfficialAccount(id: id)
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    self.statusItemText.title = AppDelegate.statusTitle("Codex · %@ · Reopened", self.currentCodexSelectionName())
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func addCodexOfficialAccountAction() {
        guard let name = showOfficialAccountNamePanel(
            title: MoaL10n.text("Add Codex Official Account"),
            message: MoaL10n.text("Save the current Codex official login as a switchable account."),
            buttonTitle: MoaL10n.text("Add"),
            initialName: MoaL10n.text("OpenAI Current Account")
        ) else {
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Adding Codex Official account...")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.profileController.addOfficialAccountFromCurrentLogin(name: name)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let account):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    self.statusItemText.title = AppDelegate.statusTitle("Saved Codex Official account: %@", account.displayTitle)
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func renameCodexOfficialAccountAction() {
        guard let account = try? profileController.selectedOfficialAccount() else {
            showError(MoaL10n.text("Select a Codex official account first."))
            return
        }
        guard let name = showOfficialAccountNamePanel(
            title: MoaL10n.text("Rename Codex Official Account"),
            message: MoaL10n.text("Update the display name for the current Codex official account."),
            buttonTitle: MoaL10n.text("Save"),
            initialName: account.name
        ) else {
            return
        }

        do {
            let updated = try profileController.renameSelectedOfficialAccount(name: name)
            rebuildCodexProviderMenus()
            statusItemText.title = AppDelegate.statusTitle("Renamed %@", updated.displayTitle)
        } catch {
            NSSound.beep()
            statusItemText.title = AppDelegate.statusTitle("Failed")
            showError(error.localizedDescription)
        }
    }

    func deleteCodexOfficialAccountAction() {
        guard let account = try? profileController.selectedOfficialAccount() else {
            showError(MoaL10n.text("Select a Codex official account first."))
            return
        }

        guard MoaNonBlockingAlert.confirm(
            messageText: MoaL10n.text("Delete Codex Official Account?"),
            informativeText: String(format: MoaL10n.text("Delete \"%@\" from Moa's saved Codex official accounts. Current Codex files will be backed up first."), account.displayTitle),
            primaryButtonTitle: MoaL10n.text("Delete"),
            tone: .danger
        ) else {
            return
        }

        statusItemText.title = AppDelegate.statusTitle("Deleting %@...", account.displayTitle)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.profileController.deleteSelectedOfficialAccount()
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let result):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    if let activated = result.activated {
                        self.statusItemText.title = AppDelegate.statusTitle("Deleted %@ · Using %@", result.deleted.name, activated.name)
                    } else {
                        self.statusItemText.title = AppDelegate.statusTitle("Deleted %@", result.deleted.name)
                    }
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func applyProfileAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        statusItemText.title = AppDelegate.statusTitle("Switching config...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let applied = try self.profileController.applyProfile(id: id)
                return try self.ensureProviderBridge(for: applied)
            }

            switch result {
            case .success:
                self.controller.reopenCodex()
            case .failure:
                break
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    self.rebuildCodexProviderMenus()
                    self.refreshStatus()
                    self.statusItemText.title = AppDelegate.statusTitle("Using %@", profile.name)
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = AppDelegate.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
}
