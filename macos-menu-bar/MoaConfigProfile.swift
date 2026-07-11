import Foundation

struct ConfigProfile: Codable, Equatable {
    let id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var schemaVersion: Int? = nil
    var providerKind: MoaProviderKind? = nil
    var clientTarget: MoaProviderClientTarget? = nil
    var upstreamProtocol: MoaProviderUpstreamProtocol? = nil
    var bridgeMode: MoaProviderBridgeMode? = nil
    var upstreamBaseURL: String? = nil
    var model: String? = nil
    var testModel: String? = nil
    var models: [String]? = nil
    var reasoningMode: MoaProviderReasoningMode? = nil
    var bridgeToken: String? = nil
    var bridgePort: Int? = nil

    init(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String,
        schemaVersion: Int? = nil,
        providerKind: MoaProviderKind? = nil,
        clientTarget: MoaProviderClientTarget? = nil,
        upstreamProtocol: MoaProviderUpstreamProtocol? = nil,
        bridgeMode: MoaProviderBridgeMode? = nil,
        upstreamBaseURL: String? = nil,
        model: String? = nil,
        testModel: String? = nil,
        models: [String]? = nil,
        reasoningMode: MoaProviderReasoningMode? = nil,
        bridgeToken: String? = nil,
        bridgePort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.schemaVersion = schemaVersion
        self.providerKind = providerKind
        self.clientTarget = clientTarget
        self.upstreamProtocol = upstreamProtocol
        self.bridgeMode = bridgeMode
        self.upstreamBaseURL = upstreamBaseURL
        self.model = model
        self.testModel = testModel
        self.models = models
        self.reasoningMode = reasoningMode
        self.bridgeToken = bridgeToken
        self.bridgePort = bridgePort
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiKey
        case schemaVersion
        case providerKind
        case clientTarget
        case upstreamProtocol
        case bridgeMode
        case upstreamBaseURL
        case model
        case testModel
        case models
        case reasoningMode
        case bridgeToken
        case bridgePort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        providerKind = try container.decodeIfPresent(MoaProviderKind.self, forKey: .providerKind)
        clientTarget = try container.decodeIfPresent(MoaProviderClientTarget.self, forKey: .clientTarget)
        upstreamProtocol = try container.decodeIfPresent(MoaProviderUpstreamProtocol.self, forKey: .upstreamProtocol)
        bridgeMode = try container.decodeIfPresent(MoaProviderBridgeMode.self, forKey: .bridgeMode)
        upstreamBaseURL = try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        testModel = try container.decodeIfPresent(String.self, forKey: .testModel)
        models = try container.decodeIfPresent([String].self, forKey: .models)
        reasoningMode = try container.decodeIfPresent(MoaProviderReasoningMode.self, forKey: .reasoningMode)
        bridgeToken = try container.decodeIfPresent(String.self, forKey: .bridgeToken)
        bridgePort = try container.decodeIfPresent(Int.self, forKey: .bridgePort)
        if let bridgePort, !MoaProviderBridgePort.range.contains(bridgePort) {
            throw DecodingError.dataCorruptedError(
                forKey: .bridgePort,
                in: container,
                debugDescription: MoaProviderBridgePortError.outOfRange(bridgePort).localizedDescription
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(providerKind, forKey: .providerKind)
        try container.encodeIfPresent(clientTarget, forKey: .clientTarget)
        try container.encodeIfPresent(upstreamProtocol, forKey: .upstreamProtocol)
        try container.encodeIfPresent(bridgeMode, forKey: .bridgeMode)
        try container.encodeIfPresent(upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(testModel, forKey: .testModel)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(reasoningMode, forKey: .reasoningMode)
        try container.encodeIfPresent(bridgeToken, forKey: .bridgeToken)
        try container.encodeIfPresent(bridgePort, forKey: .bridgePort)
    }

    var resolvedProviderKind: MoaProviderKind {
        providerKind ?? .custom
    }

    var resolvedClientTarget: MoaProviderClientTarget {
        clientTarget ?? .codex
    }

    var resolvedUpstreamProtocol: MoaProviderUpstreamProtocol {
        upstreamProtocol ?? .responses
    }

    var resolvedBridgeMode: MoaProviderBridgeMode {
        bridgeMode ?? .direct
    }

    var resolvedUpstreamBaseURL: String {
        let upstream = upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return upstream.isEmpty ? baseURL : upstream
    }

    var resolvedModel: String? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var resolvedTestModel: String? {
        let trimmed = testModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return resolvedModel
    }

    var resolvedBridgePort: Int {
        bridgePort ?? MoaProviderBridgeDefaults.defaultPort
    }

    var codexBaseURL: String {
        resolvedBridgeMode == .localBridge
            ? MoaProviderBridgeEndpointNormalizer.localResponsesBaseURL(port: resolvedBridgePort)
            : baseURL
    }

    var codexBearerToken: String {
        resolvedBridgeMode == .localBridge ? (bridgeToken ?? "") : apiKey
    }

    var usesLocalProviderBridge: Bool {
        resolvedBridgeMode == .localBridge && resolvedUpstreamProtocol == .chatCompletions
    }
}
