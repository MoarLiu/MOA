import AppKit
import Foundation

final class ZCodeUsageScanner {
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let databaseURL: URL
    private let sqliteURL: URL
    private let pricingOverrides: MoaUsagePricingOverrideController

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let zcodeHomePath = environment["ZCODE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.zcode"
        let databasePath = environment["ZCODE_USAGE_DB"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(zcodeHomePath)/cli/db/db.sqlite"
        let sqlitePath = environment["SQLITE3_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/sqlite3"
        databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        sqliteURL = URL(fileURLWithPath: sqlitePath).standardizedFileURL
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
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return MoaUsageReport(rows: [], generatedAt: now)
        }

        let output = try runSQLite("""
        select
          date(started_at / 1000, 'unixepoch', 'localtime') as day_key,
          coalesce(nullif(model_id, ''), 'unknown') as model_id,
          coalesce(sum(input_tokens), 0) as input_tokens,
          coalesce(sum(cache_read_input_tokens), 0) as cache_read_input_tokens,
          coalesce(sum(cache_creation_input_tokens), 0) as cache_creation_input_tokens,
          coalesce(sum(output_tokens), 0) as output_tokens
        from model_usage
        where status = 'completed'
        group by day_key, model_id
        order by day_key, model_id;
        """)

        let separator = "\u{1F}"
        var buckets: [String: MoaUsageDetailRow] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 6 else { continue }
            let dayKey = columns[0]
            let model = columns[1]
            let rawInput = max(0, Self.intValue(columns[2]))
            let cacheRead = min(max(0, Self.intValue(columns[3])), rawInput)
            let cacheCreation = min(max(0, Self.intValue(columns[4])), max(0, rawInput - cacheRead))
            let output = max(0, Self.intValue(columns[5]))
            let input = max(0, rawInput - cacheRead - cacheCreation)

            guard input > 0 || cacheRead > 0 || cacheCreation > 0 || output > 0 else { continue }

            let estimate = pricingOverrides.zcodeCostEstimate(
                model: model,
                inputTokens: input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: output
            ) ?? MoaUsagePricing.zcodeCostEstimate(
                model: model,
                inputTokens: input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: output
            )

            let row = MoaUsageDetailRow(
                source: .zcode,
                dayKey: dayKey,
                model: estimate?.normalizedModel ?? MoaUsagePricing.normalizeZCodeModel(model),
                input: input,
                cachedInput: 0,
                cacheReadInput: cacheRead,
                cacheCreationInput: cacheCreation,
                output: output,
                costUSD: estimate?.costUSD ?? 0,
                pricingModel: estimate?.pricingModel ?? model,
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

    private func runSQLite(_ query: String) throws -> String {
        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [
            "-batch",
            "-noheader",
            "-separator",
            "\u{1F}",
            databaseURL.path,
            query
        ]

        let captureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MoaZCodeSQLite-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: captureRoot) }

        let stdoutURL = captureRoot.appendingPathComponent("stdout")
        let stderrURL = captureRoot.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()

        let output = String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: try Data(contentsOf: stderrURL), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "Moa",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : MoaL10n.text("Unable to read ZCode usage database.")]
            )
        }
        return output
    }

    private func summary(from report: MoaUsageReport, now: Date) -> CodexUsageSummary {
        let todayKey = MoaUsageReport.dayKey(from: now)
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

    private static func intValue(_ value: String) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

final class ZCodeController {
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let zcodeHome: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let zcodeHomePath = environment["ZCODE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.zcode"
        zcodeHome = URL(fileURLWithPath: zcodeHomePath).standardizedFileURL
    }

    func openZCode() {
        if let appURL = zcodeAppURL(), fileManager.fileExists(atPath: appURL.path) {
            _ = run("/usr/bin/open", [appURL.path])
            return
        }
        _ = run("/usr/bin/open", ["-a", "ZCode"])
    }

    func reopenZCode() {
        quitZCodeIfNeeded()
        openZCode()
    }

    func openZCodeFolder() {
        try? fileManager.createDirectory(at: zcodeHome, withIntermediateDirectories: true)
        _ = run("/usr/bin/open", [zcodeHome.path])
    }

    private func quitZCodeIfNeeded() {
        guard isZCodeRunning() else { return }

        _ = run("/usr/bin/osascript", ["-e", "tell application id \"dev.zcode.app\" to quit"])
        _ = waitForZCodeRunning(false, timeout: 4)

        guard isZCodeRunning() else { return }
        if let executable = zcodeExecutableURL() {
            _ = run("/usr/bin/pkill", ["-f", NSRegularExpression.escapedPattern(for: executable.path)])
        } else {
            _ = run("/usr/bin/pkill", ["-if", "ZCode.app/Contents/MacOS|zcode.app/Contents/MacOS"])
        }
        _ = waitForZCodeRunning(false, timeout: 3)
    }

    private func isZCodeRunning() -> Bool {
        if let executable = zcodeExecutableURL() {
            return run("/usr/bin/pgrep", ["-f", NSRegularExpression.escapedPattern(for: executable.path)]) == 0
        }
        return run("/usr/bin/pgrep", ["-if", "ZCode.app/Contents/MacOS|zcode.app/Contents/MacOS"]) == 0
    }

    private func waitForZCodeRunning(_ running: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isZCodeRunning() == running {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isZCodeRunning() == running
    }

    private func zcodeAppURL() -> URL? {
        if let raw = environment["ZCODE_APP"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "/Applications/ZCode.app",
            "/Applications/zcode.app",
            "\(home)/Applications/ZCode.app",
            "\(home)/Applications/zcode.app"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private func zcodeExecutableURL() -> URL? {
        guard let appURL = zcodeAppURL() else { return nil }
        let macOSDir = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        for name in ["ZCode", "zcode"] {
            let candidate = macOSDir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }
}
