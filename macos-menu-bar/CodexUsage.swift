import AppKit
import Foundation

struct CodexUsageSummary {
    let todayCostUSD: Double
    let totalCostUSD: Double
    let todayTokens: Int
    let totalTokens: Int
    let cacheHitPercent: Double
    let topModelName: String?
    let topModelTokens: Int
    let topModelPercent: Double
    let updatedAt: Date
}

enum MoaUsageSource: String, Codable, CaseIterable, Hashable {
    case codex
    case claude
    case zcode

    var title: String {
        switch self {
        case .codex:
            return MoaL10n.text("Codex")
        case .claude:
            return MoaL10n.text("Claude Desktop")
        case .zcode:
            return MoaL10n.text("ZCode")
        }
    }
}

struct MoaUsageDetailRow: Identifiable, Codable, Hashable {
    var source: MoaUsageSource
    var dayKey: String
    var model: String
    var input: Int
    var cachedInput: Int
    var cacheReadInput: Int
    var cacheCreationInput: Int
    var output: Int
    var costUSD: Double
    var pricingModel: String
    var usesFallbackPricing: Bool

    var id: String {
        "\(source.rawValue)|\(dayKey)|\(model)"
    }

    var totalTokens: Int {
        input + cachedInput + cacheReadInput + cacheCreationInput + output
    }

    var cacheTokens: Int {
        cachedInput + cacheReadInput + cacheCreationInput
    }

    var cacheHitTokens: Int {
        cachedInput + cacheReadInput
    }

    mutating func merge(_ row: MoaUsageDetailRow) {
        input += row.input
        cachedInput += row.cachedInput
        cacheReadInput += row.cacheReadInput
        cacheCreationInput += row.cacheCreationInput
        output += row.output
        costUSD += row.costUSD
        usesFallbackPricing = usesFallbackPricing || row.usesFallbackPricing
        if pricingModel.isEmpty {
            pricingModel = row.pricingModel
        }
    }
}

struct MoaUsageReport {
    var rows: [MoaUsageDetailRow]
    var generatedAt: Date

    var totalCostUSD: Double {
        rows.reduce(0) { $0 + $1.costUSD }
    }

    var totalTokens: Int {
        rows.reduce(0) { $0 + $1.totalTokens }
    }

    var cacheHitTokens: Int {
        rows.reduce(0) { $0 + $1.cacheHitTokens }
    }

    var cacheHitPercent: Double {
        guard totalTokens > 0 else { return 0 }
        return Double(cacheHitTokens) / Double(totalTokens) * 100
    }

    var fallbackRows: [MoaUsageDetailRow] {
        var seen = Set<String>()
        return rows
            .filter(\.usesFallbackPricing)
            .sorted { lhs, rhs in
                if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
                return lhs.model < rhs.model
            }
            .filter { row in
                let key = "\(row.source.rawValue)|\(row.model)|\(row.pricingModel)"
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    func filtered(source: MoaUsageSource?, recentDays: Int, now: Date = Date()) -> MoaUsageReport {
        let todayKey = Self.dayKey(from: now)
        let since = Calendar.current.date(byAdding: .day, value: -(max(1, recentDays) - 1), to: now) ?? now
        let sinceKey = Self.dayKey(from: since)
        return MoaUsageReport(
            rows: rows.filter { row in
                let sourceMatches = source.map { row.source == $0 } ?? true
                return sourceMatches && row.dayKey >= sinceKey && row.dayKey <= todayKey
            },
            generatedAt: generatedAt
        )
    }

    static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }
}

struct MoaUsagePricingOverride: Identifiable, Codable, Equatable {
    var source: MoaUsageSource
    var model: String
    var inputUSDPerMillion: Double
    var outputUSDPerMillion: Double
    var cacheReadUSDPerMillion: Double?
    var cacheCreationUSDPerMillion: Double?
    var updatedAt: Date

    var id: String {
        "\(source.rawValue)|\(model)"
    }
}

final class MoaUsagePricingOverrideController {
    private struct Payload: Codable {
        var overrides: [MoaUsagePricingOverride]
    }

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var cachedOverrides: [MoaUsagePricingOverride]?
    private var cachedModified: Date?

    private var url: URL {
        MoaDataRoot.currentURL(environment: environment)
            .appendingPathComponent("usage-pricing-overrides.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    func overrides() -> [MoaUsagePricingOverride] {
        lock.lock()
        defer { lock.unlock() }

        let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cachedOverrides, cachedModified == modified {
            return cachedOverrides
        }

        let loaded: [MoaUsagePricingOverride]
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            loaded = []
            cachedOverrides = loaded
            cachedModified = modified
            return loaded
        }
        if let payload = try? decoder.decode(Payload.self, from: data) {
            loaded = payload.overrides
        } else {
            loaded = (try? decoder.decode([MoaUsagePricingOverride].self, from: data)) ?? []
        }
        cachedOverrides = loaded
        cachedModified = modified
        return loaded
    }

    func override(source: MoaUsageSource, model: String) -> MoaUsagePricingOverride? {
        let normalized = normalizedModel(source: source, model: model)
        return overrides().first { $0.source == source && $0.model == normalized }
    }

    func upsert(
        source: MoaUsageSource,
        model: String,
        inputUSDPerMillion: Double,
        outputUSDPerMillion: Double,
        cacheReadUSDPerMillion: Double?,
        cacheCreationUSDPerMillion: Double?
    ) throws {
        let normalized = normalizedModel(source: source, model: model)
        var overrides = overrides().filter { !($0.source == source && $0.model == normalized) }
        overrides.append(MoaUsagePricingOverride(
            source: source,
            model: normalized,
            inputUSDPerMillion: max(0, inputUSDPerMillion),
            outputUSDPerMillion: max(0, outputUSDPerMillion),
            cacheReadUSDPerMillion: cacheReadUSDPerMillion.map { max(0, $0) },
            cacheCreationUSDPerMillion: cacheCreationUSDPerMillion.map { max(0, $0) },
            updatedAt: Date()
        ))
        try save(overrides)
    }

    func remove(source: MoaUsageSource, model: String) throws {
        let normalized = normalizedModel(source: source, model: model)
        try save(overrides().filter { !($0.source == source && $0.model == normalized) })
    }

    func codexCostEstimate(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> MoaUsagePricing.CostEstimate? {
        guard let override = override(source: .codex, model: model) else { return nil }
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = override.cacheReadUSDPerMillion
            ?? MoaUsagePricing.codexCacheReadUSDPerMillion(model: override.model, inputTokens: inputTokens)
            ?? override.inputUSDPerMillion
        let cost = Self.cost(tokens: nonCached, perMillion: override.inputUSDPerMillion)
            + Self.cost(tokens: cached, perMillion: cachedRate)
            + Self.cost(tokens: outputTokens, perMillion: override.outputUSDPerMillion)
        return MoaUsagePricing.CostEstimate(
            costUSD: cost,
            normalizedModel: override.model,
            pricingModel: MoaL10n.text("Custom"),
            usesFallbackPricing: false
        )
    }

    func claudeCostEstimate(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> MoaUsagePricing.CostEstimate? {
        guard let override = override(source: .claude, model: model) else { return nil }
        let promptTokens = max(0, inputTokens) + max(0, cacheReadInputTokens) + max(0, cacheCreationInputTokens)
        let readRate = override.cacheReadUSDPerMillion
            ?? MoaUsagePricing.claudeCacheReadUSDPerMillion(model: override.model, promptTokens: promptTokens)
            ?? override.inputUSDPerMillion
        let creationRate = override.cacheCreationUSDPerMillion
            ?? MoaUsagePricing.claudeCacheCreationUSDPerMillion(model: override.model, promptTokens: promptTokens)
            ?? override.inputUSDPerMillion
        let cost = Self.cost(tokens: inputTokens, perMillion: override.inputUSDPerMillion)
            + Self.cost(tokens: cacheReadInputTokens, perMillion: readRate)
            + Self.cost(tokens: cacheCreationInputTokens, perMillion: creationRate)
            + Self.cost(tokens: outputTokens, perMillion: override.outputUSDPerMillion)
        return MoaUsagePricing.CostEstimate(
            costUSD: cost,
            normalizedModel: override.model,
            pricingModel: MoaL10n.text("Custom"),
            usesFallbackPricing: false
        )
    }

    func zcodeCostEstimate(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> MoaUsagePricing.CostEstimate? {
        guard let override = override(source: .zcode, model: model) else { return nil }
        let promptTokens = max(0, inputTokens) + max(0, cacheReadInputTokens) + max(0, cacheCreationInputTokens)
        let readRate = override.cacheReadUSDPerMillion
            ?? MoaUsagePricing.zcodeCacheReadUSDPerMillion(model: override.model, promptTokens: promptTokens)
            ?? override.inputUSDPerMillion
        let creationRate = override.cacheCreationUSDPerMillion
            ?? MoaUsagePricing.zcodeCacheCreationUSDPerMillion(model: override.model, promptTokens: promptTokens)
            ?? override.inputUSDPerMillion
        let cost = Self.cost(tokens: inputTokens, perMillion: override.inputUSDPerMillion)
            + Self.cost(tokens: cacheReadInputTokens, perMillion: readRate)
            + Self.cost(tokens: cacheCreationInputTokens, perMillion: creationRate)
            + Self.cost(tokens: outputTokens, perMillion: override.outputUSDPerMillion)
        return MoaUsagePricing.CostEstimate(
            costUSD: cost,
            normalizedModel: override.model,
            pricingModel: MoaL10n.text("Custom"),
            usesFallbackPricing: false
        )
    }

    private func save(_ overrides: [MoaUsagePricingOverride]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Payload(overrides: overrides.sorted { $0.id < $1.id })
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lock.lock()
        cachedOverrides = payload.overrides
        cachedModified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lock.unlock()
    }

    private func normalizedModel(source: MoaUsageSource, model: String) -> String {
        switch source {
        case .codex:
            return MoaUsagePricing.normalizeCodexModel(model)
        case .claude:
            return MoaUsagePricing.normalizeClaudeModel(model)
        case .zcode:
            return MoaUsagePricing.normalizeZCodeModel(model)
        }
    }

    private static func cost(tokens: Int, perMillion: Double) -> Double {
        Double(max(0, tokens)) * max(0, perMillion) / 1_000_000
    }
}

enum MoaUsageReportExporter {
    static func csv(report: MoaUsageReport) -> String {
        let header = [
            "date", "source", "model", "input_tokens", "cache_tokens", "output_tokens",
            "total_tokens", "cost_usd", "pricing_model", "fallback_pricing"
        ]
        let rows = report.rows.sorted(by: rowSort).map { row in
            [
                row.dayKey,
                row.source.title,
                row.model,
                String(row.input),
                String(row.cacheTokens),
                String(row.output),
                String(row.totalTokens),
                String(format: "%.6f", row.costUSD),
                row.pricingModel,
                row.usesFallbackPricing ? "true" : "false"
            ].map(csvEscape).joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
    }

    static func markdown(report: MoaUsageReport) -> String {
        var lines = [
            "# Moa Usage Report",
            "",
            "- Generated: \(ISO8601DateFormatter().string(from: report.generatedAt))",
            "- Total cost: \(currency(report.totalCostUSD))",
            "- Total tokens: \(report.totalTokens)",
            "",
            "| Date | Source | Model | Input | Cache | Output | Total | Cost | Pricing | Fallback |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |"
        ]
        for row in report.rows.sorted(by: rowSort) {
            lines.append("| \(md(row.dayKey)) | \(md(row.source.title)) | \(md(row.model)) | \(row.input) | \(row.cacheTokens) | \(row.output) | \(row.totalTokens) | \(currency(row.costUSD)) | \(md(row.pricingModel)) | \(row.usesFallbackPricing ? "Yes" : "No") |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func rowSort(_ lhs: MoaUsageDetailRow, _ rhs: MoaUsageDetailRow) -> Bool {
        if lhs.dayKey != rhs.dayKey { return lhs.dayKey > rhs.dayKey }
        if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.model < rhs.model
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func md(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

enum CodexUsageMenuState {
    case idle
    case loading(CodexUsageSummary?)
    case loaded(CodexUsageSummary)
    case failed(CodexUsageSummary?, String)
}

final class CodexUsageScanner {
    private struct TokenUsage: Codable, Equatable {
        var input: Int = 0
        var cached: Int = 0
        var output: Int = 0
        var costUSD: Double = 0

        var totalTokens: Int {
            input + output
        }

        mutating func add(input: Int, cached: Int, output: Int, costUSD: Double) {
            self.input += input
            self.cached += cached
            self.output += output
            self.costUSD += costUSD
        }
    }

    private struct CachedFile: Codable, Equatable {
        var mtime: TimeInterval
        var size: Int64
        var days: [String: [String: TokenUsage]]
    }

    private struct Cache: Codable, Equatable {
        var version: Int
        var codexHomePath: String
        var files: [String: CachedFile]
    }

    private struct RunningTotals {
        var input: Int = 0
        var cached: Int = 0
        var output: Int = 0
    }

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let codexHome: URL
    private let pricingOverrides: MoaUsagePricingOverrideController
    private let cacheLock = NSLock()

    private var cacheURL: URL {
        MoaDataRoot.currentURL(environment: environment)
            .appendingPathComponent("codex-usage-cache-v1.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let codexHomePath = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.codex"
        codexHome = URL(fileURLWithPath: codexHomePath).standardizedFileURL
        pricingOverrides = MoaUsagePricingOverrideController(environment: environment)
    }

    func loadSummary(forceRefresh: Bool = false, now: Date = Date()) throws -> CodexUsageSummary {
        summary(from: try loadReport(forceRefresh: forceRefresh, now: now), now: now)
    }

    func loadReport(
        forceRefresh: Bool = false,
        now: Date = Date(),
        persistCache: Bool = true
    ) throws -> MoaUsageReport {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        let files = sessionFiles(in: roots)
        let validPaths = Set(files.map(\.path))
        var cache = lockedLoadCache()
        if cache.version != 1 || cache.codexHomePath != codexHome.path {
            cache = Cache(version: 1, codexHomePath: codexHome.path, files: [:])
        }
        let originalCache = cache

        var nextFiles: [String: CachedFile] = [:]
        for fileURL in files {
            guard let metadata = fileMetadata(for: fileURL) else { continue }
            let path = fileURL.path
            if !forceRefresh,
               let cached = cache.files[path],
               cached.mtime == metadata.mtime,
               cached.size == metadata.size
            {
                nextFiles[path] = cached
                continue
            }

            let days = parseSessionFile(fileURL)
            nextFiles[path] = CachedFile(mtime: metadata.mtime, size: metadata.size, days: days)
        }

        cache.files = nextFiles.filter { validPaths.contains($0.key) }
        if persistCache && cache != originalCache {
            lockedSaveCache(cache)
        }
        return report(from: cache, now: now)
    }

    private func sessionFiles(in roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
                files.append(fileURL.standardizedFileURL)
            }
        }
        return files
    }

    private func fileMetadata(for url: URL) -> (mtime: TimeInterval, size: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate?.timeIntervalSince1970,
              let size = values.fileSize
        else { return nil }
        return (mtime, Int64(size))
    }

    private func parseSessionFile(_ fileURL: URL) -> [String: [String: TokenUsage]] {
        var days: [String: [String: TokenUsage]] = [:]
        var currentModel: String?
        var previousTotals: RunningTotals?

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard input > 0 || cached > 0 || output > 0 else { return }
            let normalizedModel = CodexUsagePricing.normalizeModel(model)
            let clampedCached = min(max(0, cached), max(0, input))
            days[dayKey, default: [:]][normalizedModel, default: TokenUsage()]
                .add(input: input, cached: clampedCached, output: output, costUSD: 0)
        }

        do {
            try scanLines(fileURL: fileURL) { line in
                guard shouldInspect(line) else { return }
                if line.count > 512 * 1024 {
                    if line.containsASCII(#""type":"turn_context""#),
                       let model = extractStringField("model", fromPrefixOf: line)
                    {
                        currentModel = model
                    }
                    return
                }

                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let type = object["type"] as? String
                else { return }

                if type == "turn_context" {
                    if let payload = object["payload"] as? [String: Any] {
                        currentModel = payload["model"] as? String
                            ?? (payload["info"] as? [String: Any])?["model"] as? String
                    }
                    return
                }

                guard type == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let timestamp = object["timestamp"] as? String,
                      let dayKey = Self.dayKey(from: timestamp)
                else { return }

                let info = payload["info"] as? [String: Any]
                let model = currentModel
                    ?? info?["model"] as? String
                    ?? info?["model_name"] as? String
                    ?? payload["model"] as? String
                    ?? object["model"] as? String
                    ?? "gpt-5"
                let total = info?["total_token_usage"] as? [String: Any]
                let last = info?["last_token_usage"] as? [String: Any]
                let delta: RunningTotals?

                if let last {
                    delta = RunningTotals(
                        input: max(0, Self.intValue(last["input_tokens"])),
                        cached: max(0, Self.intValue(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                        output: max(0, Self.intValue(last["output_tokens"])))
                } else if let total {
                    let current = RunningTotals(
                        input: max(0, Self.intValue(total["input_tokens"])),
                        cached: max(0, Self.intValue(total["cached_input_tokens"] ?? total["cache_read_input_tokens"])),
                        output: max(0, Self.intValue(total["output_tokens"])))
                    let previous = previousTotals ?? RunningTotals()
                    if current.input < previous.input || current.cached < previous.cached || current.output < previous.output {
                        delta = current
                    } else {
                        delta = RunningTotals(
                            input: max(0, current.input - previous.input),
                            cached: max(0, current.cached - previous.cached),
                            output: max(0, current.output - previous.output))
                    }
                } else {
                    delta = nil
                }

                if let total {
                    previousTotals = RunningTotals(
                        input: max(0, Self.intValue(total["input_tokens"])),
                        cached: max(0, Self.intValue(total["cached_input_tokens"] ?? total["cache_read_input_tokens"])),
                        output: max(0, Self.intValue(total["output_tokens"])))
                } else if let delta {
                    let previous = previousTotals ?? RunningTotals()
                    previousTotals = RunningTotals(
                        input: previous.input + delta.input,
                        cached: previous.cached + delta.cached,
                        output: previous.output + delta.output)
                }

                guard let delta else { return }
                add(dayKey: dayKey, model: model, input: delta.input, cached: delta.cached, output: delta.output)
            }
        } catch {
            return days
        }

        return days
    }

    private func scanLines(fileURL: URL, onLine: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var consumedUntil = buffer.startIndex
            var searchStart = buffer.startIndex
            while searchStart < buffer.endIndex,
                  let newline = buffer[searchStart...].firstIndex(of: 10) {
                var line = buffer.subdata(in: consumedUntil..<newline)
                if line.last == 13 {
                    line.removeLast()
                }
                onLine(line)
                consumedUntil = buffer.index(after: newline)
                searchStart = consumedUntil
            }
            if consumedUntil > buffer.startIndex {
                buffer = buffer.subdata(in: consumedUntil..<buffer.endIndex)
            }
        }

        if !buffer.isEmpty {
            onLine(buffer)
        }
    }

    private func shouldInspect(_ line: Data) -> Bool {
        if line.containsASCII(#""token_count""#) {
            return true
        }
        if line.containsASCII(#""type":"turn_context""#) {
            return true
        }
        return false
    }

    private func extractStringField(_ field: String, fromPrefixOf line: Data) -> String? {
        let prefix = line.prefix(32 * 1024)
        guard let text = String(data: Data(prefix), encoding: .utf8) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: field)
        let pattern = #"""# + escaped + #""\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    private func report(from cache: Cache, now: Date) -> MoaUsageReport {
        var buckets: [String: MoaUsageDetailRow] = [:]
        for cachedFile in cache.files.values {
            for (dayKey, models) in cachedFile.days {
                for (model, usage) in models {
                    let metadata = pricingOverrides.codexCostEstimate(
                        model: model,
                        inputTokens: usage.input,
                        cachedInputTokens: usage.cached,
                        outputTokens: usage.output
                    ) ?? CodexUsagePricing.codexCostEstimate(
                        model: model,
                        inputTokens: usage.input,
                        cachedInputTokens: usage.cached,
                        outputTokens: usage.output
                    )
                    let row = MoaUsageDetailRow(
                        source: .codex,
                        dayKey: dayKey,
                        model: metadata?.normalizedModel ?? model,
                        input: max(0, usage.input - usage.cached),
                        cachedInput: usage.cached,
                        cacheReadInput: 0,
                        cacheCreationInput: 0,
                        output: usage.output,
                        costUSD: metadata?.costUSD ?? 0,
                        pricingModel: metadata?.pricingModel ?? model,
                        usesFallbackPricing: metadata?.usesFallbackPricing ?? false
                    )
                    if var existing = buckets[row.id] {
                        existing.merge(row)
                        buckets[row.id] = existing
                    } else {
                        buckets[row.id] = row
                    }
                }
            }
        }
        return MoaUsageReport(rows: Array(buckets.values), generatedAt: now)
    }

    private func summary(from report: MoaUsageReport, now: Date) -> CodexUsageSummary {
        let todayKey = Self.dayKey(from: now)
        var todayCost = 0.0
        var todayTokens = 0
        var totalCost = 0.0
        var totalTokens = 0
        var cacheHitTokens = 0
        var modelTotals: [String: Int] = [:]

        for row in report.rows {
            let tokens = row.totalTokens
            totalCost += row.costUSD
            totalTokens += tokens
            cacheHitTokens += row.cacheHitTokens
            modelTotals[row.model, default: 0] += tokens

            if row.dayKey == todayKey {
                todayCost += row.costUSD
                todayTokens += tokens
            }
        }

        let top = modelTotals.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }
        let topPercent = if let top, totalTokens > 0 {
            (Double(top.value) / Double(totalTokens)) * 100
        } else {
            0.0
        }
        let cacheHitPercent = totalTokens > 0
            ? Double(cacheHitTokens) / Double(totalTokens) * 100
            : 0.0

        return CodexUsageSummary(
            todayCostUSD: todayCost,
            totalCostUSD: totalCost,
            todayTokens: todayTokens,
            totalTokens: totalTokens,
            cacheHitPercent: cacheHitPercent,
            topModelName: top?.key,
            topModelTokens: top?.value ?? 0,
            topModelPercent: topPercent,
            updatedAt: now)
    }

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            return Cache(version: 1, codexHomePath: codexHome.path, files: [:])
        }
        return decoded
    }

    private func lockedLoadCache() -> Cache {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return loadCache()
    }

    private func lockedSaveCache(_ cache: Cache) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        saveCache(cache)
    }

    private func saveCache(_ cache: Cache) {
        do {
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string) ?? 0
        }
        return 0
    }

    private static func dayKey(from timestamp: String) -> String? {
        guard let date = CodexUsageDateParser.parse(timestamp) else { return nil }
        return dayKey(from: date)
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }
}

final class ClaudeUsageScanner {
    private struct TokenUsage: Codable, Equatable {
        var input: Int = 0
        var cacheRead: Int = 0
        var cacheCreation: Int = 0
        var output: Int = 0
        var costUSD: Double = 0

        var totalTokens: Int {
            input + cacheRead + cacheCreation + output
        }

        mutating func add(input: Int, cacheRead: Int, cacheCreation: Int, output: Int, costUSD: Double) {
            self.input += input
            self.cacheRead += cacheRead
            self.cacheCreation += cacheCreation
            self.output += output
            self.costUSD += costUSD
        }
    }

    private struct UsageRow: Codable, Equatable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let output: Int
        let costUSD: Double

        var totalTokens: Int {
            input + cacheRead + cacheCreation + output
        }
    }

    private struct CachedFile: Codable, Equatable {
        var mtime: TimeInterval
        var size: Int64
        var rows: [UsageRow]
    }

    private struct Cache: Codable, Equatable {
        var version: Int
        var roots: [String]
        var files: [String: CachedFile]
    }

    private let fileManager = FileManager.default
    private let home: String
    private let environment: [String: String]
    private let pricingOverrides: MoaUsagePricingOverrideController
    private let cacheLock = NSLock()

    private var cacheURL: URL {
        MoaDataRoot.currentURL(environment: environment)
            .appendingPathComponent("claude-usage-cache-v1.json")
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        home = environment["HOME"] ?? NSHomeDirectory()
        self.environment = environment
        pricingOverrides = MoaUsagePricingOverrideController(environment: environment)
    }

    func loadSummary(forceRefresh: Bool = false, now: Date = Date()) throws -> CodexUsageSummary {
        summary(from: try loadReport(forceRefresh: forceRefresh, now: now), now: now)
    }

    func loadReport(
        forceRefresh: Bool = false,
        now: Date = Date(),
        persistCache: Bool = true
    ) throws -> MoaUsageReport {
        let projectsRoots = Self.defaultProjectsRoots(home: home, environment: environment)
        let files = sessionFiles(in: projectsRoots)
        let validPaths = Set(files.map(\.path))
        let rootPaths = projectsRoots.map(\.path).sorted()
        var cache = lockedLoadCache(rootPaths: rootPaths)
        if cache.version != 2 {
            cache = Cache(version: 2, roots: rootPaths, files: [:])
        }
        cache.roots = rootPaths
        let originalCache = cache

        var nextFiles: [String: CachedFile] = [:]
        for fileURL in files {
            guard let metadata = fileMetadata(for: fileURL) else { continue }
            let path = fileURL.path
            if !forceRefresh,
               let cached = cache.files[path],
               cached.mtime == metadata.mtime,
               cached.size == metadata.size
            {
                nextFiles[path] = cached
                continue
            }

            let rows = parseSessionFile(fileURL)
            nextFiles[path] = CachedFile(mtime: metadata.mtime, size: metadata.size, rows: rows)
        }

        cache.files = nextFiles.filter { validPaths.contains($0.key) }
        if persistCache && cache != originalCache {
            lockedSaveCache(cache)
        }
        return report(from: cache, now: now)
    }

    private static func defaultProjectsRoots(home: String, environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            roots.append(contentsOf: raw.split(separator: ",").compactMap { part in
                let path = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return nil }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                if url.lastPathComponent == "projects" {
                    return url
                }
                return url.appendingPathComponent("projects", isDirectory: true).standardizedFileURL
            })
        }

        roots.append(contentsOf: [
            URL(fileURLWithPath: "\(home)/.config/claude/projects", isDirectory: true).standardizedFileURL,
            URL(fileURLWithPath: "\(home)/.claude/projects", isDirectory: true).standardizedFileURL
        ])

        let appSupport = URL(fileURLWithPath: "\(home)/Library/Application Support", isDirectory: true)
        for appName in ["Claude", "Claude-3p"] {
            let appRoot = appSupport.appendingPathComponent(appName, isDirectory: true)
            roots.append(contentsOf: discoverNestedProjectRoots(
                under: appRoot.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)))
            roots.append(contentsOf: discoverNestedProjectRoots(
                under: appRoot.appendingPathComponent("claude-code-sessions", isDirectory: true)))
        }

        var seen: Set<String> = []
        return roots.filter { root in
            guard !seen.contains(root.path) else { return false }
            seen.insert(root.path)
            return true
        }
    }

    private static func discoverNestedProjectRoots(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants])
        else {
            return []
        }

        var roots: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "projects",
                  url.deletingLastPathComponent().lastPathComponent == ".claude",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else {
                continue
            }
            roots.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }
        return roots
    }

    private func sessionFiles(in roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
                files.append(fileURL.standardizedFileURL)
            }
        }
        return files
    }

    private func fileMetadata(for url: URL) -> (mtime: TimeInterval, size: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate?.timeIntervalSince1970,
              let size = values.fileSize
        else { return nil }
        return (mtime, Int64(size))
    }

    private func parseSessionFile(_ fileURL: URL) -> [UsageRow] {
        var keyedRows: [String: UsageRow] = [:]
        var unkeyedRows: [UsageRow] = []

        do {
            try scanLines(fileURL: fileURL) { line in
                guard shouldInspect(line) else { return }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (object["type"] as? String) == "assistant",
                      let timestamp = object["timestamp"] as? String,
                      let dayKey = Self.dayKey(from: timestamp),
                      let message = object["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      model != "<synthetic>",
                      let usage = message["usage"] as? [String: Any]
                else { return }

                let input = max(0, Self.intValue(usage["input_tokens"]))
                let cacheRead = max(0, Self.intValue(usage["cache_read_input_tokens"]))
                let cacheCreation = max(0, Self.intValue(usage["cache_creation_input_tokens"]))
                let output = max(0, Self.intValue(usage["output_tokens"]))
                guard input > 0 || cacheRead > 0 || cacheCreation > 0 || output > 0 else { return }

                let normalizedModel = MoaUsagePricing.normalizeClaudeModel(model)
                let estimate = pricingOverrides.claudeCostEstimate(
                    model: normalizedModel,
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreation,
                    outputTokens: output
                ) ?? MoaUsagePricing.claudeCostEstimate(
                    model: normalizedModel,
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreation,
                    outputTokens: output
                )
                let sessionId = object["sessionId"] as? String
                    ?? object["session_id"] as? String
                    ?? (object["metadata"] as? [String: Any])?["sessionId"] as? String
                    ?? (message["metadata"] as? [String: Any])?["sessionId"] as? String
                let messageId = message["id"] as? String
                let requestId = object["requestId"] as? String
                let row = UsageRow(
                    dayKey: dayKey,
                    model: normalizedModel,
                    sessionId: sessionId,
                    messageId: messageId,
                    requestId: requestId,
                    input: input,
                    cacheRead: cacheRead,
                    cacheCreation: cacheCreation,
                    output: output,
                    costUSD: estimate?.costUSD ?? 0)

                if let key = Self.rowKey(row) {
                    if let existing = keyedRows[key], existing.totalTokens > row.totalTokens {
                        return
                    }
                    keyedRows[key] = row
                } else {
                    unkeyedRows.append(row)
                }
            }
        } catch {
            return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
        }

        return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
    }

    private func scanLines(fileURL: URL, onLine: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var consumedUntil = buffer.startIndex
            var searchStart = buffer.startIndex
            while searchStart < buffer.endIndex,
                  let newline = buffer[searchStart...].firstIndex(of: 10) {
                var line = buffer.subdata(in: consumedUntil..<newline)
                if line.last == 13 {
                    line.removeLast()
                }
                onLine(line)
                consumedUntil = buffer.index(after: newline)
                searchStart = consumedUntil
            }
            if consumedUntil > buffer.startIndex {
                buffer = buffer.subdata(in: consumedUntil..<buffer.endIndex)
            }
        }

        if !buffer.isEmpty {
            onLine(buffer)
        }
    }

    private func shouldInspect(_ line: Data) -> Bool {
        line.containsASCII(#""type":"assistant""#) && line.containsASCII(#""usage""#)
    }

    private func report(from cache: Cache, now: Date) -> MoaUsageReport {
        var winners: [String: UsageRow] = [:]
        var unkeyedRows: [UsageRow] = []
        for cachedFile in cache.files.values {
            for row in cachedFile.rows {
                if let key = Self.rowKey(row) {
                    if let existing = winners[key], existing.totalTokens > row.totalTokens {
                        continue
                    }
                    winners[key] = row
                } else {
                    unkeyedRows.append(row)
                }
            }
        }

        var buckets: [String: MoaUsageDetailRow] = [:]
        for usageRow in Array(winners.values) + unkeyedRows {
            let estimate = pricingOverrides.claudeCostEstimate(
                model: usageRow.model,
                inputTokens: usageRow.input,
                cacheReadInputTokens: usageRow.cacheRead,
                cacheCreationInputTokens: usageRow.cacheCreation,
                outputTokens: usageRow.output
            ) ?? MoaUsagePricing.claudeCostEstimate(
                model: usageRow.model,
                inputTokens: usageRow.input,
                cacheReadInputTokens: usageRow.cacheRead,
                cacheCreationInputTokens: usageRow.cacheCreation,
                outputTokens: usageRow.output
            )
            let row = MoaUsageDetailRow(
                source: .claude,
                dayKey: usageRow.dayKey,
                model: estimate?.normalizedModel ?? usageRow.model,
                input: usageRow.input,
                cachedInput: 0,
                cacheReadInput: usageRow.cacheRead,
                cacheCreationInput: usageRow.cacheCreation,
                output: usageRow.output,
                costUSD: estimate?.costUSD ?? usageRow.costUSD,
                pricingModel: estimate?.pricingModel ?? usageRow.model,
                usesFallbackPricing: estimate?.usesFallbackPricing ?? false
            )
            if var existing = buckets[row.id] {
                existing.merge(row)
                buckets[row.id] = existing
            } else {
                buckets[row.id] = row
            }
        }
        return MoaUsageReport(rows: Array(buckets.values), generatedAt: now)
    }

    private func summary(from report: MoaUsageReport, now: Date) -> CodexUsageSummary {
        let todayKey = Self.dayKey(from: now)
        var todayCost = 0.0
        var todayTokens = 0
        var totalCost = 0.0
        var totalTokens = 0
        var cacheHitTokens = 0
        var modelTotals: [String: Int] = [:]

        for row in report.rows {
            let tokens = row.totalTokens
            totalCost += row.costUSD
            totalTokens += tokens
            cacheHitTokens += row.cacheHitTokens
            modelTotals[row.model, default: 0] += tokens

            if row.dayKey == todayKey {
                todayCost += row.costUSD
                todayTokens += tokens
            }
        }

        let top = modelTotals.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }
        let topPercent = if let top, totalTokens > 0 {
            (Double(top.value) / Double(totalTokens)) * 100
        } else {
            0.0
        }
        let cacheHitPercent = totalTokens > 0
            ? Double(cacheHitTokens) / Double(totalTokens) * 100
            : 0.0

        return CodexUsageSummary(
            todayCostUSD: todayCost,
            totalCostUSD: totalCost,
            todayTokens: todayTokens,
            totalTokens: totalTokens,
            cacheHitPercent: cacheHitPercent,
            topModelName: top?.key,
            topModelTokens: top?.value ?? 0,
            topModelPercent: topPercent,
            updatedAt: now)
    }

    private func loadCache(rootPaths: [String]) -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            return Cache(version: 2, roots: rootPaths, files: [:])
        }
        return decoded
    }

    private func lockedLoadCache(rootPaths: [String]) -> Cache {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return loadCache(rootPaths: rootPaths)
    }

    private func lockedSaveCache(_ cache: Cache) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        saveCache(cache)
    }

    private func saveCache(_ cache: Cache) {
        do {
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func rowKey(_ row: UsageRow) -> String? {
        guard let messageId = row.messageId, !messageId.isEmpty else { return nil }
        let session = row.sessionId ?? ""
        let request = row.requestId ?? ""
        return "\(session)|\(messageId)|\(request)"
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string) ?? 0
        }
        return 0
    }

    private static func dayKey(from timestamp: String) -> String? {
        guard let date = CodexUsageDateParser.parse(timestamp) else { return nil }
        return dayKey(from: date)
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }
}

enum MoaUsagePricing {
    struct CostEstimate {
        let costUSD: Double
        let normalizedModel: String
        let pricingModel: String
        let usesFallbackPricing: Bool
    }

    private static let codexPriorityInputTokenLimit = 272_000
    // 全新模型未内置价格时的回退参考模型：Codex 侧用 gpt-5.5，Claude 侧用 claude-opus-4-7，
    // 避免未知模型的成本被静默计为 0、导致总额偏低。
    private static let fallbackCodexPricingModel = "gpt-5.5"
    private static let fallbackClaudePricingModel = "claude-opus-4-7"
    private static let fallbackZCodePricingModel = "GLM-5.2"
    private static let catalogStoreLock = NSLock()
    private static var catalogStore = MoaUsagePricingCatalogStore.shared

    private struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let priorityInputCostPerToken: Double?
        let priorityOutputCostPerToken: Double?
        let priorityCacheReadInputCostPerToken: Double?
    }

    private struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    private struct ZCodePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5-codex": CodexPricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5-mini": CodexPricing(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadInputCostPerToken: 2.5e-8, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5-nano": CodexPricing(inputCostPerToken: 5e-8, outputCostPerToken: 4e-7, cacheReadInputCostPerToken: 5e-9, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5-pro": CodexPricing(inputCostPerToken: 1.5e-5, outputCostPerToken: 1.2e-4, cacheReadInputCostPerToken: nil, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.1": CodexPricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.1-codex": CodexPricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.1-codex-max": CodexPricing(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadInputCostPerToken: 1.25e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.1-codex-mini": CodexPricing(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadInputCostPerToken: 2.5e-8, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.2": CodexPricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.2-codex": CodexPricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.2-pro": CodexPricing(inputCostPerToken: 2.1e-5, outputCostPerToken: 1.68e-4, cacheReadInputCostPerToken: nil, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.3-codex": CodexPricing(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadInputCostPerToken: 1.75e-7, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.3-codex-spark": CodexPricing(inputCostPerToken: 0, outputCostPerToken: 0, cacheReadInputCostPerToken: 0, displayLabel: "Research Preview", thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.4": CodexPricing(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadInputCostPerToken: 2.5e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 5e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheReadInputCostPerTokenAboveThreshold: 5e-7, priorityInputCostPerToken: 5e-6, priorityOutputCostPerToken: 3e-5, priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.4-mini": CodexPricing(inputCostPerToken: 7.5e-7, outputCostPerToken: 4.5e-6, cacheReadInputCostPerToken: 7.5e-8, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: 1.5e-6, priorityOutputCostPerToken: 9e-6, priorityCacheReadInputCostPerToken: 1.5e-7),
        "gpt-5.4-nano": CodexPricing(inputCostPerToken: 2e-7, outputCostPerToken: 1.25e-6, cacheReadInputCostPerToken: 2e-8, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.4-pro": CodexPricing(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadInputCostPerToken: nil, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        "gpt-5.5": CodexPricing(inputCostPerToken: 5e-6, outputCostPerToken: 3e-5, cacheReadInputCostPerToken: 5e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 1e-5, outputCostPerTokenAboveThreshold: 4.5e-5, cacheReadInputCostPerTokenAboveThreshold: 1e-6, priorityInputCostPerToken: 1.25e-5, priorityOutputCostPerToken: 7.5e-5, priorityCacheReadInputCostPerToken: 1.25e-6),
        "gpt-5.5-pro": CodexPricing(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadInputCostPerToken: nil, displayLabel: nil, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil, priorityInputCostPerToken: nil, priorityOutputCostPerToken: nil, priorityCacheReadInputCostPerToken: nil),
        // Refreshed 2026-07-10 from https://models.dev/api.json and cross-checked against
        // https://developers.openai.com/api/docs/pricing.md. The gpt-5.6 alias routes to Sol.
        "gpt-5.6": CodexPricing(inputCostPerToken: 5e-6, outputCostPerToken: 3e-5, cacheReadInputCostPerToken: 5e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 1e-5, outputCostPerTokenAboveThreshold: 4.5e-5, cacheReadInputCostPerTokenAboveThreshold: 1e-6, priorityInputCostPerToken: 1e-5, priorityOutputCostPerToken: 6e-5, priorityCacheReadInputCostPerToken: 1e-6),
        "gpt-5.6-sol": CodexPricing(inputCostPerToken: 5e-6, outputCostPerToken: 3e-5, cacheReadInputCostPerToken: 5e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 1e-5, outputCostPerTokenAboveThreshold: 4.5e-5, cacheReadInputCostPerTokenAboveThreshold: 1e-6, priorityInputCostPerToken: 1e-5, priorityOutputCostPerToken: 6e-5, priorityCacheReadInputCostPerToken: 1e-6),
        "gpt-5.6-terra": CodexPricing(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadInputCostPerToken: 2.5e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 5e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheReadInputCostPerTokenAboveThreshold: 5e-7, priorityInputCostPerToken: 5e-6, priorityOutputCostPerToken: 3e-5, priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.6-luna": CodexPricing(inputCostPerToken: 1e-6, outputCostPerToken: 6e-6, cacheReadInputCostPerToken: 1e-7, displayLabel: nil, thresholdTokens: 272_000, inputCostPerTokenAboveThreshold: 2e-6, outputCostPerTokenAboveThreshold: 9e-6, cacheReadInputCostPerTokenAboveThreshold: 2e-7, priorityInputCostPerToken: 2e-6, priorityOutputCostPerToken: 1.2e-5, priorityCacheReadInputCostPerToken: 2e-7)
    ]

    private static let claude: [String: ClaudePricing] = [
        "claude-haiku-4-5-20251001": ClaudePricing(inputCostPerToken: 1e-6, outputCostPerToken: 5e-6, cacheCreationInputCostPerToken: 1.25e-6, cacheReadInputCostPerToken: 1e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(inputCostPerToken: 1e-6, outputCostPerToken: 5e-6, cacheCreationInputCostPerToken: 1.25e-6, cacheReadInputCostPerToken: 1e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationInputCostPerToken: 6.25e-6, cacheReadInputCostPerToken: 5e-7, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationInputCostPerToken: 3.75e-6, cacheReadInputCostPerToken: 3e-7, thresholdTokens: 200_000, inputCostPerTokenAboveThreshold: 6e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6, cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationInputCostPerToken: 3.75e-6, cacheReadInputCostPerToken: 3e-7, thresholdTokens: 200_000, inputCostPerTokenAboveThreshold: 6e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6, cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-5-20250929": ClaudePricing(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationInputCostPerToken: 3.75e-6, cacheReadInputCostPerToken: 3e-7, thresholdTokens: 200_000, inputCostPerTokenAboveThreshold: 6e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6, cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(inputCostPerToken: 1.5e-5, outputCostPerToken: 7.5e-5, cacheCreationInputCostPerToken: 1.875e-5, cacheReadInputCostPerToken: 1.5e-6, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(inputCostPerToken: 1.5e-5, outputCostPerToken: 7.5e-5, cacheCreationInputCostPerToken: 1.875e-5, cacheReadInputCostPerToken: 1.5e-6, thresholdTokens: nil, inputCostPerTokenAboveThreshold: nil, outputCostPerTokenAboveThreshold: nil, cacheCreationInputCostPerTokenAboveThreshold: nil, cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationInputCostPerToken: 3.75e-6, cacheReadInputCostPerToken: 3e-7, thresholdTokens: 200_000, inputCostPerTokenAboveThreshold: 6e-6, outputCostPerTokenAboveThreshold: 2.25e-5, cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6, cacheReadInputCostPerTokenAboveThreshold: 6e-7)
    ]

    private static let zcode: [String: ZCodePricing] = [
        "glm-5.2": ZCodePricing(inputCostPerToken: 1.4e-6, outputCostPerToken: 4.4e-6, cacheCreationInputCostPerToken: 0, cacheReadInputCostPerToken: 0.26e-6),
        "glm-5.1": ZCodePricing(inputCostPerToken: 1.4e-6, outputCostPerToken: 4.4e-6, cacheCreationInputCostPerToken: 0, cacheReadInputCostPerToken: 0.26e-6),
        "glm-5-turbo": ZCodePricing(inputCostPerToken: 1.2e-6, outputCostPerToken: 4.0e-6, cacheCreationInputCostPerToken: 0, cacheReadInputCostPerToken: 0.24e-6)
    ]

#if MOA_TESTING
    static func useRemoteCatalogStoreForTesting(_ store: MoaUsagePricingCatalogStore) {
        catalogStoreLock.lock()
        catalogStore = store
        catalogStoreLock.unlock()
    }

    static func resetRemoteCatalogStoreForTesting() {
        useRemoteCatalogStoreForTesting(.shared)
    }
#endif

    private static func remotePricing(source: MoaUsageSource, model: String) -> MoaUsageRemotePricing? {
        catalogStoreLock.lock()
        let store = catalogStore
        catalogStoreLock.unlock()
        return store.pricing(source: source, model: model)
    }

    private static func codexPricing(model: String) -> CodexPricing? {
        let builtIn = codex[model]
        guard let remote = remotePricing(source: .codex, model: model) else { return builtIn }
        return CodexPricing(
            inputCostPerToken: perToken(remote.inputUSDPerMillion),
            outputCostPerToken: perToken(remote.outputUSDPerMillion),
            cacheReadInputCostPerToken: remote.cacheReadUSDPerMillion.map(perToken) ?? builtIn?.cacheReadInputCostPerToken,
            displayLabel: builtIn?.displayLabel,
            thresholdTokens: remote.thresholdTokens ?? builtIn?.thresholdTokens,
            inputCostPerTokenAboveThreshold: remote.inputUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.inputCostPerTokenAboveThreshold,
            outputCostPerTokenAboveThreshold: remote.outputUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.outputCostPerTokenAboveThreshold,
            cacheReadInputCostPerTokenAboveThreshold: remote.cacheReadUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.cacheReadInputCostPerTokenAboveThreshold,
            priorityInputCostPerToken: builtIn?.priorityInputCostPerToken,
            priorityOutputCostPerToken: builtIn?.priorityOutputCostPerToken,
            priorityCacheReadInputCostPerToken: builtIn?.priorityCacheReadInputCostPerToken
        )
    }

    private static func claudePricing(model: String) -> ClaudePricing? {
        let builtIn = claude[model]
        guard let remote = remotePricing(source: .claude, model: model) else { return builtIn }
        return ClaudePricing(
            inputCostPerToken: perToken(remote.inputUSDPerMillion),
            outputCostPerToken: perToken(remote.outputUSDPerMillion),
            cacheCreationInputCostPerToken: remote.cacheCreationUSDPerMillion.map(perToken) ?? builtIn?.cacheCreationInputCostPerToken ?? perToken(remote.inputUSDPerMillion),
            cacheReadInputCostPerToken: remote.cacheReadUSDPerMillion.map(perToken) ?? builtIn?.cacheReadInputCostPerToken ?? perToken(remote.inputUSDPerMillion),
            thresholdTokens: remote.thresholdTokens ?? builtIn?.thresholdTokens,
            inputCostPerTokenAboveThreshold: remote.inputUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.inputCostPerTokenAboveThreshold,
            outputCostPerTokenAboveThreshold: remote.outputUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.outputCostPerTokenAboveThreshold,
            cacheCreationInputCostPerTokenAboveThreshold: remote.cacheCreationUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.cacheCreationInputCostPerTokenAboveThreshold,
            cacheReadInputCostPerTokenAboveThreshold: remote.cacheReadUSDPerMillionAboveThreshold.map(perToken) ?? builtIn?.cacheReadInputCostPerTokenAboveThreshold
        )
    }

    private static func zcodePricing(model: String) -> ZCodePricing? {
        let key = model.lowercased()
        let builtIn = zcode[key]
        guard let remote = remotePricing(source: .zcode, model: key) else { return builtIn }
        return ZCodePricing(
            inputCostPerToken: perToken(remote.inputUSDPerMillion),
            outputCostPerToken: perToken(remote.outputUSDPerMillion),
            cacheCreationInputCostPerToken: remote.cacheCreationUSDPerMillion.map(perToken) ?? builtIn?.cacheCreationInputCostPerToken ?? 0,
            cacheReadInputCostPerToken: remote.cacheReadUSDPerMillion.map(perToken) ?? builtIn?.cacheReadInputCostPerToken ?? perToken(remote.inputUSDPerMillion)
        )
    }

    private static func perToken(_ perMillion: Double) -> Double {
        perMillion / 1_000_000
    }

    static func normalizeModel(_ raw: String) -> String {
        normalizeCodexModel(raw)
    }

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        if codexPricing(model: trimmed) != nil {
            return trimmed
        }

        if let range = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<range.lowerBound])
            if codexPricing(model: base) != nil {
                return base
            }
        }
        return trimmed
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        for suffix in ["[1m]", "(1m)", "+1m"] where trimmed.lowercased().hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let range = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(range)
        }

        if let range = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<range.lowerBound])
            if claudePricing(model: base) != nil {
                return base
            }
        }

        return trimmed
    }

    static func normalizeZCodeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.lastIndex(of: "/") {
            trimmed = String(trimmed[trimmed.index(after: slash)...])
        }

        switch trimmed.lowercased() {
        case "glm-5.2":
            return "GLM-5.2"
        case "glm-5.1":
            return "GLM-5.1"
        case "glm-5-turbo", "glm-5turbo":
            return "GLM-5-Turbo"
        default:
            return trimmed
        }
    }

    static func codexDisplayLabel(model: String) -> String? {
        codexPricing(model: normalizeCodexModel(model))?.displayLabel
    }

    static func costUSD(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
        codexCostUSD(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double?
    {
        codexCostEstimate(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )?.costUSD
    }

    static func codexCostEstimate(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> CostEstimate?
    {
        let normalized = normalizeCodexModel(model)
        let usesFallback = codexPricing(model: normalized) == nil
        let pricingModel = usesFallback ? fallbackCodexPricingModel : normalized
        guard let pricing = codexPricing(model: pricingModel) else { return nil }
        let cost = codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
        return CostEstimate(
            costUSD: cost,
            normalizedModel: normalized,
            pricingModel: pricingModel,
            usesFallbackPricing: usesFallback
        )
    }

    static func codexCacheReadUSDPerMillion(model: String, inputTokens: Int = 1) -> Double? {
        let normalized = normalizeCodexModel(model)
        let pricingModel = codexPricing(model: normalized) == nil ? fallbackCodexPricingModel : normalized
        guard let pricing = codexPricing(model: pricingModel) else { return nil }
        let baseRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        let usesLongContextRates = pricing.thresholdTokens.map { max(0, inputTokens) > $0 } ?? false
        let rate = usesLongContextRates ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? baseRate : baseRate
        return rate * 1_000_000
    }

    static func codexPriorityCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int) -> Double?
    {
        let normalized = normalizeCodexModel(model)
        guard let pricing = codexPricing(model: normalized),
              let priorityInput = pricing.priorityInputCostPerToken,
              let priorityOutput = pricing.priorityOutputCostPerToken,
              max(0, inputTokens) <= codexPriorityInputTokenLimit
        else {
            return nil
        }

        let priorityPricing = CodexPricing(
            inputCostPerToken: priorityInput,
            outputCostPerToken: priorityOutput,
            cacheReadInputCostPerToken: pricing.priorityCacheReadInputCostPerToken,
            displayLabel: nil,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil,
            priorityInputCostPerToken: nil,
            priorityOutputCostPerToken: nil,
            priorityCacheReadInputCostPerToken: nil)
        return codexCostUSD(
            pricing: priorityPricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> Double?
    {
        claudeCostEstimate(
            model: model,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            outputTokens: outputTokens
        )?.costUSD
    }

    static func claudeCostEstimate(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> CostEstimate?
    {
        let normalized = normalizeClaudeModel(model)
        let usesFallback = claudePricing(model: normalized) == nil
        let pricingModel = usesFallback ? fallbackClaudePricingModel : normalized
        guard let pricing = claudePricing(model: pricingModel) else { return nil }
        let cost = claudeCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            outputTokens: outputTokens)
        return CostEstimate(
            costUSD: cost,
            normalizedModel: normalized,
            pricingModel: pricingModel,
            usesFallbackPricing: usesFallback
        )
    }

    static func claudeCacheReadUSDPerMillion(model: String, promptTokens: Int = 1) -> Double? {
        let normalized = normalizeClaudeModel(model)
        let pricingModel = claudePricing(model: normalized) == nil ? fallbackClaudePricingModel : normalized
        guard let pricing = claudePricing(model: pricingModel) else { return nil }
        let usesLongContextRates = pricing.thresholdTokens.map { max(0, promptTokens) > $0 } ?? false
        let rate = usesLongContextRates ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken : pricing.cacheReadInputCostPerToken
        return rate * 1_000_000
    }

    static func claudeCacheCreationUSDPerMillion(model: String, promptTokens: Int = 1) -> Double? {
        let normalized = normalizeClaudeModel(model)
        let pricingModel = claudePricing(model: normalized) == nil ? fallbackClaudePricingModel : normalized
        guard let pricing = claudePricing(model: pricingModel) else { return nil }
        let usesLongContextRates = pricing.thresholdTokens.map { max(0, promptTokens) > $0 } ?? false
        let rate = usesLongContextRates ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken : pricing.cacheCreationInputCostPerToken
        return rate * 1_000_000
    }

    static func zcodeCostEstimate(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> CostEstimate?
    {
        let normalized = normalizeZCodeModel(model)
        let usesFallback = zcodePricing(model: normalized) == nil
        let pricingModel = usesFallback ? fallbackZCodePricingModel : normalized
        guard let pricing = zcodePricing(model: pricingModel) else { return nil }
        let cost = zcodeCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            outputTokens: outputTokens)
        return CostEstimate(
            costUSD: cost,
            normalizedModel: normalized,
            pricingModel: pricingModel,
            usesFallbackPricing: usesFallback
        )
    }

    static func zcodeCacheReadUSDPerMillion(model: String, promptTokens: Int = 1) -> Double? {
        let normalized = normalizeZCodeModel(model)
        let pricingModel = zcodePricing(model: normalized) == nil ? fallbackZCodePricingModel : normalized
        guard let pricing = zcodePricing(model: pricingModel) else { return nil }
        return pricing.cacheReadInputCostPerToken * 1_000_000
    }

    static func zcodeCacheCreationUSDPerMillion(model: String, promptTokens: Int = 1) -> Double? {
        let normalized = normalizeZCodeModel(model)
        let pricingModel = zcodePricing(model: normalized) == nil ? fallbackZCodePricingModel : normalized
        guard let pricing = zcodePricing(model: pricingModel) else { return nil }
        return pricing.cacheCreationInputCostPerToken * 1_000_000
    }

    private static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        let usesLongContextRates = pricing.thresholdTokens.map { max(0, inputTokens) > $0 } ?? false
        let inputRate = usesLongContextRates ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? cachedRate : cachedRate
        let outputRate = usesLongContextRates ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken : pricing.outputCostPerToken

        return Double(nonCached) * inputRate
            + Double(cached) * cachedInputRate
            + Double(max(0, outputTokens)) * outputRate
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let input = max(0, inputTokens)
        let cacheRead = max(0, cacheReadInputTokens)
        let cacheCreation = max(0, cacheCreationInputTokens)
        let output = max(0, outputTokens)
        let promptTokens = input + cacheRead + cacheCreation
        let usesLongContextRates = pricing.thresholdTokens.map { promptTokens > $0 } ?? false
        let inputRate = usesLongContextRates ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken : pricing.cacheReadInputCostPerToken
        let cacheCreationRate = usesLongContextRates ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation) * cacheCreationRate
            + Double(output) * outputRate
    }

    private static func zcodeCostUSD(
        pricing: ZCodePricing,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> Double
    {
        Double(max(0, inputTokens)) * pricing.inputCostPerToken
            + Double(max(0, cacheReadInputTokens)) * pricing.cacheReadInputCostPerToken
            + Double(max(0, cacheCreationInputTokens)) * pricing.cacheCreationInputCostPerToken
            + Double(max(0, outputTokens)) * pricing.outputCostPerToken
    }
}

private typealias CodexUsagePricing = MoaUsagePricing

final class CodexUsageSummaryMenuView: NSView {
    private static let menuWidth: CGFloat = 300
    private static let menuHeight: CGFloat = 128
    private static let leftX: CGFloat = 16
    private static let centerX: CGFloat = 104
    private static let rightX: CGFloat = 192
    private static let costRightX: CGFloat = 166
    private static let usageColumnWidth: CGFloat = 84
    private static let costColumnWidth: CGFloat = 118
    private static let fullWidth: CGFloat = 268
    private let todayCaption = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let monthCaption = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let todayValue = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 16, weight: .regular), color: .labelColor)
    private let monthValue = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 16, weight: .regular), color: .labelColor)
    private let monthTokensCaption = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let latestTokensCaption = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let cacheHitCaption = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let monthTokensValue = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 16, weight: .regular), color: .labelColor)
    private let latestTokensValue = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 16, weight: .regular), color: .labelColor)
    private let cacheHitValue = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 16, weight: .regular), color: .labelColor)
    private let topModelLine = CodexUsageSummaryMenuView.label(font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
    private var currentState: CodexUsageMenuState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.menuWidth, height: Self.menuHeight)))
        [
            todayCaption,
            monthCaption,
            todayValue,
            monthValue,
            monthTokensCaption,
            latestTokensCaption,
            cacheHitCaption,
            monthTokensValue,
            latestTokensValue,
            cacheHitValue,
            topModelLine
        ].forEach(addSubview)
        todayCaption.stringValue = MoaL10n.text("Today Cost")
        monthCaption.stringValue = MoaL10n.text("Total Cost")
        monthTokensCaption.stringValue = MoaL10n.text("Today Usage")
        latestTokensCaption.stringValue = MoaL10n.text("Total Usage")
        cacheHitCaption.stringValue = MoaL10n.text("Cache Hit")
        apply(.idle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    override func layout() {
        super.layout()
        topModelLine.frame = NSRect(x: Self.leftX, y: 105, width: Self.fullWidth, height: 17)
        todayCaption.frame = NSRect(x: Self.leftX, y: 78, width: Self.costColumnWidth, height: 18)
        monthCaption.frame = NSRect(x: Self.costRightX, y: 78, width: Self.costColumnWidth, height: 18)
        todayValue.frame = NSRect(x: Self.leftX, y: 55, width: Self.costColumnWidth, height: 23)
        monthValue.frame = NSRect(x: Self.costRightX, y: 55, width: Self.costColumnWidth, height: 23)
        monthTokensCaption.frame = NSRect(x: Self.leftX, y: 28, width: Self.usageColumnWidth, height: 18)
        latestTokensCaption.frame = NSRect(x: Self.centerX, y: 28, width: Self.usageColumnWidth, height: 18)
        cacheHitCaption.frame = NSRect(x: Self.rightX, y: 28, width: Self.usageColumnWidth, height: 18)
        monthTokensValue.frame = NSRect(x: Self.leftX, y: 5, width: Self.usageColumnWidth, height: 23)
        latestTokensValue.frame = NSRect(x: Self.centerX, y: 5, width: Self.usageColumnWidth, height: 23)
        cacheHitValue.frame = NSRect(x: Self.rightX, y: 5, width: Self.usageColumnWidth, height: 23)
    }

    func apply(_ state: CodexUsageMenuState) {
        currentState = state
        switch state {
        case .idle:
            todayValue.stringValue = "—"
            monthValue.stringValue = "—"
            monthTokensValue.stringValue = "—"
            latestTokensValue.stringValue = "—"
            cacheHitValue.stringValue = "—"
            topModelLine.stringValue = "\(MoaL10n.text("Top Model")): —"
        case .loading(let previous):
            if let previous {
                applyLoaded(previous)
            } else {
                todayValue.stringValue = "..."
                monthValue.stringValue = "..."
                monthTokensValue.stringValue = "..."
                latestTokensValue.stringValue = "..."
                cacheHitValue.stringValue = "..."
                topModelLine.stringValue = "\(MoaL10n.text("Top Model")): ..."
            }
        case .loaded(let summary):
            applyLoaded(summary)
        case .failed(let previous, let message):
            if let previous {
                applyLoaded(previous)
            } else {
                todayValue.stringValue = "—"
                monthValue.stringValue = "—"
                monthTokensValue.stringValue = "—"
                latestTokensValue.stringValue = "—"
                cacheHitValue.stringValue = "—"
                topModelLine.stringValue = "\(MoaL10n.text("Top Model")): —"
            }
            toolTip = "\(MoaL10n.text("Usage update failed")): \(message)"
        }
        needsLayout = true
    }

    private func applyLoaded(_ summary: CodexUsageSummary) {
        todayValue.stringValue = Self.currency(summary.todayCostUSD)
        monthValue.stringValue = Self.currency(summary.totalCostUSD)
        monthTokensValue.stringValue = Self.tokens(summary.todayTokens)
        latestTokensValue.stringValue = Self.tokens(summary.totalTokens)
        cacheHitValue.stringValue = Self.percent(summary.cacheHitPercent)
        if let topModel = summary.topModelName {
            let displayModel = Self.displayModelName(topModel)
            let topModelText = "\(MoaL10n.text("Top Model")): \(displayModel) (\(MoaL10n.text("Usage Rate")): \(String(format: "%.1f%%", summary.topModelPercent)))"
            topModelLine.stringValue = topModelText
            toolTip = topModelText
        } else {
            topModelLine.stringValue = "\(MoaL10n.text("Top Model")): —"
            toolTip = nil
        }
    }

    private static func label(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        return label
    }

    private static func displayModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("claude-") {
            return String(trimmed.dropFirst("claude-".count))
        }
        return trimmed
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func tokens(_ value: Int) -> String {
        let double = Double(value)
        if value >= 1_000_000_000 {
            return compact(double / 1_000_000_000, suffix: "B", decimals: 1)
        }
        if value >= 1_000_000 {
            let decimals = value < 10_000_000 ? 1 : 0
            return compact(double / 1_000_000, suffix: "M", decimals: decimals)
        }
        if value >= 1_000 {
            return compact(double / 1_000, suffix: "K", decimals: 0)
        }
        return "\(value)"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private static func compact(_ value: Double, suffix: String, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if decimals > 0 {
            while text.last == "0" {
                text.removeLast()
            }
            if text.last == "." {
                text.removeLast()
            }
        }
        return "\(text)\(suffix)"
    }
}

final class CodexUsageRefreshMenuView: NSView {
    private static let menuWidth: CGFloat = 300
    private static let menuHeight: CGFloat = 28
    var onRefresh: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: MoaL10n.text("Refresh Status"))
    private var isRefreshing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.menuWidth, height: Self.menuHeight)))
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 22, y: 6, width: max(0, bounds.width - 34), height: 17)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRefreshing else { return }
        onRefresh?()
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
        titleLabel.stringValue = refreshing ? MoaL10n.text("Refreshing Status...") : MoaL10n.text("Refresh Status")
        titleLabel.textColor = refreshing ? .secondaryLabelColor : .labelColor
    }
}

private enum CodexUsageDateParser {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

private extension Data {
    func containsASCII(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}
