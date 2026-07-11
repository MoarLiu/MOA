import CryptoKit
import Foundation

enum MoaProviderKind: String, Codable, CaseIterable {
    case openai
    case deepseek
    case custom
}

enum MoaProviderClientTarget: String, Codable, CaseIterable {
    case codex
    case claude
    case both
}

enum MoaProviderUpstreamProtocol: String, Codable, CaseIterable {
    case responses
    case chatCompletions
    case anthropicMessages
}

enum MoaProviderBridgeMode: String, Codable, CaseIterable {
    case direct
    case localBridge
}

enum MoaProviderReasoningMode: String, Codable, CaseIterable {
    case auto
    case enabled
    case disabled
}

enum MoaProviderBridgeDefaults {
    static let defaultPort = 19360
    static let deepSeekBaseURL = "https://api.deepseek.com"
    static let deepSeekChatModel = "deepseek-chat"
    static let deepSeekReasonerModel = "deepseek-reasoner"
    static let deepSeekAnthropicBaseURL = "https://api.deepseek.com/anthropic"
}

enum MoaProviderBridgePortError: LocalizedError, Equatable {
    case outOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .outOfRange(let port):
            return MoaL10n.format("Provider bridge port must be between 0 and 65535 (received %lld).", Int64(clamping: port))
        }
    }
}

enum MoaProviderBridgePort {
    static let range = 0...65535

    static func validated(_ port: Int) throws -> Int {
        guard range.contains(port) else {
            throw MoaProviderBridgePortError.outOfRange(port)
        }
        return port
    }
}

enum MoaProviderBridgeEndpointNormalizer {
    static func normalizedDeepSeekChatBaseURL(_ raw: String) throws -> String {
        let validation = try MoaProviderBaseURLPolicy.validate(raw)
        guard let components = URLComponents(url: validation.url, resolvingAgainstBaseURL: false) else {
            throw MoaProviderBaseURLError.invalid(raw)
        }

        var normalized = components
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "v1" || path == "chat/completions" || path == "v1/chat/completions" {
            normalized.path = ""
            normalized.query = nil
            normalized.fragment = nil
            return normalized.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? validation.normalizedString
        }

        return validation.normalizedString
    }

    static func chatCompletionsURL(baseURL: String) throws -> URL {
        let validation = try MoaProviderBaseURLPolicy.validate(baseURL)
        guard var components = URLComponents(url: validation.url, resolvingAgainstBaseURL: false) else {
            throw MoaProviderBaseURLError.invalid(baseURL)
        }
        components.query = nil
        components.fragment = nil
        guard var url = components.url else {
            throw MoaProviderBaseURLError.invalid(baseURL)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            return url
        }
        if path.isEmpty {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")
        return url
    }

    static func modelsURL(baseURL: String) throws -> URL {
        let validation = try MoaProviderBaseURLPolicy.validate(baseURL)
        guard var components = URLComponents(url: validation.url, resolvingAgainstBaseURL: false) else {
            throw MoaProviderBaseURLError.invalid(baseURL)
        }
        components.query = nil
        components.fragment = nil
        guard var url = components.url else {
            throw MoaProviderBaseURLError.invalid(baseURL)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("models") {
            return url
        }
        if path.hasSuffix("chat/completions") {
            url.deleteLastPathComponent()
            url.deleteLastPathComponent()
        }
        if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent("models")
        return url
    }

    static func localResponsesBaseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/v1"
    }
}

enum MoaProviderBridgeToken {
    static func generate() throws -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Prefix(_ token: String, length: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

enum MoaProviderBridgeProtocolError: LocalizedError, Equatable {
    case invalidJSONObject
    case missingRequiredField(String)
    case unsupportedInputItem(String)
    case malformedApplyPatchArguments(String)
    case malformedSSE(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSONObject:
            return "Provider bridge expected a JSON object."
        case .missingRequiredField(let field):
            return "Provider bridge request is missing required field: \(field)."
        case .unsupportedInputItem(let type):
            return "Provider bridge cannot convert Responses input item: \(type)."
        case .malformedApplyPatchArguments(let message):
            return "Provider bridge received malformed apply_patch arguments: \(message)."
        case .malformedSSE(let message):
            return "Provider bridge received malformed SSE: \(message)."
        }
    }
}

struct MoaProviderBridgeToolContext {
    struct NamespaceTool: Equatable {
        var namespace: String
        var name: String
    }

    struct NamespaceAlias: Equatable {
        var alias: String
        var tool: NamespaceTool
    }

    var customToolNames: Set<String>
    var namespaceTools: [String: NamespaceTool]

    init(customToolNames: Set<String> = [], namespaceTools: [String: NamespaceTool] = [:]) {
        self.customToolNames = customToolNames
        self.namespaceTools = namespaceTools
    }

    static func fromResponsesTools(_ tools: [[String: Any]]) -> MoaProviderBridgeToolContext {
        var customToolNames = Set<String>()
        var namespaceTools: [String: NamespaceTool] = [:]

        for tool in tools {
            let type = tool["type"] as? String ?? "function"
            let name = MoaProviderBridgeToolNaming.toolName(tool)
            if type == "custom", name != "apply_patch" {
                customToolNames.insert(name)
            }
        }

        for alias in namespaceAliases(fromResponsesTools: tools) {
            namespaceTools[alias.alias] = alias.tool
        }

        return MoaProviderBridgeToolContext(customToolNames: customToolNames, namespaceTools: namespaceTools)
    }

    static func namespaceAliases(fromResponsesTools tools: [[String: Any]]) -> [NamespaceAlias] {
        var usedNames = Set<String>()
        for tool in tools {
            let type = tool["type"] as? String ?? "function"
            guard type != "namespace" else { continue }

            let name = MoaProviderBridgeToolNaming.toolName(tool)
            if name == "apply_patch" {
                usedNames.formUnion(MoaApplyPatchProxyCodec.proxyNames)
            } else {
                usedNames.insert(name)
            }
        }

        var aliases: [NamespaceAlias] = []
        for tool in tools {
            let type = tool["type"] as? String ?? "function"
            guard type == "namespace" else { continue }

            let namespace = MoaProviderBridgeToolNaming.namespaceName(tool) ?? ""
            let name = MoaProviderBridgeToolNaming.toolName(tool)
            let baseAlias = MoaProviderBridgeToolNaming.flattenedName(namespace: namespace, name: name)
            let alias = MoaProviderBridgeToolNaming.uniqueFunctionName(baseAlias, usedNames: &usedNames)
            aliases.append(NamespaceAlias(alias: alias, tool: NamespaceTool(namespace: namespace, name: name)))
        }
        return aliases
    }

    func treatsAsCustomTool(_ name: String) -> Bool {
        customToolNames.contains(name) || MoaApplyPatchProxyCodec.isApplyPatchProxyName(name)
    }

    func namespaceTool(for flattenedName: String) -> NamespaceTool? {
        namespaceTools[flattenedName]
    }
}

enum MoaProviderBridgeToolNaming {
    static func toolName(_ tool: [String: Any]) -> String {
        (tool["name"] as? String)
            ?? ((tool["function"] as? [String: Any])?["name"] as? String)
            ?? "tool"
    }

    static func namespaceName(_ tool: [String: Any]) -> String? {
        if let namespace = tool["namespace"] as? String {
            return namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let nested = tool["tool"] as? [String: Any], let namespace = nested["namespace"] as? String {
            return namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func flattenedName(namespace: String, name: String) -> String {
        let namespacePart = sanitizedFunctionName(namespace)
        let namePart = sanitizedFunctionName(name)
        guard !namespacePart.isEmpty else {
            return namePart.isEmpty ? "tool" : namePart
        }
        guard !namePart.isEmpty else {
            return namespacePart
        }
        return "\(namespacePart)__\(namePart)"
    }

    static func uniqueFunctionName(_ proposed: String, usedNames: inout Set<String>) -> String {
        let base = proposed.isEmpty ? "tool" : proposed
        if !usedNames.contains(base) {
            usedNames.insert(base)
            return base
        }

        var counter = 2
        while true {
            let candidate = "\(base)__\(counter)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    static func sanitizedFunctionName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let collapsed = String(scalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed
    }
}

enum MoaProviderBridgeThinkSplitter {
    static func split(_ text: String) -> (reasoning: String, visible: String) {
        var remaining = text
        var reasoning: [String] = []
        var visible = ""

        while let start = remaining.range(of: "<think>") {
            visible += String(remaining[..<start.lowerBound])
            remaining = String(remaining[start.upperBound...])
            if let end = remaining.range(of: "</think>") {
                reasoning.append(String(remaining[..<end.lowerBound]))
                remaining = String(remaining[end.upperBound...])
            } else {
                reasoning.append(remaining)
                remaining = ""
                break
            }
        }

        visible += remaining
        return (
            reasoning: reasoning.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            visible: visible.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum MoaProviderBridgeJSON {
    static func object(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw MoaProviderBridgeProtocolError.invalidJSONObject
        }
        return object
    }

    static func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: sanitize(object), options: [.sortedKeys])
    }

    static func compactString(from object: [String: Any]) throws -> String {
        let data = try data(from: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func prettyString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case .some(let value):
            if JSONSerialization.isValidJSONObject(["value": value]),
               let data = try? JSONSerialization.data(withJSONObject: sanitize(value), options: [.sortedKeys]) {
                return String(data: data, encoding: .utf8)
            }
            return String(describing: value)
        case nil:
            return nil
        }
    }

    static func contentText(from value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let parts as [[String: Any]]:
            return parts.compactMap { part in
                if let text = part["text"] as? String {
                    return text
                }
                if let text = part["input_text"] as? String {
                    return text
                }
                if let text = part["output_text"] as? String {
                    return text
                }
                if let text = part["content"] as? String {
                    return text
                }
                return nil
            }.joined()
        case let parts as [Any]:
            return parts.compactMap { part in
                if let text = part as? String {
                    return text
                }
                if let object = part as? [String: Any] {
                    return contentText(from: [object])
                }
                return nil
            }.joined()
        case .some(let value):
            return stringValue(value) ?? ""
        case nil:
            return ""
        }
    }

    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case Optional<Any>.none:
            return NSNull()
        default:
            return value
        }
    }
}

enum MoaResponsesToChatConverter {
    static func convert(
        _ request: [String: Any],
        reasoningMode: MoaProviderReasoningMode = .auto
    ) throws -> [String: Any] {
        var chat: [String: Any] = [:]
        chat["model"] = request["model"] ?? "deepseek-chat"
        chat["messages"] = try messages(from: request)

        copy("temperature", from: request, to: &chat)
        copy("top_p", from: request, to: &chat)
        copy("stream", from: request, to: &chat)
        copy("stop", from: request, to: &chat)
        copy("parallel_tool_calls", from: request, to: &chat)

        if let maxOutputTokens = request["max_output_tokens"] ?? request["max_completion_tokens"] {
            chat["max_tokens"] = maxOutputTokens
        }

        if (request["stream"] as? Bool) == true {
            chat["stream_options"] = ["include_usage": true]
        }

        if reasoningMode != .disabled, let reasoning = request["reasoning"] as? [String: Any] {
            if let effort = reasoning["effort"] as? String {
                chat["reasoning_effort"] = normalizedDeepSeekReasoningEffort(effort)
            }
            if let mode = reasoning["mode"] as? String {
                chat["thinking"] = ["type": mode == "disabled" ? "disabled" : "enabled"]
            }
        }
        if reasoningMode == .enabled && chat["reasoning_effort"] == nil {
            chat["reasoning_effort"] = "high"
        }

        if let tools = request["tools"] as? [[String: Any]] {
            let convertedTools = try MoaApplyPatchProxyCodec.chatTools(fromResponsesTools: tools)
            if !convertedTools.isEmpty {
                chat["tools"] = convertedTools
            }
        }

        if let toolChoice = request["tool_choice"] {
            chat["tool_choice"] = chatToolChoice(from: toolChoice)
        }

        return chat
    }

    private static func messages(from request: [String: Any]) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []

        if let instructions = request["instructions"] {
            for text in instructionTexts(from: instructions) where !text.isEmpty {
                messages.append(["role": "system", "content": text])
            }
        }

        guard let input = request["input"] else {
            throw MoaProviderBridgeProtocolError.missingRequiredField("input")
        }

        switch input {
        case let text as String:
            messages.append(["role": "user", "content": text])
        case let items as [[String: Any]]:
            for item in items {
                let converted = try Self.messages(fromInputItem: item)
                messages.append(contentsOf: converted)
            }
        case let items as [Any]:
            for rawItem in items {
                guard let item = rawItem as? [String: Any] else {
                    messages.append(["role": "user", "content": MoaProviderBridgeJSON.contentText(from: rawItem)])
                    continue
                }
                let converted = try Self.messages(fromInputItem: item)
                messages.append(contentsOf: converted)
            }
        default:
            messages.append(["role": "user", "content": MoaProviderBridgeJSON.contentText(from: input)])
        }

        return messages
    }

    private static func instructionTexts(from instructions: Any) -> [String] {
        switch instructions {
        case let text as String:
            return [text]
        case let objects as [[String: Any]]:
            return objects.map { MoaProviderBridgeJSON.contentText(from: $0["content"] ?? $0["text"]) }
        case let array as [Any]:
            return array.map { MoaProviderBridgeJSON.contentText(from: $0) }
        default:
            return [MoaProviderBridgeJSON.contentText(from: instructions)]
        }
    }

    private static func messages(fromInputItem item: [String: Any]) throws -> [[String: Any]] {
        let type = (item["type"] as? String) ?? "message"

        if type == "message" || item["role"] != nil {
            let rawRole = (item["role"] as? String) ?? "user"
            let role = rawRole == "developer" ? "system" : rawRole
            let content = MoaProviderBridgeJSON.contentText(from: item["content"] ?? item["text"])
            if !content.isEmpty || role == "assistant" || role == "tool" {
                return [["role": role, "content": content]]
            }
            return []
        }

        switch type {
        case "input_text":
            return [["role": "user", "content": MoaProviderBridgeJSON.contentText(from: item["text"])]]
        case "output_text":
            return [["role": "assistant", "content": MoaProviderBridgeJSON.contentText(from: item["text"])]]
        case "reasoning":
            return []
        case "function_call":
            return [assistantToolCallMessage(from: item, defaultName: item["name"] as? String ?? "function_call")]
        case "custom_tool_call":
            return [assistantToolCallMessage(
                from: item,
                defaultName: item["name"] as? String ?? "custom_tool",
                customToolReplay: true
            )]
        case "function_call_output", "custom_tool_call_output":
            guard let callID = item["call_id"] as? String ?? item["tool_call_id"] as? String else {
                let output = MoaProviderBridgeJSON.contentText(from: item["output"] ?? item["content"])
                return [["role": "user", "content": "Tool output without call_id:\n\(output)"]]
            }
            return [[
                "role": "tool",
                "tool_call_id": callID,
                "content": MoaProviderBridgeJSON.contentText(from: item["output"] ?? item["content"])
            ]]
        default:
            throw MoaProviderBridgeProtocolError.unsupportedInputItem(type)
        }
    }

    private static func assistantToolCallMessage(
        from item: [String: Any],
        defaultName: String,
        customToolReplay: Bool = false
    ) -> [String: Any] {
        let callID = item["call_id"] as? String ?? item["id"] as? String ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let name = item["name"] as? String ?? defaultName
        let functionName = name == "apply_patch" ? "apply_patch_batch" : name
        let arguments = customToolReplay
            ? customToolReplayArguments(name: name, item: item)
            : item["arguments"] as? String
                ?? item["input"] as? String
                ?? MoaProviderBridgeJSON.contentText(from: item["arguments"] ?? item["input"])
        return [
            "role": "assistant",
            "content": "",
            "tool_calls": [[
                "id": callID,
                "type": "function",
                "function": [
                    "name": functionName,
                    "arguments": arguments
                ]
            ]]
        ]
    }

    private static func customToolReplayArguments(name: String, item: [String: Any]) -> String {
        let input = item["input"] as? String
            ?? item["arguments"] as? String
            ?? MoaProviderBridgeJSON.contentText(from: item["input"] ?? item["arguments"])
        let key = name == "apply_patch" ? "patch" : "input"
        return (try? MoaProviderBridgeJSON.compactString(from: [key: input])) ?? "{}"
    }

    private static func copy(_ key: String, from source: [String: Any], to target: inout [String: Any]) {
        if let value = source[key] {
            target[key] = value
        }
    }

    private static func normalizedDeepSeekReasoningEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "max", "xhigh":
            return "max"
        default:
            return "high"
        }
    }

    private static func chatToolChoice(from value: Any) -> Any {
        if let text = value as? String {
            return text
        }
        guard let object = value as? [String: Any] else {
            return value
        }
        if let name = object["name"] as? String {
            return ["type": "function", "function": ["name": chatFunctionName(forResponsesToolName: name)]]
        }
        if let function = object["function"] as? [String: Any], let name = function["name"] as? String {
            return ["type": "function", "function": ["name": chatFunctionName(forResponsesToolName: name)]]
        }
        return value
    }

    private static func chatFunctionName(forResponsesToolName name: String) -> String {
        name == "apply_patch" ? "apply_patch_batch" : name
    }
}

enum MoaChatToResponsesConverter {
    static func convert(
        _ chatResponse: [String: Any],
        toolContext: MoaProviderBridgeToolContext = MoaProviderBridgeToolContext()
    ) throws -> [String: Any] {
        let responseID = responseID(from: chatResponse)
        let created = chatResponse["created"] as? Int ?? Int(Date().timeIntervalSince1970)
        let model = chatResponse["model"] as? String ?? "deepseek-chat"
        let choice = (chatResponse["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any] ?? [:]
        let finishReason = choice?["finish_reason"] as? String

        var output: [[String: Any]] = []
        let contentSplit = MoaProviderBridgeThinkSplitter.split(MoaProviderBridgeJSON.contentText(from: message["content"]))
        let combinedReasoning = [reasoningText(from: message), contentSplit.reasoning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !combinedReasoning.isEmpty {
            output.append(reasoningItem(text: combinedReasoning, responseID: responseID))
        }

        if !contentSplit.visible.isEmpty {
            output.append(messageItem(text: contentSplit.visible, responseID: responseID))
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            let toolItems = try outputItems(fromToolCalls: toolCalls, responseID: responseID, toolContext: toolContext)
            output.append(contentsOf: toolItems)
        }

        var response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": created,
            "model": model,
            "status": finishReason == "length" ? "incomplete" : "completed",
            "output": output
        ]

        if let usage = usage(from: chatResponse["usage"] as? [String: Any]) {
            response["usage"] = usage
        }
        if finishReason == "length" {
            response["incomplete_details"] = ["reason": "max_output_tokens"]
        } else if finishReason == "content_filter" {
            response["status"] = "incomplete"
            response["incomplete_details"] = ["reason": "content_filter"]
        } else if finishReason == "insufficient_system_resource" {
            response["status"] = "failed"
            response["error"] = [
                "code": "insufficient_system_resource",
                "message": "The upstream model stopped because of insufficient system resources."
            ]
        }

        return response
    }

    static func errorEnvelope(statusCode: Int, message: String, code: String? = nil) -> [String: Any] {
        [
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "failed",
            "error": [
                "code": code ?? "upstream_http_\(statusCode)",
                "message": message.isEmpty ? "Upstream request failed with HTTP \(statusCode)." : message
            ],
            "output": []
        ]
    }

    private static func outputItems(
        fromToolCalls toolCalls: [[String: Any]],
        responseID: String,
        toolContext: MoaProviderBridgeToolContext
    ) throws -> [[String: Any]] {
        let grouped = Dictionary(grouping: toolCalls) { call -> Bool in
            let name = functionName(from: call)
            return MoaApplyPatchProxyCodec.isApplyPatchProxyName(name)
        }

        var output: [[String: Any]] = []
        if let applyPatchCalls = grouped[true], !applyPatchCalls.isEmpty {
            let patch = try MoaApplyPatchProxyCodec.patchText(fromToolCalls: applyPatchCalls)
            output.append([
                "id": "ctc_\(responseID)_apply_patch",
                "type": "custom_tool_call",
                "status": "completed",
                "call_id": applyPatchCalls.first?["id"] as? String ?? "call_apply_patch",
                "name": "apply_patch",
                "input": patch
            ])
        }

        for call in grouped[false] ?? [] {
            let callID = call["id"] as? String ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let name = functionName(from: call)
            let arguments = functionArguments(from: call)
            if toolContext.treatsAsCustomTool(name) {
                let input = MoaApplyPatchProxyCodec.isApplyPatchProxyName(name)
                    ? arguments
                    : customToolInput(fromFunctionArguments: arguments)
                output.append([
                    "id": "ctc_\(callID)",
                    "type": "custom_tool_call",
                    "status": "completed",
                    "call_id": callID,
                    "name": name,
                    "input": input
                ])
            } else if let namespaceTool = toolContext.namespaceTool(for: name) {
                output.append([
                    "id": "fc_\(callID)",
                    "type": "function_call",
                    "status": "completed",
                    "call_id": callID,
                    "namespace": namespaceTool.namespace,
                    "name": namespaceTool.name,
                    "arguments": arguments
                ])
            } else {
                output.append([
                    "id": "fc_\(callID)",
                    "type": "function_call",
                    "status": "completed",
                    "call_id": callID,
                    "name": name,
                    "arguments": arguments
                ])
            }
        }
        return output
    }

    private static func responseID(from chatResponse: [String: Any]) -> String {
        let raw = chatResponse["id"] as? String ?? UUID().uuidString
        if raw.hasPrefix("resp_") {
            return raw
        }
        return "resp_\(raw.replacingOccurrences(of: "-", with: ""))"
    }

    private static func messageItem(text: String, responseID: String) -> [String: Any] {
        let itemID = "msg_\(responseID.replacingOccurrences(of: "resp_", with: ""))"
        return [
            "id": itemID,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": text,
                "annotations": []
            ]]
        ]
    }

    private static func reasoningItem(text: String, responseID: String) -> [String: Any] {
        [
            "id": "rs_\(responseID.replacingOccurrences(of: "resp_", with: ""))",
            "type": "reasoning",
            "status": "completed",
            "summary": [[
                "type": "summary_text",
                "text": text
            ]]
        ]
    }

    private static func reasoningText(from message: [String: Any]) -> String? {
        for key in ["reasoning_content", "reasoning", "reasoning_details"] {
            if let text = message[key] as? String {
                return text
            }
            if let array = message[key] as? [[String: Any]] {
                let text = array.map { MoaProviderBridgeJSON.contentText(from: $0["text"] ?? $0["content"]) }.joined()
                if !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func usage(from chatUsage: [String: Any]?) -> [String: Any]? {
        guard let chatUsage else { return nil }
        var usage: [String: Any] = [
            "input_tokens": chatUsage["prompt_tokens"] ?? 0,
            "output_tokens": chatUsage["completion_tokens"] ?? 0,
            "total_tokens": chatUsage["total_tokens"] ?? 0
        ]
        if let cached = chatUsage["prompt_cache_hit_tokens"] {
            usage["input_tokens_details"] = ["cached_tokens": cached]
        }
        if let details = chatUsage["completion_tokens_details"] as? [String: Any],
           let reasoningTokens = details["reasoning_tokens"] {
            usage["output_tokens_details"] = ["reasoning_tokens": reasoningTokens]
        }
        return usage
    }

    private static func functionName(from call: [String: Any]) -> String {
        ((call["function"] as? [String: Any])?["name"] as? String)
            ?? call["name"] as? String
            ?? "tool"
    }

    private static func functionArguments(from call: [String: Any]) -> String {
        ((call["function"] as? [String: Any])?["arguments"] as? String)
            ?? call["arguments"] as? String
            ?? "{}"
    }

    static func customToolInput(fromFunctionArguments arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = object["input"] as? String
        else {
            return arguments
        }
        return input
    }
}

enum MoaApplyPatchProxyCodec {
    static let proxyNames: [String] = [
        "apply_patch_add_file",
        "apply_patch_delete_file",
        "apply_patch_update_file",
        "apply_patch_replace_file",
        "apply_patch_batch"
    ]

    static func isApplyPatchProxyName(_ name: String) -> Bool {
        proxyNames.contains(name)
    }

    static func chatTools(fromResponsesTools tools: [[String: Any]]) throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        let namespaceAliases = MoaProviderBridgeToolContext.namespaceAliases(fromResponsesTools: tools)
        var namespaceAliasIndex = 0
        for tool in tools {
            let type = tool["type"] as? String ?? "function"
            let name = MoaProviderBridgeToolNaming.toolName(tool)
            if name == "apply_patch" {
                output.append(contentsOf: applyPatchFunctionTools())
            } else if type == "function" {
                output.append(chatFunctionTool(fromResponsesFunction: tool))
            } else if type == "namespace" {
                let alias = namespaceAliasIndex < namespaceAliases.count
                    ? namespaceAliases[namespaceAliasIndex].alias
                    : MoaProviderBridgeToolNaming.flattenedName(
                        namespace: MoaProviderBridgeToolNaming.namespaceName(tool) ?? "",
                        name: name
                    )
                namespaceAliasIndex += 1
                output.append(chatFunctionTool(fromResponsesNamespaceTool: tool, alias: alias))
            } else {
                output.append(chatFunctionToolForCustomTool(tool))
            }
        }
        return output
    }

    static func patchText(fromToolCalls toolCalls: [[String: Any]]) throws -> String {
        var hunks: [String] = []
        for call in toolCalls {
            let name = ((call["function"] as? [String: Any])?["name"] as? String) ?? call["name"] as? String ?? ""
            let arguments = ((call["function"] as? [String: Any])?["arguments"] as? String) ?? call["arguments"] as? String ?? "{}"
            let object = try argumentsObject(from: arguments)
            let patch = try patchBody(proxyName: name, arguments: object)
            hunks.append(patch)
        }

        let body = hunks
            .map { trimPatchEnvelope($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        guard !body.isEmpty else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("No apply_patch operation was produced.")
        }
        return "*** Begin Patch\n\(body)\n*** End Patch"
    }

    private static func applyPatchFunctionTools() -> [[String: Any]] {
        [
            functionTool(
                name: "apply_patch_add_file",
                description: "Create a new file by producing one apply_patch Add File operation.",
                properties: [
                    "path": stringSchema("Path of the new file."),
                    "content": stringSchema("Full file content to add.")
                ],
                required: ["path", "content"]
            ),
            functionTool(
                name: "apply_patch_delete_file",
                description: "Delete a file by producing one apply_patch Delete File operation.",
                properties: [
                    "path": stringSchema("Path of the file to delete.")
                ],
                required: ["path"]
            ),
            functionTool(
                name: "apply_patch_update_file",
                description: "Update an existing file with apply_patch hunk lines. The patch field must contain @@ markers and lines prefixed with space, +, or -.",
                properties: [
                    "path": stringSchema("Path of the file to update."),
                    "patch": stringSchema("Patch hunk body for this file, without Begin Patch or Update File envelope.")
                ],
                required: ["path", "patch"]
            ),
            functionTool(
                name: "apply_patch_replace_file",
                description: "Replace a file by deleting it and adding it again with new content.",
                properties: [
                    "path": stringSchema("Path of the file to replace."),
                    "content": stringSchema("Full replacement content.")
                ],
                required: ["path", "content"]
            ),
            functionTool(
                name: "apply_patch_batch",
                description: "Submit a complete apply_patch document when multiple file edits are needed.",
                properties: [
                    "patch": stringSchema("A complete apply_patch document including Begin Patch and End Patch.")
                ],
                required: ["patch"]
            )
        ]
    }

    private static func chatFunctionTool(fromResponsesFunction tool: [String: Any]) -> [String: Any] {
        var function: [String: Any]
        if let nested = tool["function"] as? [String: Any] {
            function = nested
        } else {
            function = [:]
            function["name"] = MoaProviderBridgeToolNaming.toolName(tool)
            function["description"] = tool["description"]
            function["parameters"] = tool["parameters"] ?? ["type": "object", "properties": [:]]
            if let strict = tool["strict"] {
                function["strict"] = strict
            }
        }
        return ["type": "function", "function": function]
    }

    private static func chatFunctionTool(fromResponsesNamespaceTool tool: [String: Any], alias: String) -> [String: Any] {
        var function: [String: Any] = [
            "name": alias,
            "description": tool["description"] ?? "Namespaced tool input.",
            "parameters": tool["parameters"] ?? ["type": "object", "properties": [:]]
        ]
        if let strict = tool["strict"] {
            function["strict"] = strict
        }
        return ["type": "function", "function": function]
    }

    private static func chatFunctionToolForCustomTool(_ tool: [String: Any]) -> [String: Any] {
        functionTool(
            name: MoaProviderBridgeToolNaming.toolName(tool),
            description: (tool["description"] as? String) ?? "Custom tool input.",
            properties: ["input": stringSchema("Raw custom tool input.")],
            required: ["input"]
        )
    }

    private static func functionTool(name: String, description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func argumentsObject(from arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Arguments are not UTF-8.")
        }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Arguments must be a JSON object.")
        }
        return object
    }

    private static func patchBody(proxyName: String, arguments: [String: Any]) throws -> String {
        switch proxyName {
        case "apply_patch_add_file":
            let path = try requiredString("path", in: arguments)
            let content = try requiredString("content", in: arguments)
            return "*** Add File: \(path)\n\(addedContentLines(content))"
        case "apply_patch_delete_file":
            let path = try requiredString("path", in: arguments)
            return "*** Delete File: \(path)"
        case "apply_patch_update_file":
            let path = try requiredString("path", in: arguments)
            let patch = try requiredString("patch", in: arguments)
            try validateUpdatePatchBody(patch)
            return "*** Update File: \(path)\n\(patch.trimmingCharacters(in: .newlines))"
        case "apply_patch_replace_file":
            let path = try requiredString("path", in: arguments)
            let content = try requiredString("content", in: arguments)
            return "*** Delete File: \(path)\n*** Add File: \(path)\n\(addedContentLines(content))"
        case "apply_patch_batch":
            let patch = try requiredString("patch", in: arguments)
            try validateCompletePatch(patch)
            return patch
        default:
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Unknown apply_patch proxy function: \(proxyName).")
        }
    }

    private static func requiredString(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Missing string field \(key).")
        }
        return value
    }

    private static func addedContentLines(_ content: String) -> String {
        let normalized = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }
        return lines.isEmpty ? "+" : lines.joined(separator: "\n")
    }

    private static func validateCompletePatch(_ patch: String) throws {
        let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("*** Begin Patch"), trimmed.hasSuffix("*** End Patch") else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Batch patch must include Begin Patch and End Patch.")
        }
    }

    private static func validateUpdatePatchBody(_ patch: String) throws {
        let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@@") else {
            throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Update patch must include at least one @@ hunk marker.")
        }
        for line in patch.components(separatedBy: "\n") {
            guard line.isEmpty
                || line.hasPrefix("@@")
                || line.hasPrefix(" ")
                || line.hasPrefix("+")
                || line.hasPrefix("-")
                || line == "*** End of File"
            else {
                throw MoaProviderBridgeProtocolError.malformedApplyPatchArguments("Invalid update hunk line: \(line).")
            }
        }
    }

    private static func trimPatchEnvelope(_ patch: String) -> String {
        var lines = patch.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "*** Begin Patch" {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "*** End Patch" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

final class MoaChatSSEToResponsesSSEConverter {
    private let responseID: String
    private let model: String
    private let createdAt: Int
    private let toolContext: MoaProviderBridgeToolContext
    private var sequence = 0
    private var started = false
    private var finished = false
    private var failed = false
    private var textStarted = false
    private var reasoningStarted = false
    private var nextOutputIndex = 0
    private var textOutputIndex: Int?
    private var reasoningOutputIndex: Int?
    private var text = ""
    private var reasoning = ""
    private var toolCalls: [Int: StreamedToolCall] = [:]
    private var inlineThinkBuffer = ""
    private var inlineThinking = false

    init(
        responseID: String = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        model: String = "deepseek-chat",
        createdAt: Int = Int(Date().timeIntervalSince1970),
        toolContext: MoaProviderBridgeToolContext = MoaProviderBridgeToolContext()
    ) {
        self.responseID = responseID
        self.model = model
        self.createdAt = createdAt
        self.toolContext = toolContext
    }

    func convert(_ sseText: String) throws -> String {
        var frames: [String] = []
        for payload in try payloads(from: sseText) {
            if payload == "[DONE]" {
                frames.append(contentsOf: try finish())
                frames.append("data: [DONE]\n\n")
                continue
            }
            frames.append(contentsOf: try ingest(jsonPayload: payload))
        }
        return frames.joined()
    }

    func ingest(jsonPayload payload: String) throws -> [String] {
        guard let data = payload.data(using: .utf8),
              let chunk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MoaProviderBridgeProtocolError.malformedSSE("Chunk is not a JSON object.")
        }

        var frames = startIfNeeded()
        if let error = chunk["error"] as? [String: Any] {
            failed = true
            finished = true
            frames.append(event("response.failed", [
                "response": MoaChatToResponsesConverter.errorEnvelope(
                    statusCode: 500,
                    message: (error["message"] as? String) ?? String(describing: error),
                    code: error["code"] as? String
                )
            ]))
            return frames
        }

        if let model = chunk["model"] as? String, model != self.model {
            _ = model
        }

        if let choices = chunk["choices"] as? [[String: Any]], choices.isEmpty,
           let usage = chunk["usage"] as? [String: Any],
           let mappedUsage = MoaChatToResponsesConverter.convertUsageForStreaming(usage) {
            frames.append(event("response.usage.delta", ["usage": mappedUsage]))
            return frames
        }

        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else {
            return frames
        }
        let delta = choice["delta"] as? [String: Any] ?? [:]

        if let reasoningDelta = delta["reasoning_content"] as? String, !reasoningDelta.isEmpty {
            frames.append(contentsOf: appendReasoningDelta(reasoningDelta))
        }

        if let contentDelta = delta["content"] as? String, !contentDelta.isEmpty {
            for segment in contentSegments(from: contentDelta, flush: false) {
                frames.append(contentsOf: appendContentSegment(segment))
            }
        }

        if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
            for toolDelta in toolDeltas {
                mergeToolDelta(toolDelta)
            }
        }

        return frames
    }

    func finish() throws -> [String] {
        guard !finished else { return [] }
        var frames = startIfNeeded()
        frames.append(contentsOf: flushInlineThinkBuffer())
        if failed {
            finished = true
            return frames
        }
        if reasoningStarted {
            let outputIndex = assignedReasoningOutputIndex()
            frames.append(event("response.reasoning_summary_text.done", [
                "item_id": reasoningItemID,
                "output_index": outputIndex,
                "summary_index": 0,
                "text": reasoning
            ]))
            frames.append(event("response.output_item.done", [
                "output_index": outputIndex,
                "item": [
                    "id": reasoningItemID,
                    "type": "reasoning",
                    "status": "completed",
                    "summary": [["type": "summary_text", "text": reasoning]]
                ]
            ]))
            reasoningStarted = false
        }
        if textStarted {
            let outputIndex = assignedTextOutputIndex()
            frames.append(event("response.output_text.done", [
                "item_id": messageItemID,
                "output_index": outputIndex,
                "content_index": 0,
                "text": text
            ]))
            frames.append(event("response.content_part.done", [
                "item_id": messageItemID,
                "output_index": outputIndex,
                "content_index": 0,
                "part": ["type": "output_text", "text": text, "annotations": []]
            ]))
            frames.append(event("response.output_item.done", [
                "output_index": outputIndex,
                "item": [
                    "id": messageItemID,
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": text, "annotations": []]]
                ]
            ]))
            textStarted = false
        }
        frames.append(contentsOf: try finishToolCalls())
        frames.append(event("response.completed", [
            "response": responseEnvelope(status: "completed")
        ]))
        finished = true
        return frames
    }

    private func startIfNeeded() -> [String] {
        guard !started else { return [] }
        started = true
        return [
            event("response.created", ["response": responseEnvelope(status: "in_progress")]),
            event("response.in_progress", ["response": responseEnvelope(status: "in_progress")])
        ]
    }

    private func startReasoningIfNeeded() -> [String] {
        guard !reasoningStarted else { return [] }
        reasoningStarted = true
        let outputIndex = assignedReasoningOutputIndex()
        return [
            event("response.output_item.added", [
                "output_index": outputIndex,
                "item": [
                    "id": reasoningItemID,
                    "type": "reasoning",
                    "status": "in_progress",
                    "summary": []
                ]
            ]),
            event("response.reasoning_summary_part.added", [
                "item_id": reasoningItemID,
                "output_index": outputIndex,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": ""]
            ])
        ]
    }

    private func startTextIfNeeded() -> [String] {
        guard !textStarted else { return [] }
        textStarted = true
        let outputIndex = assignedTextOutputIndex()
        return [
            event("response.output_item.added", [
                "output_index": outputIndex,
                "item": [
                    "id": messageItemID,
                    "type": "message",
                    "status": "in_progress",
                    "role": "assistant",
                    "content": []
                ]
            ]),
            event("response.content_part.added", [
                "item_id": messageItemID,
                "output_index": outputIndex,
                "content_index": 0,
                "part": ["type": "output_text", "text": "", "annotations": []]
            ])
        ]
    }

    private func appendReasoningDelta(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        var frames = startReasoningIfNeeded()
        reasoning += delta
        frames.append(event("response.reasoning_summary_text.delta", [
            "item_id": reasoningItemID,
            "output_index": assignedReasoningOutputIndex(),
            "summary_index": 0,
            "delta": delta
        ]))
        return frames
    }

    private func appendTextDelta(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        var frames = startTextIfNeeded()
        text += delta
        frames.append(event("response.output_text.delta", [
            "item_id": messageItemID,
            "output_index": assignedTextOutputIndex(),
            "content_index": 0,
            "delta": delta
        ]))
        return frames
    }

    private func appendContentSegment(_ segment: StreamedContentSegment) -> [String] {
        switch segment {
        case .reasoning(let delta):
            return appendReasoningDelta(delta)
        case .text(let delta):
            return appendTextDelta(delta)
        }
    }

    private func flushInlineThinkBuffer() -> [String] {
        guard !inlineThinkBuffer.isEmpty else { return [] }
        let pending = inlineThinkBuffer
        inlineThinkBuffer = ""
        return inlineThinking ? appendReasoningDelta(pending) : appendTextDelta(pending)
    }

    private func contentSegments(from delta: String, flush: Bool) -> [StreamedContentSegment] {
        inlineThinkBuffer += delta
        var segments: [StreamedContentSegment] = []

        while !inlineThinkBuffer.isEmpty {
            if inlineThinking {
                if let close = inlineThinkBuffer.range(of: "</think>") {
                    let before = String(inlineThinkBuffer[..<close.lowerBound])
                    if !before.isEmpty {
                        segments.append(.reasoning(before))
                    }
                    inlineThinkBuffer = String(inlineThinkBuffer[close.upperBound...])
                    inlineThinking = false
                    continue
                }

                let hold = flush ? 0 : partialTagSuffixLength(inlineThinkBuffer, tag: "</think>")
                let emitEnd = hold == 0
                    ? inlineThinkBuffer.endIndex
                    : inlineThinkBuffer.index(inlineThinkBuffer.endIndex, offsetBy: -hold)
                let emitText = String(inlineThinkBuffer[..<emitEnd])
                if !emitText.isEmpty {
                    segments.append(.reasoning(emitText))
                }
                inlineThinkBuffer = String(inlineThinkBuffer[emitEnd...])
                break
            }

            if let open = inlineThinkBuffer.range(of: "<think>") {
                let before = String(inlineThinkBuffer[..<open.lowerBound])
                if !before.isEmpty {
                    segments.append(.text(before))
                }
                inlineThinkBuffer = String(inlineThinkBuffer[open.upperBound...])
                inlineThinking = true
                continue
            }

            let hold = flush ? 0 : partialTagSuffixLength(inlineThinkBuffer, tag: "<think>")
            let emitEnd = hold == 0
                ? inlineThinkBuffer.endIndex
                : inlineThinkBuffer.index(inlineThinkBuffer.endIndex, offsetBy: -hold)
            let emitText = String(inlineThinkBuffer[..<emitEnd])
            if !emitText.isEmpty {
                segments.append(.text(emitText))
            }
            inlineThinkBuffer = String(inlineThinkBuffer[emitEnd...])
            break
        }

        return segments
    }

    private func partialTagSuffixLength(_ text: String, tag: String) -> Int {
        let maxLength = min(text.count, max(0, tag.count - 1))
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if tag.hasPrefix(String(text.suffix(length))) {
                return length
            }
        }
        return 0
    }

    private func finishToolCalls() throws -> [String] {
        var frames: [String] = []
        let orderedCalls = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
        guard !orderedCalls.isEmpty else { return frames }

        let applyPatchCalls = orderedCalls.filter { MoaApplyPatchProxyCodec.isApplyPatchProxyName($0.name) }
        let ordinaryCalls = orderedCalls.filter { !MoaApplyPatchProxyCodec.isApplyPatchProxyName($0.name) }
        if !applyPatchCalls.isEmpty {
            let rawCalls = applyPatchCalls.map(\.chatToolCallObject)
            let patch = try MoaApplyPatchProxyCodec.patchText(fromToolCalls: rawCalls)
            let outputIndex = assignedNextOutputIndex()
            let itemID = "ctc_\(responseID)_apply_patch"
            frames.append(event("response.output_item.added", [
                "output_index": outputIndex,
                "item": [
                    "id": itemID,
                    "type": "custom_tool_call",
                    "status": "in_progress",
                    "call_id": applyPatchCalls.first?.id ?? "call_apply_patch",
                    "name": "apply_patch",
                    "input": ""
                ]
            ]))
            frames.append(event("response.custom_tool_call_input.delta", [
                "output_index": outputIndex,
                "item_id": itemID,
                "delta": patch
            ]))
            frames.append(event("response.custom_tool_call_input.done", [
                "output_index": outputIndex,
                "item_id": itemID,
                "input": patch
            ]))
            frames.append(event("response.output_item.done", [
                "output_index": outputIndex,
                "item": [
                    "id": itemID,
                    "type": "custom_tool_call",
                    "status": "completed",
                    "call_id": applyPatchCalls.first?.id ?? "call_apply_patch",
                    "name": "apply_patch",
                    "input": patch
                ]
            ]))
        }

        for call in ordinaryCalls {
            let outputIndex = assignedNextOutputIndex()
            frames.append(contentsOf: finishOrdinaryToolCall(call, outputIndex: outputIndex))
        }
        toolCalls.removeAll()
        return frames
    }

    private func finishOrdinaryToolCall(_ call: StreamedToolCall, outputIndex: Int) -> [String] {
        if toolContext.treatsAsCustomTool(call.name) {
            let itemID = "ctc_\(call.id)"
            let input = MoaChatToResponsesConverter.customToolInput(fromFunctionArguments: call.arguments)
            return [
                event("response.output_item.added", [
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "custom_tool_call",
                        "status": "in_progress",
                        "call_id": call.id,
                        "name": call.name,
                        "input": ""
                    ]
                ]),
                event("response.custom_tool_call_input.delta", [
                    "output_index": outputIndex,
                    "item_id": itemID,
                    "delta": input
                ]),
                event("response.custom_tool_call_input.done", [
                    "output_index": outputIndex,
                    "item_id": itemID,
                    "input": input
                ]),
                event("response.output_item.done", [
                    "output_index": outputIndex,
                    "item": [
                        "id": itemID,
                        "type": "custom_tool_call",
                        "status": "completed",
                        "call_id": call.id,
                        "name": call.name,
                        "input": input
                    ]
                ])
            ]
        }

        let itemID = "fc_\(call.id)"
        let namespaceTool = toolContext.namespaceTool(for: call.name)
        let itemName = namespaceTool?.name ?? call.name
        var addedItem: [String: Any] = [
            "id": itemID,
            "type": "function_call",
            "status": "in_progress",
            "call_id": call.id,
            "name": itemName,
            "arguments": ""
        ]
        var doneItem = addedItem
        doneItem["status"] = "completed"
        doneItem["arguments"] = call.arguments
        if let namespaceTool {
            addedItem["namespace"] = namespaceTool.namespace
            doneItem["namespace"] = namespaceTool.namespace
        }

        return [
            event("response.output_item.added", [
                "output_index": outputIndex,
                "item": addedItem
            ]),
            event("response.function_call_arguments.delta", [
                "output_index": outputIndex,
                "item_id": itemID,
                "delta": call.arguments
            ]),
            event("response.function_call_arguments.done", [
                "output_index": outputIndex,
                "item_id": itemID,
                "arguments": call.arguments
            ]),
            event("response.output_item.done", [
                "output_index": outputIndex,
                "item": doneItem
            ])
        ]
    }

    private func mergeToolDelta(_ delta: [String: Any]) {
        let index = delta["index"] as? Int ?? 0
        var current = toolCalls[index] ?? StreamedToolCall(
            id: delta["id"] as? String ?? "call_\(index)",
            name: "",
            arguments: ""
        )
        if let id = delta["id"] as? String {
            current.id = id
        }
        if let function = delta["function"] as? [String: Any] {
            if let name = function["name"] as? String {
                current.name = name
            }
            if let arguments = function["arguments"] as? String {
                current.arguments += arguments
            }
        }
        toolCalls[index] = current
    }

    private var messageItemID: String {
        "msg_\(responseID.replacingOccurrences(of: "resp_", with: ""))"
    }

    private var reasoningItemID: String {
        "rs_\(responseID.replacingOccurrences(of: "resp_", with: ""))"
    }

    private func assignedTextOutputIndex() -> Int {
        if let textOutputIndex {
            return textOutputIndex
        }
        let index = assignedNextOutputIndex()
        textOutputIndex = index
        return index
    }

    private func assignedReasoningOutputIndex() -> Int {
        if let reasoningOutputIndex {
            return reasoningOutputIndex
        }
        let index = assignedNextOutputIndex()
        reasoningOutputIndex = index
        return index
    }

    private func assignedNextOutputIndex() -> Int {
        let index = nextOutputIndex
        nextOutputIndex += 1
        return index
    }

    private func responseEnvelope(status: String) -> [String: Any] {
        [
            "id": responseID,
            "object": "response",
            "created_at": createdAt,
            "model": model,
            "status": status,
            "output": []
        ]
    }

    private func event(_ type: String, _ payload: [String: Any]) -> String {
        var object = payload
        object["type"] = type
        object["sequence_number"] = sequence
        sequence += 1
        let data = (try? MoaProviderBridgeJSON.compactString(from: object)) ?? #"{"type":"error","message":"serialization failed"}"#
        return "data: \(data)\n\n"
    }

    private func payloads(from sseText: String) throws -> [String] {
        var payloads: [String] = []
        for frame in sseText.components(separatedBy: "\n\n") {
            let lines = frame.components(separatedBy: "\n")
            let dataLines = lines.compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            if !dataLines.isEmpty {
                payloads.append(dataLines.joined(separator: "\n"))
            }
        }
        return payloads
    }

    private struct StreamedToolCall {
        var id: String
        var name: String
        var arguments: String

        var chatToolCallObject: [String: Any] {
            [
                "id": id,
                "type": "function",
                "function": [
                    "name": name,
                    "arguments": arguments
                ]
            ]
        }
    }

    private enum StreamedContentSegment {
        case reasoning(String)
        case text(String)
    }
}

private extension MoaChatToResponsesConverter {
    static func convertUsageForStreaming(_ chatUsage: [String: Any]) -> [String: Any]? {
        let response = try? MoaChatToResponsesConverter.convert(["usage": chatUsage, "choices": []])
        return response?["usage"] as? [String: Any]
    }
}
