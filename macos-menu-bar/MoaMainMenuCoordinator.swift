import AppKit
import Foundation

final class MoaMainMenuCoordinator {
    unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
    }

    func configureMenu() {
        app.menu.delegate = app

        app.versionItem.title = AppDelegate.versionTitle()
        app.versionItem.isEnabled = false
        app.menu.addItem(app.versionItem)
        app.statusItemText.isEnabled = false
        app.menu.addItem(app.statusItemText)
        app.menu.addItem(NSMenuItem.separator())

        app.codexProfilesItem.submenu = app.codexProfilesMenu
        app.menu.addItem(app.codexProfilesItem)
        app.claudeDesktopProfilesItem.submenu = app.claudeDesktopProfilesMenu
        app.menu.addItem(app.claudeDesktopProfilesItem)
        app.zcodeItem.submenu = app.zcodeMenu
        app.menu.addItem(app.zcodeItem)
        app.providerBridgeItem.submenu = app.providerBridgeMenu
        app.menu.addItem(app.providerBridgeItem)
        app.menu.addItem(NSMenuItem.separator())

        app.moaDataItem.submenu = app.moaDataMenu
        configureMoaDataMenu()
        app.menu.addItem(app.moaDataItem)
        app.menu.addItem(NSMenuItem.separator())

        let checkUpdateItem = NSMenuItem(title: MoaL10n.text("Check Update"), action: #selector(AppDelegate.checkUpdateAction), keyEquivalent: "")
        checkUpdateItem.target = app
        app.menu.addItem(checkUpdateItem)
        app.menu.addItem(NSMenuItem.separator())

        app.menu.addItem(NSMenuItem(title: MoaL10n.text("Quit Moa"), action: #selector(AppDelegate.quitAction), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        let now = Date()
        guard now.timeIntervalSince(app.lastMenuRefreshAt) >= app.menuRefreshInterval else {
            return
        }
        app.lastMenuRefreshAt = now
        rebuildProfileMenu()
        rebuildClaudeDesktopProfilesMenu()
        rebuildZCodeMenu()
        rebuildProviderBridgeMenu()
        configureMoaDataMenu()
        refreshStatus()
    }

    func configureMoaDataMenu() {
        app.moaDataMenu.removeAllItems()
        for item in [
            app.exportDataPackageItem,
            app.importDataPackageItem,
            NSMenuItem.separator(),
            app.toggleICloudStorageItem,
            app.openMoaDataFolderItem,
            app.openICloudDataFolderItem,
            NSMenuItem.separator(),
            app.exportDiagnosticPackageItem
        ] {
            app.moaDataMenu.addItem(item)
        }

        for item in [
            app.exportDataPackageItem,
            app.importDataPackageItem,
            app.exportDiagnosticPackageItem,
            app.toggleICloudStorageItem,
            app.openMoaDataFolderItem,
            app.openICloudDataFolderItem
        ] {
            item.target = app
        }

        app.toggleICloudStorageItem.title = app.dataPackageController.isICloudStorageEnabled()
            ? MoaL10n.text("Move Data Back to This Mac")
            : MoaL10n.text("Store Data in iCloud")
        app.toggleICloudStorageItem.state = app.dataPackageController.isICloudStorageEnabled() ? .on : .off
    }

    func refreshStatus() {
        let tier = app.controller.serviceTier()
        let isFast = tier == "fast"
        let remoteEnabled = app.controller.isRemoteConnectionsEnabled()
        app.fastModeItem.state = isFast ? .on : .off
        app.remoteConnectionsItem.state = remoteEnabled ? .on : .off

        if let button = app.statusItem.button {
            button.toolTip = MoaL10n.text("Moa - Codex, Claude, ZCode, Provider Bridge")
        }
    }

    func rebuildZCodeMenu() {
        app.zcodeMenu.removeAllItems()
        app.zcodeItem.title = MoaL10n.text("ZCode")
        app.zcodeMenu.title = MoaL10n.text("ZCode")

        app.zcodeMenu.addItem(app.usageCoordinator.zcodeSummaryItem)
        app.zcodeMenu.addItem(app.usageCoordinator.zcodeRefreshItem)
        app.zcodeDailyUsageAlertItem.target = app
        app.zcodeDailyUsageAlertItem.title = DailyUsageAlertController.menuTitle(for: .zcode)
        app.zcodeMenu.addItem(app.zcodeDailyUsageAlertItem)
        app.zcodeUsageDetailsItem.target = app
        app.zcodeMenu.addItem(app.zcodeUsageDetailsItem)
        app.zcodeMenu.addItem(NSMenuItem.separator())

        let zcodeOfficialItem = NSMenuItem(title: MoaL10n.text("ZCode Official Mode"), action: #selector(AppDelegate.applyZCodeOfficialModeAction), keyEquivalent: "")
        zcodeOfficialItem.target = app
        zcodeOfficialItem.state = .on
        app.zcodeMenu.addItem(zcodeOfficialItem)
        app.zcodeMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: MoaL10n.text("Open ZCode"), action: #selector(AppDelegate.openZCodeAction), keyEquivalent: "")
        openItem.target = app
        app.zcodeMenu.addItem(openItem)

        let reopenItem = NSMenuItem(title: MoaL10n.text("Reopen ZCode"), action: #selector(AppDelegate.reopenZCodeAction), keyEquivalent: "")
        reopenItem.target = app
        app.zcodeMenu.addItem(reopenItem)

        let openFolderItem = NSMenuItem(title: MoaL10n.text("Open ZCode Folder"), action: #selector(AppDelegate.openZCodeFolderAction), keyEquivalent: "")
        openFolderItem.target = app
        app.zcodeMenu.addItem(openFolderItem)
    }

    func rebuildProfileMenu() {
        app.codexProfilesMenu.removeAllItems()
        app.codexProfilesMenu.autoenablesItems = false

        let selectedID: String?
        let profiles: [ConfigProfile]
        let officialAccounts: [CodexOfficialAccount]
        let providerBridgeProfiles: [ConfigProfile]
        let selectedOfficialAccountID: String?
        let currentOfficialLoginSaveStatus: (hasLogin: Bool, savedAccountName: String?)
        do {
            selectedID = try app.profileController.selectedProfileID()
            profiles = try app.profileController.profiles()
            officialAccounts = try app.profileController.officialAccounts()
            providerBridgeProfiles = try app.providerBridgeProfiles()
            selectedOfficialAccountID = try app.profileController.selectedOfficialAccountID()
            currentOfficialLoginSaveStatus = try app.profileController.currentOfficialLoginSaveStatus()
        } catch {
            showDataLoadFailure(error, source: "Codex", in: app.codexProfilesMenu)
            app.codexProfilesItem.title = "Codex · \(MoaL10n.text("Load Failed"))"
            return
        }
        let directProfiles = profiles.filter { !$0.usesLocalProviderBridge }
        let isProviderBridgeMode = app.profileController.isProviderBridgeModeSelected()
        let selectedName = app.currentCodexSelectionName()
        app.codexProfilesItem.title = "Codex · \(selectedName)"
        let isNoOfficialAccountMode = selectedOfficialAccountID == nil

        app.codexProfilesMenu.addItem(app.usageCoordinator.codexSummaryItem)
        app.codexProfilesMenu.addItem(app.usageCoordinator.codexRefreshItem)
        app.codexDailyUsageAlertItem.target = app
        app.codexDailyUsageAlertItem.title = DailyUsageAlertController.menuTitle(for: .codex)
        app.codexProfilesMenu.addItem(app.codexDailyUsageAlertItem)
        app.codexUsageDetailsItem.target = app
        app.codexProfilesMenu.addItem(app.codexUsageDetailsItem)
        app.codexProfilesMenu.addItem(NSMenuItem.separator())

        app.codexOfficialMenu.removeAllItems()
        app.codexOfficialMenu.autoenablesItems = false
        app.codexOfficialMenu.title = MoaL10n.text("Codex Official")
        app.codexOfficialItem.title = MoaL10n.text("Codex Official")
        app.codexOfficialItem.target = nil
        app.codexOfficialItem.action = nil
        app.codexOfficialItem.isEnabled = true
        app.codexOfficialItem.state = selectedID == nil ? .on : .off
        app.codexOfficialItem.submenu = app.codexOfficialMenu
        let useOfficialModeItem = NSMenuItem(title: MoaL10n.text("Use Codex Official Mode"), action: #selector(AppDelegate.restoreCodexOfficialAction), keyEquivalent: "")
        useOfficialModeItem.target = app
        useOfficialModeItem.state = selectedID == nil ? .on : .off
        useOfficialModeItem.isEnabled = !isNoOfficialAccountMode
        app.codexOfficialMenu.addItem(useOfficialModeItem)
        app.codexOfficialMenu.addItem(NSMenuItem.separator())

        let noAccountItem = NSMenuItem(title: MoaL10n.text("Do Not Use Account"), action: #selector(AppDelegate.applyCodexOfficialNoAccountAction), keyEquivalent: "")
        noAccountItem.target = app
        noAccountItem.state = isNoOfficialAccountMode ? .on : .off
        app.codexOfficialMenu.addItem(noAccountItem)

        if officialAccounts.isEmpty {
            let emptyItem = NSMenuItem(title: MoaL10n.text("No Official Accounts"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            app.codexOfficialMenu.addItem(emptyItem)
        } else {
            for account in officialAccounts {
                let item = NSMenuItem(title: account.displayTitle, action: #selector(AppDelegate.applyCodexOfficialAccountAction(_:)), keyEquivalent: "")
                item.target = app
                item.representedObject = account.id
                item.state = account.id == selectedOfficialAccountID ? .on : .off
                app.codexOfficialMenu.addItem(item)
            }
        }
        app.codexOfficialMenu.addItem(NSMenuItem.separator())
        let addOfficialTitle: String
        let canAddOfficialAccount: Bool
        if let savedAccountName = currentOfficialLoginSaveStatus.savedAccountName {
            addOfficialTitle = MoaL10n.format("Current Login Saved as %@", savedAccountName)
            canAddOfficialAccount = false
        } else if currentOfficialLoginSaveStatus.hasLogin {
            addOfficialTitle = MoaL10n.text("Add Current Login as Account")
            canAddOfficialAccount = true
        } else {
            addOfficialTitle = MoaL10n.text("No Current Official Login")
            canAddOfficialAccount = false
        }
        let addOfficialAccountItem = NSMenuItem(title: addOfficialTitle, action: #selector(AppDelegate.addCodexOfficialAccountAction), keyEquivalent: "")
        addOfficialAccountItem.target = app
        addOfficialAccountItem.isEnabled = canAddOfficialAccount
        app.codexOfficialMenu.addItem(addOfficialAccountItem)
        let renameOfficialAccountItem = NSMenuItem(title: MoaL10n.text("Rename Current Account"), action: #selector(AppDelegate.renameCodexOfficialAccountAction), keyEquivalent: "")
        renameOfficialAccountItem.target = app
        renameOfficialAccountItem.isEnabled = selectedOfficialAccountID != nil
        app.codexOfficialMenu.addItem(renameOfficialAccountItem)
        let deleteOfficialAccountItem = NSMenuItem(title: MoaL10n.text("Delete Current Account"), action: #selector(AppDelegate.deleteCodexOfficialAccountAction), keyEquivalent: "")
        deleteOfficialAccountItem.target = app
        deleteOfficialAccountItem.isEnabled = selectedOfficialAccountID != nil
        app.codexOfficialMenu.addItem(deleteOfficialAccountItem)
        app.codexProfilesMenu.addItem(app.codexOfficialItem)

        app.codexProviderBridgeModeItem.target = app
        app.codexProviderBridgeModeItem.title = MoaL10n.text("Provider Bridge Mode")
        app.codexProviderBridgeModeItem.state = isProviderBridgeMode ? .on : .off
        app.codexProviderBridgeModeItem.isEnabled = !providerBridgeProfiles.isEmpty
        app.codexProfilesMenu.addItem(app.codexProviderBridgeModeItem)

        if directProfiles.isEmpty {
            let emptyItem = NSMenuItem(title: MoaL10n.text("No Saved Configs"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            app.codexProfilesMenu.addItem(emptyItem)
        } else {
            app.codexProfilesMenu.addItem(NSMenuItem.separator())
            for profile in directProfiles {
                let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.applyProfileAction(_:)), keyEquivalent: "")
                item.representedObject = profile.id
                item.state = profile.id == selectedID ? .on : .off
                app.codexProfilesMenu.addItem(item)
            }
        }

        app.codexProfilesMenu.addItem(NSMenuItem.separator())
        app.codexProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Add Config"), action: #selector(AppDelegate.addProfileAction), keyEquivalent: ""))
        app.codexProfilesMenu.addItem(providerPresetSubmenuItem(
            title: MoaL10n.text("Add Responses Preset"),
            presets: MoaProviderPresets.responsesNative + MoaProviderPresets.responsesGateways
        ))
        app.importProfilesItem.target = app
        app.importProfilesItem.title = MoaL10n.text("Import Config")
        app.codexProfilesMenu.addItem(app.importProfilesItem)
        app.exportProfilesItem.target = app
        app.exportProfilesItem.title = MoaL10n.text("Export Config")
        app.exportProfilesItem.isEnabled = !profiles.isEmpty
        app.codexProfilesMenu.addItem(app.exportProfilesItem)
        app.editProfileItem.target = app
        app.editProfileItem.title = MoaL10n.text("Edit Selected Config")
        app.editProfileItem.isEnabled = selectedID != nil && directProfiles.contains { $0.id == selectedID }
        app.editProfileItem.representedObject = selectedID
        app.codexProfilesMenu.addItem(app.editProfileItem)
        app.deleteProfileItem.target = app
        app.deleteProfileItem.title = MoaL10n.text("Delete Selected Config")
        app.deleteProfileItem.isEnabled = app.editProfileItem.isEnabled
        app.deleteProfileItem.representedObject = selectedID
        app.codexProfilesMenu.addItem(app.deleteProfileItem)
        app.codexProfilesMenu.addItem(NSMenuItem.separator())

        app.fastModeItem.target = app
        app.fastModeItem.title = MoaL10n.text("Fast Mode")
        app.codexProfilesMenu.addItem(app.fastModeItem)
        app.remoteConnectionsItem.target = app
        app.remoteConnectionsItem.title = MoaL10n.text("Remote Connections")
        app.codexProfilesMenu.addItem(app.remoteConnectionsItem)
        app.codexProfilesMenu.addItem(NSMenuItem.separator())

        app.codexProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open Codex"), action: #selector(AppDelegate.openCodexAction), keyEquivalent: ""))
        app.codexProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Reopen Codex"), action: #selector(AppDelegate.reopenCodexAction), keyEquivalent: ""))
        let migrateHistoryProviderItem = NSMenuItem(title: MoaL10n.text("Migrate History model_provider"), action: #selector(AppDelegate.migrateCodexSessionModelProviderAction), keyEquivalent: "")
        migrateHistoryProviderItem.target = app
        app.codexProfilesMenu.addItem(migrateHistoryProviderItem)
        app.codexProfilesMenu.addItem(NSMenuItem.separator())
        app.codexProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open Moa Folder"), action: #selector(AppDelegate.openMoaFolderAction), keyEquivalent: ""))
        app.codexProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open Codex Folder"), action: #selector(AppDelegate.openCodexFolderAction), keyEquivalent: ""))
    }

    func rebuildProviderBridgeMenu() {
        app.providerBridgeMenu.removeAllItems()
        app.providerBridgeItem.title = MoaL10n.text("Provider Bridge")
        app.providerBridgeMenu.title = MoaL10n.text("Provider Bridge")

        let profiles: [ConfigProfile]
        let selectedID: String?
        do {
            profiles = try app.providerBridgeProfileController.profiles()
            selectedID = try app.providerBridgeProfileController.selectedProfileID()
        } catch {
            showDataLoadFailure(error, source: MoaL10n.text("Provider Bridge"), in: app.providerBridgeMenu)
            app.providerBridgeItem.title = "\(MoaL10n.text("Provider Bridge")) · \(MoaL10n.text("Load Failed"))"
            return
        }
        let bridgeSnapshot = app.providerBridgeServer.snapshot()

        if profiles.isEmpty {
            let emptyItem = NSMenuItem(title: MoaL10n.text("No Saved Configs"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            app.providerBridgeMenu.addItem(emptyItem)
        } else {
            for profile in profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.applyProviderBridgeProfileAction(_:)), keyEquivalent: "")
                item.target = app
                item.representedObject = profile.id
                item.state = profile.id == selectedID ? .on : .off
                app.providerBridgeMenu.addItem(item)
            }
        }

        app.providerBridgeMenu.addItem(NSMenuItem.separator())

        app.startProviderBridgeItem.target = app
        app.startProviderBridgeItem.title = MoaL10n.text("Start Provider Bridge")
        app.startProviderBridgeItem.isEnabled = selectedID != nil && !bridgeSnapshot.isRunning
        app.providerBridgeMenu.addItem(app.startProviderBridgeItem)

        app.stopProviderBridgeItem.target = app
        app.stopProviderBridgeItem.title = MoaL10n.text("Stop Provider Bridge")
        app.stopProviderBridgeItem.isEnabled = bridgeSnapshot.isRunning
        app.providerBridgeMenu.addItem(app.stopProviderBridgeItem)

        app.addProviderBridgeConfigItem.target = app
        app.addProviderBridgeConfigItem.title = MoaL10n.text("Add Provider Bridge Config")
        app.providerBridgeMenu.addItem(app.addProviderBridgeConfigItem)
    }

    func providerPresetSubmenuItem(title: String, presets: [MoaProviderPreset]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for preset in presets {
            let item = NSMenuItem(title: preset.name, action: #selector(AppDelegate.addProviderPresetAction(_:)), keyEquivalent: "")
            item.target = app
            item.representedObject = preset.id
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    func rebuildClaudeDesktopProfilesMenu() {
        app.claudeDesktopProfilesMenu.removeAllItems()

        let selectedID: String?
        let profiles: [ClaudeDesktopProviderProfile]
        do {
            selectedID = try app.claudeDesktopProfileController.selectedProfileID()
            profiles = try app.claudeDesktopProfileController.profiles()
        } catch {
            showDataLoadFailure(error, source: "Claude Desktop", in: app.claudeDesktopProfilesMenu)
            app.claudeDesktopProfilesItem.title = "Claude Desktop · \(MoaL10n.text("Load Failed"))"
            return
        }
        let selectedName = app.claudeDesktopProfileController.selectedProfileName() ?? MoaL10n.text("Official")
        app.claudeDesktopProfilesItem.title = "Claude Desktop · \(selectedName)"

        app.claudeDesktopProfilesMenu.addItem(app.usageCoordinator.claudeSummaryItem)
        app.claudeDesktopProfilesMenu.addItem(app.usageCoordinator.claudeRefreshItem)
        app.claudeDailyUsageAlertItem.target = app
        app.claudeDailyUsageAlertItem.title = DailyUsageAlertController.menuTitle(for: .claude)
        app.claudeDesktopProfilesMenu.addItem(app.claudeDailyUsageAlertItem)
        app.claudeUsageDetailsItem.target = app
        app.claudeDesktopProfilesMenu.addItem(app.claudeUsageDetailsItem)
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem.separator())

        let officialItem = NSMenuItem(title: MoaL10n.text("Claude Desktop Official"), action: #selector(AppDelegate.restoreClaudeDesktopOfficialAction), keyEquivalent: "")
        officialItem.state = selectedID == nil ? .on : .off
        app.claudeDesktopProfilesMenu.addItem(officialItem)

        if !profiles.isEmpty {
            app.claudeDesktopProfilesMenu.addItem(NSMenuItem.separator())
            for profile in profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.applyClaudeDesktopProviderAction(_:)), keyEquivalent: "")
                item.representedObject = profile.id
                item.state = profile.id == selectedID ? .on : .off
                app.claudeDesktopProfilesMenu.addItem(item)
            }
        }

        app.claudeDesktopProfilesMenu.addItem(NSMenuItem.separator())
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Add Provider"), action: #selector(AppDelegate.addClaudeDesktopProviderAction), keyEquivalent: ""))
        app.importClaudeDesktopProviderItem.target = app
        app.importClaudeDesktopProviderItem.title = MoaL10n.text("Import Provider")
        app.claudeDesktopProfilesMenu.addItem(app.importClaudeDesktopProviderItem)
        app.exportClaudeDesktopProviderItem.target = app
        app.exportClaudeDesktopProviderItem.title = MoaL10n.text("Export Provider")
        app.exportClaudeDesktopProviderItem.isEnabled = !profiles.isEmpty
        app.claudeDesktopProfilesMenu.addItem(app.exportClaudeDesktopProviderItem)

        app.editClaudeDesktopProviderItem.target = app
        app.editClaudeDesktopProviderItem.title = MoaL10n.text("Edit Selected Provider")
        app.editClaudeDesktopProviderItem.isEnabled = selectedID != nil && profiles.contains { $0.id == selectedID }
        app.editClaudeDesktopProviderItem.representedObject = selectedID
        app.claudeDesktopProfilesMenu.addItem(app.editClaudeDesktopProviderItem)

        app.deleteClaudeDesktopProviderItem.target = app
        app.deleteClaudeDesktopProviderItem.title = MoaL10n.text("Delete Selected Provider")
        app.deleteClaudeDesktopProviderItem.isEnabled = app.editClaudeDesktopProviderItem.isEnabled
        app.deleteClaudeDesktopProviderItem.representedObject = selectedID
        app.claudeDesktopProfilesMenu.addItem(app.deleteClaudeDesktopProviderItem)

        app.claudeDesktopProfilesMenu.addItem(NSMenuItem.separator())
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open Claude Desktop"), action: #selector(AppDelegate.openClaudeDesktopAction), keyEquivalent: ""))
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Reopen Claude Desktop"), action: #selector(AppDelegate.reopenClaudeDesktopAction), keyEquivalent: ""))
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open Claude Folder"), action: #selector(AppDelegate.openClaudeDesktopFolderAction), keyEquivalent: ""))
        app.claudeDesktopProfilesMenu.addItem(NSMenuItem(title: MoaL10n.text("Open 3P Profile Folder"), action: #selector(AppDelegate.openClaudeDesktop3PFolderAction), keyEquivalent: ""))
    }

    private func showDataLoadFailure(_ error: Error, source: String, in menu: NSMenu) {
        let item = NSMenuItem(
            title: MoaL10n.format("Unable to load %@ data: %@", source, error.localizedDescription),
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        menu.addItem(item)
        app.statusItemText.title = AppDelegate.statusTitle("Load Failed")
    }
}
