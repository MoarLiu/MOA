import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = FastStateController()
    let profileController = ConfigProfileController()
    let providerBridgeProfileController = ProviderBridgeProfileController()
    let claudeDesktopProfileController = ClaudeDesktopProfileController()
    let providerBridgeServer = MoaProviderBridgeServer()
    let zcodeController = ZCodeController()
    lazy var usageCoordinator = MoaUsageCoordinator()
    let dataPackageController = MoaDataPackageController()
    let updateController = MoaUpdateController()
    lazy var mainMenuCoordinator = MoaMainMenuCoordinator(app: self)
    lazy var providerActionCoordinator = MoaProviderActionCoordinator(app: self)
    lazy var profileActionCoordinator = MoaProfileActionCoordinator(app: self)
    lazy var usageInsightsWindow = MoaUsageInsightsWindowController(
        codexScanner: usageCoordinator.codexScanner,
        claudeScanner: usageCoordinator.claudeScanner,
        zcodeScanner: usageCoordinator.zcodeScanner,
        usageAlertThresholdProvider: { kind in
            DailyUsageAlertController.threshold(for: kind)
        },
        usageAlertSettingsAction: { [weak self] kind in
            self?.showDailyUsageAlertPanel(kind: kind)
            self?.rebuildProfileMenu()
            self?.rebuildClaudeDesktopProfilesMenu()
            self?.rebuildZCodeMenu()
        }
    )

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let statusItemText = NSMenuItem(title: MoaL10n.format("Status: %@", MoaL10n.text("Ready")), action: nil, keyEquivalent: "")
    var lastMenuRefreshAt = Date.distantPast
    let menuRefreshInterval: TimeInterval = 0.75

    let codexProfilesItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
    let codexProfilesMenu = NSMenu()
    let claudeDesktopProfilesItem = NSMenuItem(title: "Claude Desktop", action: nil, keyEquivalent: "")
    let claudeDesktopProfilesMenu = NSMenu()
    let zcodeItem = NSMenuItem(title: MoaL10n.text("ZCode"), action: nil, keyEquivalent: "")
    let zcodeMenu = NSMenu(title: MoaL10n.text("ZCode"))
    let providerBridgeItem = NSMenuItem(title: MoaL10n.text("Provider Bridge"), action: nil, keyEquivalent: "")
    let providerBridgeMenu = NSMenu(title: MoaL10n.text("Provider Bridge"))

    let codexDailyUsageAlertItem = NSMenuItem(title: MoaL10n.text("Daily Usage Alert"), action: #selector(showCodexDailyUsageAlertAction), keyEquivalent: "")
    let claudeDailyUsageAlertItem = NSMenuItem(title: MoaL10n.text("Daily Usage Alert"), action: #selector(showClaudeDailyUsageAlertAction), keyEquivalent: "")
    let zcodeDailyUsageAlertItem = NSMenuItem(title: MoaL10n.text("Daily Usage Alert"), action: #selector(showZCodeDailyUsageAlertAction), keyEquivalent: "")
    let codexUsageDetailsItem = NSMenuItem(title: MoaL10n.text("Usage Details"), action: #selector(showCodexUsageDetailsAction), keyEquivalent: "")
    let claudeUsageDetailsItem = NSMenuItem(title: MoaL10n.text("Usage Details"), action: #selector(showClaudeUsageDetailsAction), keyEquivalent: "")
    let zcodeUsageDetailsItem = NSMenuItem(title: MoaL10n.text("Usage Details"), action: #selector(showZCodeUsageDetailsAction), keyEquivalent: "")
    let fastModeItem = NSMenuItem(title: MoaL10n.text("Fast Mode"), action: #selector(toggleFastModeAction(_:)), keyEquivalent: "")
    let remoteConnectionsItem = NSMenuItem(title: MoaL10n.text("Remote Connections"), action: #selector(toggleRemoteConnectionsAction(_:)), keyEquivalent: "")
    let codexOfficialItem = NSMenuItem(title: MoaL10n.text("Codex Official"), action: nil, keyEquivalent: "")
    let codexOfficialMenu = NSMenu(title: MoaL10n.text("Codex Official"))
    let codexProviderBridgeModeItem = NSMenuItem(title: MoaL10n.text("Provider Bridge Mode"), action: #selector(applyCodexProviderBridgeModeAction), keyEquivalent: "")
    let startProviderBridgeItem = NSMenuItem(title: MoaL10n.text("Start Provider Bridge"), action: #selector(startProviderBridgeAction), keyEquivalent: "")
    let stopProviderBridgeItem = NSMenuItem(title: MoaL10n.text("Stop Provider Bridge"), action: #selector(stopProviderBridgeAction), keyEquivalent: "")
    let addProviderBridgeConfigItem = NSMenuItem(title: MoaL10n.text("Add Provider Bridge Config"), action: #selector(addProviderBridgeConfigAction), keyEquivalent: "")
    let editProfileItem = NSMenuItem(title: MoaL10n.text("Edit Selected Config"), action: #selector(editProfileAction(_:)), keyEquivalent: "")
    let deleteProfileItem = NSMenuItem(title: MoaL10n.text("Delete Selected Config"), action: #selector(deleteProfileAction(_:)), keyEquivalent: "")
    let importProfilesItem = NSMenuItem(title: MoaL10n.text("Import Config"), action: #selector(importCodexProfilesAction), keyEquivalent: "")
    let exportProfilesItem = NSMenuItem(title: MoaL10n.text("Export Config"), action: #selector(exportCodexProfilesAction), keyEquivalent: "")
    let editClaudeDesktopProviderItem = NSMenuItem(title: MoaL10n.text("Edit Selected Provider"), action: #selector(editClaudeDesktopProviderAction(_:)), keyEquivalent: "")
    let deleteClaudeDesktopProviderItem = NSMenuItem(title: MoaL10n.text("Delete Selected Provider"), action: #selector(deleteClaudeDesktopProviderAction(_:)), keyEquivalent: "")
    let importClaudeDesktopProviderItem = NSMenuItem(title: MoaL10n.text("Import Provider"), action: #selector(importClaudeDesktopProfilesAction), keyEquivalent: "")
    let exportClaudeDesktopProviderItem = NSMenuItem(title: MoaL10n.text("Export Provider"), action: #selector(exportClaudeDesktopProfilesAction), keyEquivalent: "")

    let moaDataItem = NSMenuItem(title: MoaL10n.text("Moa Data"), action: nil, keyEquivalent: "")
    let moaDataMenu = NSMenu(title: MoaL10n.text("Moa Data"))
    let exportDataPackageItem = NSMenuItem(title: MoaL10n.text("Export Data Package"), action: #selector(exportDataPackageAction), keyEquivalent: "")
    let importDataPackageItem = NSMenuItem(title: MoaL10n.text("Import Data Package"), action: #selector(importDataPackageAction), keyEquivalent: "")
    let exportDiagnosticPackageItem = NSMenuItem(title: MoaL10n.text("Export Diagnostic Package"), action: #selector(exportDiagnosticPackageAction), keyEquivalent: "")
    let toggleICloudStorageItem = NSMenuItem(title: MoaL10n.text("Store Data in iCloud"), action: #selector(toggleICloudStorageAction), keyEquivalent: "")
    let openMoaDataFolderItem = NSMenuItem(title: MoaL10n.text("Open Moa Data Folder"), action: #selector(openMoaDataFolderAction), keyEquivalent: "")
    let openICloudDataFolderItem = NSMenuItem(title: MoaL10n.text("Open iCloud Data Folder"), action: #selector(openICloudDataFolderAction), keyEquivalent: "")
    let versionItem = NSMenuItem(title: "Moa", action: nil, keyEquivalent: "")

    var providerBridgeLastHealthCheckAt: Date?
    var providerBridgeLastErrorSummary = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        repairLegacyICloudDataSplitIfNeeded()
        configureApplicationMenu()
        configureStatusItem()
        configureMenu()
        refreshStatus()
        restoreActiveProviderBridgeIfNeeded()
        configureUsageAlertCallbacks()
        usageCoordinator.start()
    }

    private func configureUsageAlertCallbacks() {
        usageCoordinator.onCodexSummaryLoaded = { [weak self] summary in
            self?.maybeShowDailyUsageAlert(kind: .codex, summary: summary)
        }
        usageCoordinator.onClaudeSummaryLoaded = { [weak self] summary in
            self?.maybeShowDailyUsageAlert(kind: .claude, summary: summary)
        }
        usageCoordinator.onZCodeSummaryLoaded = { [weak self] summary in
            self?.maybeShowDailyUsageAlert(kind: .zcode, summary: summary)
        }
    }

    private func repairLegacyICloudDataSplitIfNeeded() {
        do {
            if try dataPackageController.repairLegacyICloudDataSplitIfNeeded() {
                NSLog("Moa repaired missing files from legacy iCloud data root")
            }
        } catch {
            NSLog("Moa legacy iCloud data repair failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageCoordinator.stop()
        providerBridgeServer.stop()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: MoaL10n.text("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: MoaL10n.text("Quit Moa"), action: #selector(quitAction), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: MoaL10n.text("Edit"))
        editMenu.addItem(NSMenuItem(title: MoaL10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: MoaL10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: MoaL10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: MoaL10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = MoaL10n.text("Moa - Codex, Claude, ZCode, Provider Bridge")
        }
        statusItem.menu = menu
    }

    static func versionTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let version, !version.isEmpty else {
            return "Moa"
        }

        if let build, !build.isEmpty {
            return "Moa \(version) (\(build))"
        }

        return "Moa \(version)"
    }

    static func statusTitle(_ key: String, _ arguments: CVarArg...) -> String {
        let message = String(format: MoaL10n.text(key), arguments: arguments)
        return MoaL10n.format("Status: %@", message)
    }

    static func tomlEscaped(_ value: String) -> String {
        MoaTomlEditor.escapedStringContent(value)
    }

    static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func shellEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func identifierSlug(_ value: String) -> String {
        ConfigProfileController.providerIdentifierSlug(value)
    }

    private static func makeMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MoaMenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 19, height: 19)
            image.isTemplate = true
            image.accessibilityDescription = "Moa"
            return image
        }

        let image = NSImage(size: NSSize(width: 19, height: 19))
        image.lockFocus()

        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1.0, y: 1.0, width: 17.0, height: 17.0))
        ring.lineWidth = 1.6
        ring.stroke()

        NSColor.white.setFill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 9.9, y: 15.0))
        bolt.line(to: NSPoint(x: 6.8, y: 9.0))
        bolt.line(to: NSPoint(x: 9.2, y: 9.0))
        bolt.line(to: NSPoint(x: 8.0, y: 4.0))
        bolt.line(to: NSPoint(x: 12.7, y: 10.1))
        bolt.line(to: NSPoint(x: 10.2, y: 10.1))
        bolt.line(to: NSPoint(x: 11.1, y: 15.0))
        bolt.close()
        bolt.fill()

        image.unlockFocus()
        image.isTemplate = false
        image.size = NSSize(width: 19, height: 19)
        image.accessibilityDescription = "Moa"
        return image
    }

    func applyFastMode(_ enabled: Bool) {
        fastModeItem.isEnabled = false
        fastModeItem.state = enabled ? .on : .off
        statusItemText.title = enabled ? Self.statusTitle("Turning Fast on...") : Self.statusTitle("Turning Fast off...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.controller.applyFastMode(enabled)
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.refreshStatus()
                case .failure(let error):
                    NSSound.beep()
                    self.fastModeItem.state = self.controller.isFastEnabled() ? .on : .off
                    self.fastModeItem.isEnabled = true
                    self.statusItemText.title = Self.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }

                self.fastModeItem.isEnabled = true
            }
        }
    }

    func applyRemoteConnections(_ enabled: Bool) {
        remoteConnectionsItem.isEnabled = false
        remoteConnectionsItem.state = enabled ? .on : .off
        statusItemText.title = enabled ? Self.statusTitle("Turning Remote on...") : Self.statusTitle("Turning Remote off...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.controller.applyRemoteConnections(enabled)
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.refreshStatus()
                case .failure(let error):
                    NSSound.beep()
                    self.remoteConnectionsItem.state = self.controller.isRemoteConnectionsEnabled() ? .on : .off
                    self.remoteConnectionsItem.isEnabled = true
                    self.statusItemText.title = Self.statusTitle("Failed")
                    self.showError(error.localizedDescription)
                }

                self.remoteConnectionsItem.isEnabled = true
            }
        }
    }
}
