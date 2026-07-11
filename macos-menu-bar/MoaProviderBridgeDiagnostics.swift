import Foundation

struct MoaProviderBridgeDiagnosticSummary: Codable, Equatable {
    var schemaVersion: Int
    var updatedAt: String
    var activeProfile: MoaProviderBridgeActiveProfileDiagnostic?
    var recentRequests: [MoaProviderBridgeRequestDiagnostic]
    var recentError: MoaProviderBridgeErrorDiagnostic?
}

struct MoaProviderBridgeActiveProfileDiagnostic: Codable, Equatable {
    var profileID: String
    var providerName: String
    var providerKind: String
    var bridgeMode: String
    var localPort: Int
    var localProtocol: String
    var upstreamProtocol: String
    var upstreamHost: String
    var model: String?
    var startedAt: String
}

struct MoaProviderBridgeRequestDiagnostic: Codable, Equatable {
    var startedAt: String
    var completedAt: String
    var durationMs: Int
    var method: String
    var path: String
    var localPort: Int?
    var localProtocol: String
    var upstreamProtocol: String
    var upstreamHost: String
    var stream: Bool
    var status: Int
    var upstreamStatus: Int?
    var errorCode: String?
}

struct MoaProviderBridgeErrorDiagnostic: Codable, Equatable {
    var occurredAt: String
    var code: String
    var status: Int
    var upstreamStatus: Int?
    var method: String
    var path: String
    var upstreamHost: String
}

final class MoaProviderBridgeDiagnostics: @unchecked Sendable {
    static let shared = MoaProviderBridgeDiagnostics()
    static let fileName = "provider-bridge-diagnostics.json"

    private let lock = NSRecursiveLock()
    private let maxRequests: Int
    private var activeProfile: MoaProviderBridgeActiveProfileDiagnostic?
    private var recentRequests: [MoaProviderBridgeRequestDiagnostic] = []
    private var recentError: MoaProviderBridgeErrorDiagnostic?
    private var updatedAt = MoaProviderBridgeDiagnostics.timestamp()

    init(maxRequests: Int = 20) {
        self.maxRequests = max(1, maxRequests)
    }

    func bridgeStarted(
        profileID: String,
        providerName: String,
        providerKind: String,
        bridgeMode: String,
        localPort: Int,
        upstreamProtocol: String,
        upstreamBaseURL: String,
        model: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        let now = Self.timestamp()
        activeProfile = MoaProviderBridgeActiveProfileDiagnostic(
            profileID: Self.safeSummary(profileID, maxLength: 96),
            providerName: Self.safeSummary(providerName, maxLength: 160),
            providerKind: Self.safeSummary(providerKind, maxLength: 48),
            bridgeMode: Self.safeSummary(bridgeMode, maxLength: 48),
            localPort: localPort,
            localProtocol: "responses",
            upstreamProtocol: Self.safeSummary(upstreamProtocol, maxLength: 64),
            upstreamHost: Self.upstreamHost(from: upstreamBaseURL),
            model: model.map { Self.safeSummary($0, maxLength: 96) },
            startedAt: now
        )
        updatedAt = now
    }

    func bridgeStopped() {
        lock.lock()
        defer { lock.unlock() }
        activeProfile = nil
        updatedAt = Self.timestamp()
    }

    @discardableResult
    func recordRequest(
        method: String,
        path: String,
        localPort: Int?,
        upstreamBaseURL: String,
        upstreamProtocol: String,
        status: Int,
        upstreamStatus: Int? = nil,
        errorCode: String? = nil,
        stream: Bool = false,
        startedAt: Date,
        completedAt: Date = Date()
    ) -> MoaProviderBridgeRequestDiagnostic {
        lock.lock()
        defer { lock.unlock() }

        let sanitizedMethod = Self.safeToken(method.uppercased(), fallback: "UNKNOWN", maxLength: 16)
        let sanitizedPath = Self.safeHTTPPath(path)
        let sanitizedUpstreamProtocol = Self.safeSummary(upstreamProtocol, maxLength: 64)
        let upstreamHost = Self.upstreamHost(from: upstreamBaseURL)
        let sanitizedErrorCode = errorCode.map { Self.safeToken($0, fallback: "error", maxLength: 80) }
        let completed = completedAt < startedAt ? startedAt : completedAt
        let request = MoaProviderBridgeRequestDiagnostic(
            startedAt: Self.timestamp(startedAt),
            completedAt: Self.timestamp(completed),
            durationMs: max(0, Int((completed.timeIntervalSince(startedAt) * 1000).rounded())),
            method: sanitizedMethod,
            path: sanitizedPath,
            localPort: localPort,
            localProtocol: "responses",
            upstreamProtocol: sanitizedUpstreamProtocol,
            upstreamHost: upstreamHost,
            stream: stream,
            status: status,
            upstreamStatus: upstreamStatus,
            errorCode: sanitizedErrorCode
        )

        recentRequests.append(request)
        if recentRequests.count > maxRequests {
            recentRequests.removeFirst(recentRequests.count - maxRequests)
        }

        if status >= 400 || (upstreamStatus ?? 0) >= 400 || sanitizedErrorCode != nil {
            recentError = MoaProviderBridgeErrorDiagnostic(
                occurredAt: request.completedAt,
                code: sanitizedErrorCode ?? (upstreamStatus == nil ? "http_status" : "upstream_http_status"),
                status: status,
                upstreamStatus: upstreamStatus,
                method: request.method,
                path: request.path,
                upstreamHost: request.upstreamHost
            )
        }

        updatedAt = request.completedAt
        return request
    }

    func snapshot() -> MoaProviderBridgeDiagnosticSummary {
        lock.lock()
        defer { lock.unlock() }
        return MoaProviderBridgeDiagnosticSummary(
            schemaVersion: 1,
            updatedAt: updatedAt,
            activeProfile: activeProfile,
            recentRequests: recentRequests,
            recentError: recentError
        )
    }

    func diagnosticJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot()) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func upstreamHost(from rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed)
        let host = url?.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else {
            return "unknown"
        }
        if let port = url?.port {
            return "\(safeSummary(host, maxLength: 180)):\(port)"
        }
        return safeSummary(host, maxLength: 180)
    }

    private static func safeHTTPPath(_ rawPath: String) -> String {
        let path = (URLComponents(string: rawPath)?.path ?? rawPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "/"
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        if isLikelyLocalPath(normalized) {
            return "[redacted-path]"
        }
        return safeSummary(normalized, maxLength: 160)
    }

    private static func isLikelyLocalPath(_ path: String) -> Bool {
        let prefixes = [
            "/Users/",
            "/Volumes/",
            "/private/",
            "/tmp/",
            "/var/",
            "/home/"
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    private static func safeToken(_ raw: String, fallback: String, maxLength: Int) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        let token = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(token)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return safeSummary(sanitized.isEmpty ? fallback : sanitized, maxLength: maxLength)
    }

    private static func safeSummary(_ value: String, maxLength: Int) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxLength))
    }
}
