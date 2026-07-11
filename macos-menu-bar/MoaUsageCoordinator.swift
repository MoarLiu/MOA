import AppKit
import Foundation

final class MoaUsageCoordinator {
    let codexScanner: CodexUsageScanner
    let claudeScanner: ClaudeUsageScanner
    let zcodeScanner: ZCodeUsageScanner
    let codexSummaryItem = NSMenuItem()
    let codexRefreshItem = NSMenuItem()
    let claudeSummaryItem = NSMenuItem()
    let claudeRefreshItem = NSMenuItem()
    let zcodeSummaryItem = NSMenuItem()
    let zcodeRefreshItem = NSMenuItem()

    var onCodexSummaryLoaded: ((CodexUsageSummary) -> Void)?
    var onClaudeSummaryLoaded: ((CodexUsageSummary) -> Void)?
    var onZCodeSummaryLoaded: ((CodexUsageSummary) -> Void)?

    private let codexSummaryView = CodexUsageSummaryMenuView()
    private let codexRefreshView = CodexUsageRefreshMenuView()
    private let claudeSummaryView = CodexUsageSummaryMenuView()
    private let claudeRefreshView = CodexUsageRefreshMenuView()
    private let zcodeSummaryView = CodexUsageSummaryMenuView()
    private let zcodeRefreshView = CodexUsageRefreshMenuView()
    private let codexQueue = DispatchQueue(label: "com.moarliu.moa.codex-usage", qos: .utility)
    private let claudeQueue = DispatchQueue(label: "com.moarliu.moa.claude-usage", qos: .utility)
    private let zcodeQueue = DispatchQueue(label: "com.moarliu.moa.zcode-usage", qos: .utility)
    private let pricingUpdateCoordinator: MoaUsagePricingUpdateCoordinator

    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private var zcodeTimer: Timer?
    private var codexSummary: CodexUsageSummary?
    private var claudeSummary: CodexUsageSummary?
    private var zcodeSummary: CodexUsageSummary?
    private var codexRefreshInFlight = false
    private var claudeRefreshInFlight = false
    private var zcodeRefreshInFlight = false

    private static let refreshMinimumDisplayDuration: TimeInterval = 0.6

    init(
        codexScanner: CodexUsageScanner = CodexUsageScanner(),
        claudeScanner: ClaudeUsageScanner = ClaudeUsageScanner(),
        zcodeScanner: ZCodeUsageScanner = ZCodeUsageScanner(),
        pricingUpdateCoordinator: MoaUsagePricingUpdateCoordinator? = nil
    ) {
        self.codexScanner = codexScanner
        self.claudeScanner = claudeScanner
        self.zcodeScanner = zcodeScanner
        self.pricingUpdateCoordinator = pricingUpdateCoordinator ?? MoaUsagePricingUpdateCoordinator()
    }

    func start() {
        pricingUpdateCoordinator.onCatalogUpdated = { [weak self] in
            self?.refreshCodex(forceRefresh: true)
            self?.refreshClaude(forceRefresh: true)
            self?.refreshZCode(forceRefresh: true)
        }
        pricingUpdateCoordinator.start()
        startCodex()
        startClaude()
        startZCode()
    }

    func stop() {
        pricingUpdateCoordinator.stop()
        codexTimer?.invalidate()
        codexTimer = nil
        claudeTimer?.invalidate()
        claudeTimer = nil
        zcodeTimer?.invalidate()
        zcodeTimer = nil
        codexRefreshView.onRefresh = nil
        claudeRefreshView.onRefresh = nil
        zcodeRefreshView.onRefresh = nil
    }

    func refreshCodex(forceRefresh: Bool) {
        guard !codexRefreshInFlight else { return }
        let startedAt = Date()
        codexRefreshInFlight = true
        codexRefreshView.setRefreshing(true)
        codexSummaryView.apply(.loading(codexSummary))

        codexQueue.async {
            let result = Result {
                try self.codexScanner.loadSummary(forceRefresh: forceRefresh)
            }

            DispatchQueue.main.async {
                let completeRefresh = {
                    self.codexRefreshInFlight = false
                    self.codexRefreshView.setRefreshing(false)

                    switch result {
                    case .success(let summary):
                        self.codexSummary = summary
                        self.codexSummaryView.apply(.loaded(summary))
                        self.onCodexSummaryLoaded?(summary)
                    case .failure(let error):
                        self.codexSummaryView.apply(.failed(self.codexSummary, error.localizedDescription))
                    }
                }
                let minimumDuration = forceRefresh ? Self.refreshMinimumDisplayDuration : 0
                let delay = max(0, minimumDuration - Date().timeIntervalSince(startedAt))
                if delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        completeRefresh()
                    }
                } else {
                    completeRefresh()
                }
            }
        }
    }

    func refreshClaude(forceRefresh: Bool) {
        guard !claudeRefreshInFlight else { return }
        let startedAt = Date()
        claudeRefreshInFlight = true
        claudeRefreshView.setRefreshing(true)
        claudeSummaryView.apply(.loading(claudeSummary))

        claudeQueue.async {
            let result = Result {
                try self.claudeScanner.loadSummary(forceRefresh: forceRefresh)
            }

            DispatchQueue.main.async {
                let completeRefresh = {
                    self.claudeRefreshInFlight = false
                    self.claudeRefreshView.setRefreshing(false)

                    switch result {
                    case .success(let summary):
                        self.claudeSummary = summary
                        self.claudeSummaryView.apply(.loaded(summary))
                        self.onClaudeSummaryLoaded?(summary)
                    case .failure(let error):
                        self.claudeSummaryView.apply(.failed(self.claudeSummary, error.localizedDescription))
                    }
                }
                let minimumDuration = forceRefresh ? Self.refreshMinimumDisplayDuration : 0
                let delay = max(0, minimumDuration - Date().timeIntervalSince(startedAt))
                if delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        completeRefresh()
                    }
                } else {
                    completeRefresh()
                }
            }
        }
    }

    func refreshZCode(forceRefresh: Bool) {
        guard !zcodeRefreshInFlight else { return }
        let startedAt = Date()
        zcodeRefreshInFlight = true
        zcodeRefreshView.setRefreshing(true)
        zcodeSummaryView.apply(.loading(zcodeSummary))

        zcodeQueue.async {
            let result = Result {
                try self.zcodeScanner.loadSummary(forceRefresh: forceRefresh)
            }

            DispatchQueue.main.async {
                let completeRefresh = {
                    self.zcodeRefreshInFlight = false
                    self.zcodeRefreshView.setRefreshing(false)

                    switch result {
                    case .success(let summary):
                        self.zcodeSummary = summary
                        self.zcodeSummaryView.apply(.loaded(summary))
                        self.onZCodeSummaryLoaded?(summary)
                    case .failure(let error):
                        self.zcodeSummaryView.apply(.failed(self.zcodeSummary, error.localizedDescription))
                    }
                }
                let minimumDuration = forceRefresh ? Self.refreshMinimumDisplayDuration : 0
                let delay = max(0, minimumDuration - Date().timeIntervalSince(startedAt))
                if delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        completeRefresh()
                    }
                } else {
                    completeRefresh()
                }
            }
        }
    }

    private func startCodex() {
        codexSummaryItem.view = codexSummaryView
        codexRefreshItem.view = codexRefreshView
        codexRefreshView.onRefresh = { [weak self] in
            self?.refreshCodex(forceRefresh: true)
        }
        codexSummaryView.apply(.idle)
        refreshCodex(forceRefresh: false)
        codexTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshCodex(forceRefresh: false)
        }
        if let codexTimer {
            RunLoop.main.add(codexTimer, forMode: .common)
        }
    }

    private func startClaude() {
        claudeSummaryItem.view = claudeSummaryView
        claudeRefreshItem.view = claudeRefreshView
        claudeRefreshView.onRefresh = { [weak self] in
            self?.refreshClaude(forceRefresh: true)
        }
        claudeSummaryView.apply(.idle)
        refreshClaude(forceRefresh: false)
        claudeTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshClaude(forceRefresh: false)
        }
        if let claudeTimer {
            RunLoop.main.add(claudeTimer, forMode: .common)
        }
    }

    private func startZCode() {
        zcodeSummaryItem.view = zcodeSummaryView
        zcodeRefreshItem.view = zcodeRefreshView
        zcodeRefreshView.onRefresh = { [weak self] in
            self?.refreshZCode(forceRefresh: true)
        }
        zcodeSummaryView.apply(.idle)
        refreshZCode(forceRefresh: false)
        zcodeTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshZCode(forceRefresh: false)
        }
        if let zcodeTimer {
            RunLoop.main.add(zcodeTimer, forMode: .common)
        }
    }
}
