import Foundation

struct MoaUsageRemotePricing: Codable, Equatable, Sendable {
    var inputUSDPerMillion: Double
    var outputUSDPerMillion: Double
    var cacheReadUSDPerMillion: Double?
    var cacheCreationUSDPerMillion: Double?
    var thresholdTokens: Int?
    var inputUSDPerMillionAboveThreshold: Double?
    var outputUSDPerMillionAboveThreshold: Double?
    var cacheReadUSDPerMillionAboveThreshold: Double?
    var cacheCreationUSDPerMillionAboveThreshold: Double?

    func mergingMissingFields(from existing: Self) -> Self {
        Self(
            inputUSDPerMillion: inputUSDPerMillion,
            outputUSDPerMillion: outputUSDPerMillion,
            cacheReadUSDPerMillion: cacheReadUSDPerMillion ?? existing.cacheReadUSDPerMillion,
            cacheCreationUSDPerMillion: cacheCreationUSDPerMillion ?? existing.cacheCreationUSDPerMillion,
            thresholdTokens: thresholdTokens ?? existing.thresholdTokens,
            inputUSDPerMillionAboveThreshold: inputUSDPerMillionAboveThreshold ?? existing.inputUSDPerMillionAboveThreshold,
            outputUSDPerMillionAboveThreshold: outputUSDPerMillionAboveThreshold ?? existing.outputUSDPerMillionAboveThreshold,
            cacheReadUSDPerMillionAboveThreshold: cacheReadUSDPerMillionAboveThreshold ?? existing.cacheReadUSDPerMillionAboveThreshold,
            cacheCreationUSDPerMillionAboveThreshold: cacheCreationUSDPerMillionAboveThreshold ?? existing.cacheCreationUSDPerMillionAboveThreshold
        )
    }
}

struct MoaUsagePricingCatalogSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var sourceURL: String
    var fetchedAt: Date
    var models: [String: [String: MoaUsageRemotePricing]]

    init(
        sourceURL: String,
        fetchedAt: Date,
        models: [String: [String: MoaUsageRemotePricing]]
    ) {
        version = Self.currentVersion
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.models = models
    }
}

enum MoaUsagePricingCatalogUpdate: Equatable, Sendable {
    case unchanged
    case updated(added: Int, changed: Int)

    var didUpdate: Bool {
        if case .updated = self { return true }
        return false
    }
}

final class MoaUsagePricingCatalogStore: @unchecked Sendable {
    static let shared = MoaUsagePricingCatalogStore()

    private struct UpdateState: Codable {
        var lastSuccessfulCheck: Date
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var cachedSnapshot: MoaUsagePricingCatalogSnapshot?
    private var cachedURL: URL?
    private var cachedModifiedAt: Date?
    private var lastFileCheckAt: Date?

    private var catalogURL: URL {
        MoaDataRoot.currentURL(environment: environment)
            .appendingPathComponent("usage-pricing-catalog-v1.json")
    }

    private var stateURL: URL {
        // Check cadence is device-local so an iCloud state-file race cannot make one Mac
        // skip a refresh before the shared catalog has finished downloading on that device.
        MoaDataRoot.supportDirectory(environment: environment)
            .appendingPathComponent("usage-pricing-update-state.json")
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func pricing(source: MoaUsageSource, model: String) -> MoaUsageRemotePricing? {
        lock.lock()
        defer { lock.unlock() }
        return loadSnapshotIfNeeded()?.models[source.rawValue]?[model.lowercased()]
    }

    func snapshot() -> MoaUsagePricingCatalogSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return loadSnapshotIfNeeded()
    }

    func merge(_ remote: MoaUsagePricingCatalogSnapshot) throws -> MoaUsagePricingCatalogUpdate {
        lock.lock()
        defer { lock.unlock() }

        let current = loadSnapshotIfNeeded()
        var mergedModels = current?.models ?? [:]
        var added = 0
        var changed = 0

        for (source, models) in remote.models {
            var mergedSource = mergedModels[source] ?? [:]
            for (model, pricing) in models {
                if let existing = mergedSource[model] {
                    let mergedPricing = pricing.mergingMissingFields(from: existing)
                    if existing != mergedPricing {
                        mergedSource[model] = mergedPricing
                        changed += 1
                    }
                } else {
                    mergedSource[model] = pricing
                    added += 1
                }
            }
            mergedModels[source] = mergedSource
        }

        guard added > 0 || changed > 0 else {
            return .unchanged
        }

        let merged = MoaUsagePricingCatalogSnapshot(
            sourceURL: remote.sourceURL,
            fetchedAt: remote.fetchedAt,
            models: mergedModels
        )
        try write(merged, to: catalogURL)
        cachedSnapshot = merged
        cachedURL = catalogURL
        cachedModifiedAt = modificationDate(of: catalogURL)
        lastFileCheckAt = Date()
        return .updated(added: added, changed: changed)
    }

    func lastSuccessfulCheck() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(UpdateState.self, from: data)
        else {
            return nil
        }
        return state.lastSuccessfulCheck
    }

    func recordSuccessfulCheck(at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(UpdateState(lastSuccessfulCheck: date), to: stateURL)
    }

    private func loadSnapshotIfNeeded(now: Date = Date()) -> MoaUsagePricingCatalogSnapshot? {
        let url = catalogURL
        if cachedURL == url,
           let lastFileCheckAt,
           now.timeIntervalSince(lastFileCheckAt) < 60
        {
            return cachedSnapshot
        }

        let modifiedAt = modificationDate(of: url)
        lastFileCheckAt = now
        if cachedURL == url, cachedModifiedAt == modifiedAt {
            return cachedSnapshot
        }

        cachedURL = url
        cachedModifiedAt = modifiedAt
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(MoaUsagePricingCatalogSnapshot.self, from: data),
              snapshot.version == MoaUsagePricingCatalogSnapshot.currentVersion
        else {
            cachedSnapshot = nil
            return nil
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum MoaUsagePricingRemoteParser {
    enum ParseError: LocalizedError {
        case invalidCatalog

        var errorDescription: String? {
            "The remote model pricing catalog is incomplete or invalid."
        }
    }

    private struct Provider: Decodable {
        var models: [String: Model]
    }

    private struct Model: Decodable {
        var cost: Cost?
    }

    private struct Cost: Decodable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?
        var tiers: [Tier]?
        var contextOver200K: ThresholdCost?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case tiers
            case contextOver200K = "context_over_200k"
        }
    }

    private struct Tier: Decodable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?
        var tier: TierDescriptor?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case tier
        }
    }

    private struct TierDescriptor: Decodable {
        var type: String?
        var size: Int?
    }

    private struct ThresholdCost: Decodable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    static func parse(data: Data, sourceURL: URL, fetchedAt: Date) throws -> MoaUsagePricingCatalogSnapshot {
        let providers = try JSONDecoder().decode([String: Provider].self, from: data)
        let mappings: [(provider: String, source: MoaUsageSource)] = [
            ("openai", .codex),
            ("anthropic", .claude),
            ("zai", .zcode)
        ]
        var result: [String: [String: MoaUsageRemotePricing]] = [:]

        for mapping in mappings {
            guard let provider = providers[mapping.provider] else { continue }
            var prices: [String: MoaUsageRemotePricing] = [:]
            for (modelID, model) in provider.models {
                guard let cost = model.cost,
                      let input = validated(cost.input),
                      let output = validated(cost.output)
                else {
                    continue
                }

                let tier = cost.tiers?
                    .filter { $0.tier?.type == "context" && ($0.tier?.size ?? 0) > 0 }
                    .sorted { ($0.tier?.size ?? .max) < ($1.tier?.size ?? .max) }
                    .first
                let threshold = tier?.tier?.size ?? (cost.contextOver200K == nil ? nil : 200_000)
                let thresholdCost = tier.map {
                    ThresholdCost(input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite)
                } ?? cost.contextOver200K

                prices[modelID.lowercased()] = MoaUsageRemotePricing(
                    inputUSDPerMillion: input,
                    outputUSDPerMillion: output,
                    cacheReadUSDPerMillion: validated(cost.cacheRead),
                    cacheCreationUSDPerMillion: validated(cost.cacheWrite),
                    thresholdTokens: threshold,
                    inputUSDPerMillionAboveThreshold: validated(thresholdCost?.input),
                    outputUSDPerMillionAboveThreshold: validated(thresholdCost?.output),
                    cacheReadUSDPerMillionAboveThreshold: validated(thresholdCost?.cacheRead),
                    cacheCreationUSDPerMillionAboveThreshold: validated(thresholdCost?.cacheWrite)
                )
            }
            if !prices.isEmpty {
                result[mapping.source.rawValue] = prices
            }
        }

        guard (result[MoaUsageSource.codex.rawValue]?.count ?? 0) >= 5,
              (result[MoaUsageSource.claude.rawValue]?.count ?? 0) >= 3,
              (result[MoaUsageSource.zcode.rawValue]?.count ?? 0) >= 1
        else {
            throw ParseError.invalidCatalog
        }

        return MoaUsagePricingCatalogSnapshot(
            sourceURL: sourceURL.absoluteString,
            fetchedAt: fetchedAt,
            models: result
        )
    }

    private static func validated(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

final class MoaUsagePricingUpdater: Sendable {
    enum UpdateError: LocalizedError {
        case invalidResponse
        case payloadTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The model pricing server returned an invalid response."
            case .payloadTooLarge:
                return "The model pricing response exceeded the allowed size."
            }
        }
    }

    static let defaultSourceURL = URL(string: "https://models.dev/api.json")!
    private static let maximumPayloadBytes = 8 * 1024 * 1024

    let store: MoaUsagePricingCatalogStore
    let sourceURL: URL
    private let session: URLSession

    init(
        store: MoaUsagePricingCatalogStore = .shared,
        sourceURL: URL = MoaUsagePricingUpdater.defaultSourceURL,
        session: URLSession = .shared
    ) {
        self.store = store
        self.sourceURL = sourceURL
        self.session = session
    }

    func refresh(completion: @escaping (Result<MoaUsagePricingCatalogUpdate, Error>) -> Void) {
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            let result = Result<MoaUsagePricingCatalogUpdate, Error> {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data
                else {
                    throw UpdateError.invalidResponse
                }
                guard data.count <= Self.maximumPayloadBytes else {
                    throw UpdateError.payloadTooLarge
                }
                let checkedAt = Date()
                let snapshot = try MoaUsagePricingRemoteParser.parse(
                    data: data,
                    sourceURL: self.sourceURL,
                    fetchedAt: checkedAt
                )
                let update = try self.store.merge(snapshot)
                try self.store.recordSuccessfulCheck(at: checkedAt)
                return update
            }
            completion(result)
        }.resume()
    }
}

final class MoaUsagePricingUpdateCoordinator {
    var onCatalogUpdated: (() -> Void)?

    private let updater: MoaUsagePricingUpdater
    private let notificationCenter: NotificationCenter
    private var calendar: Calendar
    private var timer: Timer?
    private var timeZoneObserver: NSObjectProtocol?
    private var started = false
    private var refreshInFlight = false

    init(
        updater: MoaUsagePricingUpdater = MoaUsagePricingUpdater(),
        calendar: Calendar = .autoupdatingCurrent,
        notificationCenter: NotificationCenter = .default
    ) {
        self.updater = updater
        self.calendar = calendar
        self.notificationCenter = notificationCenter
    }

    deinit {
        timer?.invalidate()
        if let timeZoneObserver {
            notificationCenter.removeObserver(timeZoneObserver)
        }
    }

    func start(now: Date = Date()) {
        guard !started else { return }
        started = true
        timeZoneObserver = notificationCenter.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.started else { return }
            let now = Date()
            self.refreshIfNeeded(now: now)
            self.scheduleNextCheck(after: now)
        }
        refreshIfNeeded(now: now)
        scheduleNextCheck(after: now)
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        if let timeZoneObserver {
            notificationCenter.removeObserver(timeZoneObserver)
            self.timeZoneObserver = nil
        }
        onCatalogUpdated = nil
    }

    static func shouldCheck(
        now: Date,
        lastSuccessfulCheck: Date?,
        calendar: Calendar
    ) -> Bool {
        if let lastSuccessfulCheck, calendar.isDate(lastSuccessfulCheck, inSameDayAs: now) {
            return false
        }
        return now >= scheduledDate(onDayContaining: now, calendar: calendar)
    }

    static func nextScheduledDate(after date: Date, calendar: Calendar) -> Date {
        let today = scheduledDate(onDayContaining: date, calendar: calendar)
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }

    private static func scheduledDate(onDayContaining date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day], from: date)
        components.hour = 0
        components.minute = 20
        components.second = 1
        return calendar.date(from: components) ?? date
    }

    private func refreshIfNeeded(now: Date) {
        let lastSuccessfulCheck = updater.store.snapshot() == nil
            ? nil
            : updater.store.lastSuccessfulCheck()
        guard Self.shouldCheck(
            now: now,
            lastSuccessfulCheck: lastSuccessfulCheck,
            calendar: calendar
        ) else {
            return
        }
        refresh()
    }

    private func refresh() {
        guard started, !refreshInFlight else { return }
        refreshInFlight = true
        updater.refresh { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.started else { return }
                switch result {
                case .success(let update):
                    if case .updated(let added, let changed) = update {
                        NSLog("Moa model pricing updated: %d added, %d changed", added, changed)
                        self.onCatalogUpdated?()
                    }
                case .failure(let error):
                    NSLog("Moa model pricing update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func scheduleNextCheck(after date: Date) {
        timer?.invalidate()
        let next = Self.nextScheduledDate(after: date, calendar: calendar)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refreshIfNeeded(now: Date())
            self.scheduleNextCheck(after: Date())
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
