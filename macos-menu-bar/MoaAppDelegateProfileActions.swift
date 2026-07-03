import AppKit
import Foundation
import SwiftUI

extension AppDelegate {
    @objc func testClaudeActiveProviderAction() { profileActionCoordinator.testClaudeActiveProviderAction() }
    @objc func copyClaudeCodeConfigAction() { profileActionCoordinator.copyClaudeCodeConfigAction() }
    @objc func editProfileAction(_ sender: NSMenuItem) { profileActionCoordinator.editProfileAction(sender) }
    @objc func deleteProfileAction(_ sender: NSMenuItem) { profileActionCoordinator.deleteProfileAction(sender) }
    @objc func importCodexProfilesAction() { profileActionCoordinator.importCodexProfilesAction() }
    @objc func exportCodexProfilesAction() { profileActionCoordinator.exportCodexProfilesAction() }
    @objc func showCodexDailyUsageAlertAction() { profileActionCoordinator.showCodexDailyUsageAlertAction() }
    @objc func showCodexUsageDetailsAction() { profileActionCoordinator.showCodexUsageDetailsAction() }
    @objc func migrateCodexSessionModelProviderAction() { profileActionCoordinator.migrateCodexSessionModelProviderAction() }
    @objc func addClaudeDesktopProviderAction() { profileActionCoordinator.addClaudeDesktopProviderAction() }
    @objc func editClaudeDesktopProviderAction(_ sender: NSMenuItem) { profileActionCoordinator.editClaudeDesktopProviderAction(sender) }
    @objc func deleteClaudeDesktopProviderAction(_ sender: NSMenuItem) { profileActionCoordinator.deleteClaudeDesktopProviderAction(sender) }
    @objc func importClaudeDesktopProfilesAction() { profileActionCoordinator.importClaudeDesktopProfilesAction() }
    @objc func exportClaudeDesktopProfilesAction() { profileActionCoordinator.exportClaudeDesktopProfilesAction() }
    @objc func showClaudeDailyUsageAlertAction() { profileActionCoordinator.showClaudeDailyUsageAlertAction() }
    @objc func showClaudeUsageDetailsAction() { profileActionCoordinator.showClaudeUsageDetailsAction() }
    @objc func showZCodeDailyUsageAlertAction() { profileActionCoordinator.showZCodeDailyUsageAlertAction() }
    @objc func showZCodeUsageDetailsAction() { profileActionCoordinator.showZCodeUsageDetailsAction() }
    @objc func applyZCodeOfficialModeAction() { profileActionCoordinator.applyZCodeOfficialModeAction() }
    @objc func openZCodeAction() { profileActionCoordinator.openZCodeAction() }
    @objc func reopenZCodeAction() { profileActionCoordinator.reopenZCodeAction() }
    @objc func openZCodeFolderAction() { profileActionCoordinator.openZCodeFolderAction() }
    @objc func applyClaudeDesktopProviderAction(_ sender: NSMenuItem) { profileActionCoordinator.applyClaudeDesktopProviderAction(sender) }
    @objc func restoreClaudeDesktopOfficialAction() { profileActionCoordinator.restoreClaudeDesktopOfficialAction() }
    @objc func openClaudeDesktopAction() { profileActionCoordinator.openClaudeDesktopAction() }
    @objc func reopenClaudeDesktopAction() { profileActionCoordinator.reopenClaudeDesktopAction() }
    @objc func openClaudeDesktopFolderAction() { profileActionCoordinator.openClaudeDesktopFolderAction() }
    @objc func openClaudeDesktop3PFolderAction() { profileActionCoordinator.openClaudeDesktop3PFolderAction() }
    @objc func restoreCodexOfficialAction() { profileActionCoordinator.restoreCodexOfficialAction() }
    @objc func applyCodexOfficialNoAccountAction() { profileActionCoordinator.applyCodexOfficialNoAccountAction() }
    @objc func applyCodexOfficialAccountAction(_ sender: NSMenuItem) { profileActionCoordinator.applyCodexOfficialAccountAction(sender) }
    @objc func addCodexOfficialAccountAction() { profileActionCoordinator.addCodexOfficialAccountAction() }
    @objc func renameCodexOfficialAccountAction() { profileActionCoordinator.renameCodexOfficialAccountAction() }
    @objc func deleteCodexOfficialAccountAction() { profileActionCoordinator.deleteCodexOfficialAccountAction() }
    @objc func applyProfileAction(_ sender: NSMenuItem) { profileActionCoordinator.applyProfileAction(sender) }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportProfiles(groupName: String, suggestedFileName: String, exporter: (Bool) throws -> Data) {
        switch MoaProviderProfileTransfer.exportProfiles(
            groupName: groupName,
            suggestedFileName: suggestedFileName,
            exporter: exporter
        ) {
        case .success:
            statusItemText.title = Self.statusTitle("Exported %@", groupName)
        case .failure(let error):
            NSSound.beep()
            statusItemText.title = Self.statusTitle("Failed")
            showError(error.localizedDescription)
        case nil:
            return
        }
    }

    func importProfiles(groupName: String, importer: (Data) throws -> Int, onImported: () -> Void) {
        switch MoaProviderProfileTransfer.importProfiles(groupName: groupName, importer: importer) {
        case .success(let count):
            onImported()
            statusItemText.title = Self.statusTitle("Imported %d %@ profiles", count, groupName)
        case .failure(let error):
            NSSound.beep()
            statusItemText.title = Self.statusTitle("Failed")
            showError(error.localizedDescription)
        case nil:
            return
        }
    }

    func showDailyUsageAlertPanel(kind: DailyUsageAlertKind) {
        let title = String(format: MoaL10n.text("Set %@ Daily Usage Alert"), kind.displayName)
        let initialThreshold = DailyUsageAlertController.threshold(for: kind)
        let initialText = initialThreshold.map { String(format: "%.2f", $0) } ?? ""

        var didSave = false
        var savedThreshold: Double?

        MoaGlassModalHost.runModal(width: 500, fallbackHeight: 360, title: title) {
            DailyUsageAlertFormView(
                title: title,
                initialEnabled: initialThreshold != nil,
                initialThresholdText: initialText,
                onSave: { threshold in
                    didSave = true
                    savedThreshold = threshold
                    NSApp.stopModal(withCode: .OK)
                },
                onCancel: {
                    NSApp.stopModal(withCode: .cancel)
                }
            )
        }

        guard didSave else { return }
        DailyUsageAlertController.setThreshold(savedThreshold, for: kind)
        statusItemText.title = Self.statusTitle("Updated %@ daily usage alert", kind.displayName)
    }

    func maybeShowDailyUsageAlert(kind: DailyUsageAlertKind, summary: CodexUsageSummary) {
        guard DailyUsageAlertController.shouldAlert(kind: kind, summary: summary),
              let threshold = DailyUsageAlertController.threshold(for: kind)
        else {
            return
        }

        NSSound.beep()
        statusItemText.title = Self.statusTitle("%@ daily usage reached threshold", kind.displayName)
        MoaNonBlockingAlert.present(
            messageText: String(format: MoaL10n.text("%@ daily usage reached the alert threshold"), kind.displayName),
            informativeText: String(format: MoaL10n.text("Today's local estimate is %@, reaching your threshold of %@."), DailyUsageAlertController.currency(summary.todayCostUSD), DailyUsageAlertController.currency(threshold)),
            tone: .warning
        )
    }

    func showAddProfilePanel() -> (name: String, baseURL: String, apiKey: String)? {
        MoaProviderProfilePanels.showAddCodexProfile()
    }

    func showEditProfilePanel(for profile: ConfigProfile) -> (name: String, baseURL: String, apiKey: String)? {
        MoaProviderProfilePanels.showEditCodexProfile(for: profile)
    }

    func showOfficialAccountNamePanel(
        title: String,
        message: String,
        buttonTitle: String,
        initialName: String
    ) -> String? {
        MoaProviderProfilePanels.showOfficialAccountName(
            title: title,
            message: message,
            buttonTitle: buttonTitle,
            initialName: initialName
        )
    }

    func showAddClaudeDesktopProviderPanel() -> (name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String])? {
        MoaProviderProfilePanels.showAddClaudeDesktopProvider()
    }

    func showEditClaudeDesktopProviderPanel(
        for profile: ClaudeDesktopProviderProfile
    ) -> (name: String, baseURL: String, apiKey: String, models: [String], oneMModels: [String])? {
        MoaProviderProfilePanels.showEditClaudeDesktopProvider(for: profile)
    }

    func showError(_ message: String) {
        MoaNonBlockingAlert.present(messageText: "Moa", informativeText: message, tone: .warning)
    }
}
