import Darwin
import Foundation

struct MoaProviderBridgeServerConfiguration: Equatable {
    var profileID: String
    var providerName: String
    var providerKind: MoaProviderKind
    var upstreamProtocol: MoaProviderUpstreamProtocol
    var bridgeMode: MoaProviderBridgeMode
    var upstreamBaseURL: String
    var apiKey: String
    var model: String
    var bridgeToken: String
    var port: Int
    var models: [String]
    var reasoningMode: MoaProviderReasoningMode

    init(profile: ConfigProfile) {
        profileID = profile.id
        providerName = profile.name
        providerKind = profile.resolvedProviderKind
        upstreamProtocol = profile.resolvedUpstreamProtocol
        bridgeMode = profile.resolvedBridgeMode
        upstreamBaseURL = profile.resolvedUpstreamBaseURL
        apiKey = profile.apiKey
        model = profile.resolvedModel ?? MoaProviderBridgeDefaults.deepSeekChatModel
        bridgeToken = profile.bridgeToken ?? ""
        port = profile.resolvedBridgePort
        models = profile.models ?? [
            MoaProviderBridgeDefaults.deepSeekChatModel,
            MoaProviderBridgeDefaults.deepSeekReasonerModel
        ]
        reasoningMode = profile.reasoningMode ?? .auto
    }
}

struct MoaProviderBridgeServerSnapshot: Equatable {
    var isRunning: Bool
    var port: Int?
    var profileID: String?
    var providerName: String?
    var tokenHashPrefix: String?
}

private struct MoaProviderBridgeForwardResult {
    var response: MoaProviderBridgeHTTPResponse
    var upstreamStatus: Int?
    var errorCode: String?
}

enum MoaProviderBridgeServerError: LocalizedError {
    case bindFailed(Int32)
    case invalidRequest
    case missingBridgeToken
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .bindFailed(let errnoValue):
            return "Moa provider bridge could not bind to 127.0.0.1: \(String(cString: strerror(errnoValue)))."
        case .invalidRequest:
            return "Moa provider bridge received an invalid HTTP request."
        case .missingBridgeToken:
            return "Moa provider bridge profile is missing its local bridge token."
        case .invalidPort(let port):
            return MoaProviderBridgePortError.outOfRange(port).localizedDescription
        }
    }
}

final class MoaProviderBridgeServer: @unchecked Sendable {
    private let urlSession: URLSession
    private let diagnostics: MoaProviderBridgeDiagnostics
    private let acceptQueue = DispatchQueue(label: "moa.provider-bridge.accept")
    private let workerQueue = DispatchQueue(label: "moa.provider-bridge.worker", attributes: .concurrent)
    private let lifecycleLock = NSRecursiveLock()
    private let stateLock = NSRecursiveLock()
    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var configuration: MoaProviderBridgeServerConfiguration?
    private(set) var activePort: Int?

    init(urlSession: URLSession = .shared, diagnostics: MoaProviderBridgeDiagnostics = .shared) {
        self.urlSession = urlSession
        self.diagnostics = diagnostics
    }

    deinit {
        stop()
    }

    func start(configuration: MoaProviderBridgeServerConfiguration) throws -> Int {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let bridgeToken = configuration.bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bridgeToken.isEmpty else {
            throw MoaProviderBridgeServerError.missingBridgeToken
        }

        stop()
        let requestedPort: Int
        do {
            requestedPort = try MoaProviderBridgePort.validated(configuration.port)
        } catch {
            throw MoaProviderBridgeServerError.invalidPort(configuration.port)
        }
        let (unclampedProbeEnd, overflowed) = requestedPort.addingReportingOverflow(50)
        let probeEnd = overflowed ? 65535 : min(65535, unclampedProbeEnd)
        let candidates = requestedPort == 0 ? [0] : Array(requestedPort...probeEnd)
        var lastErrno: Int32 = 0

        for candidate in candidates {
            do {
                let (fd, port) = try bindLoopbackSocket(port: candidate)
                try listenOnSocket(fd)

                var mutableConfiguration = configuration
                mutableConfiguration.port = port
                mutableConfiguration.bridgeToken = bridgeToken

                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
                source.setEventHandler { [weak self] in
                    self?.acceptAvailableConnections()
                }
                source.setCancelHandler {
                    close(fd)
                }
                stateLock.lock()
                socketFD = fd
                self.configuration = mutableConfiguration
                activePort = port
                acceptSource = source
                stateLock.unlock()
                source.resume()
                diagnostics.bridgeStarted(
                    profileID: mutableConfiguration.profileID,
                    providerName: mutableConfiguration.providerName,
                    providerKind: mutableConfiguration.providerKind.rawValue,
                    bridgeMode: mutableConfiguration.bridgeMode.rawValue,
                    localPort: port,
                    upstreamProtocol: mutableConfiguration.upstreamProtocol.rawValue,
                    upstreamBaseURL: mutableConfiguration.upstreamBaseURL,
                    model: mutableConfiguration.model
                )
                return port
            } catch MoaProviderBridgeServerError.bindFailed(let errnoValue) {
                lastErrno = errnoValue
                continue
            }
        }

        throw MoaProviderBridgeServerError.bindFailed(lastErrno == 0 ? errno : lastErrno)
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        let source = acceptSource
        acceptSource = nil
        configuration = nil
        activePort = nil
        if source == nil, socketFD >= 0 {
            close(socketFD)
        }
        socketFD = -1
        stateLock.unlock()
        source?.cancel()
        diagnostics.bridgeStopped()
    }

    func snapshot() -> MoaProviderBridgeServerSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return MoaProviderBridgeServerSnapshot(
            isRunning: acceptSource != nil,
            port: activePort,
            profileID: configuration?.profileID,
            providerName: configuration?.providerName,
            tokenHashPrefix: configuration?.bridgeToken.isEmpty == false
                ? MoaProviderBridgeToken.sha256Prefix(configuration?.bridgeToken ?? "")
                : nil
        )
    }

    private func bindLoopbackSocket(port: Int) throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MoaProviderBridgeServerError.bindFailed(errno)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errnoValue = errno
            close(fd)
            throw MoaProviderBridgeServerError.bindFailed(errnoValue)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLength)
            }
        }
        guard getsocknameResult == 0 else {
            let errnoValue = errno
            close(fd)
            throw MoaProviderBridgeServerError.bindFailed(errnoValue)
        }

        return (fd, Int(UInt16(bigEndian: boundAddress.sin_port)))
    }

    private func listenOnSocket(_ fd: Int32) throws {
        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let errnoValue = errno
            close(fd)
            throw MoaProviderBridgeServerError.bindFailed(errnoValue)
        }
    }

    private func acceptAvailableConnections() {
        while true {
            stateLock.lock()
            let listenFD = socketFD
            stateLock.unlock()
            guard listenFD >= 0 else { return }

            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                return
            }
            configureClientSocket(clientFD)
            let flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
            }

            workerQueue.async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    private func configureClientSocket(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleConnection(_ clientFD: Int32) {
        var shouldClose = true
        let requestStartedAt = Date()
        var observedRequest: MoaProviderBridgeHTTPRequest?
        var observedConfig: MoaProviderBridgeServerConfiguration?
        var requestDiagnosticRecorded = false
        defer {
            if shouldClose {
                close(clientFD)
            }
        }
        do {
            guard let request = try MoaProviderBridgeHTTPRequest.read(from: clientFD) else {
                try MoaProviderBridgeHTTPResponse(statusCode: 400, json: errorJSON("invalid_request", "Invalid HTTP request.")).write(to: clientFD)
                return
            }
            observedRequest = request

            let config = try currentConfiguration()
            observedConfig = config
            guard isAuthorized(request, token: config.bridgeToken) else {
                recordRequestSummary(
                    request,
                    config: config,
                    startedAt: requestStartedAt,
                    statusCode: 401,
                    errorCode: "unauthorized"
                )
                requestDiagnosticRecorded = true
                try MoaProviderBridgeHTTPResponse(statusCode: 401, json: errorJSON("unauthorized", "Invalid Moa provider bridge token.")).write(to: clientFD)
                return
            }

            if request.method == "GET", request.normalizedPath == "/v1/models" || request.normalizedPath == "/models" {
                recordRequestSummary(request, config: config, startedAt: requestStartedAt, statusCode: 200)
                requestDiagnosticRecorded = true
                try MoaProviderBridgeHTTPResponse(statusCode: 200, json: modelsJSON(config)).write(to: clientFD)
                return
            }

            guard request.method == "POST",
                  request.normalizedPath == "/v1/responses" || request.normalizedPath == "/responses"
            else {
                recordRequestSummary(
                    request,
                    config: config,
                    startedAt: requestStartedAt,
                    statusCode: 404,
                    errorCode: "not_found"
                )
                requestDiagnosticRecorded = true
                try MoaProviderBridgeHTTPResponse(statusCode: 404, json: errorJSON("not_found", "Unsupported Moa provider bridge endpoint.")).write(to: clientFD)
                return
            }

            let object = try MoaProviderBridgeJSON.object(from: request.body)
            var convertedChatRequest = try MoaResponsesToChatConverter.convert(object, reasoningMode: config.reasoningMode)
            convertedChatRequest["model"] = object["model"] ?? config.model
            let chatRequest = convertedChatRequest
            let toolContext = (object["tools"] as? [[String: Any]])
                .map { MoaProviderBridgeToolContext.fromResponsesTools($0) }
                ?? MoaProviderBridgeToolContext()

            if (chatRequest["stream"] as? Bool) == true {
                shouldClose = false
                Task { [weak self] in
                    defer { close(clientFD) }
                    guard let self else { return }
                    await self.handleStreamingResponsesRequest(
                        chatRequest,
                        request: request,
                        config: config,
                        toolContext: toolContext,
                        clientFD: clientFD,
                        startedAt: requestStartedAt
                    )
                }
                requestDiagnosticRecorded = true
            } else {
                shouldClose = false
                Task { [weak self] in
                    defer { close(clientFD) }
                    guard let self else { return }
                    var recorded = false
                    do {
                        let result = try await self.forwardNonStreaming(chatRequest, config: config, toolContext: toolContext)
                        self.recordRequestSummary(
                            request,
                            config: config,
                            startedAt: requestStartedAt,
                            statusCode: result.response.statusCode,
                            upstreamStatus: result.upstreamStatus,
                            errorCode: result.errorCode
                        )
                        recorded = true
                        try result.response.write(to: clientFD)
                    } catch {
                        if !recorded {
                            self.recordRequestSummary(
                                request,
                                config: config,
                                startedAt: requestStartedAt,
                                statusCode: 500,
                                errorCode: "bridge_error"
                            )
                        }
                        let response = MoaProviderBridgeHTTPResponse(
                            statusCode: 500,
                            json: errorJSON("bridge_error", error.localizedDescription)
                        )
                        try? response.write(to: clientFD)
                    }
                }
                requestDiagnosticRecorded = true
            }
        } catch {
            if !requestDiagnosticRecorded, let request = observedRequest, let config = observedConfig {
                recordRequestSummary(
                    request,
                    config: config,
                    startedAt: requestStartedAt,
                    statusCode: 500,
                    errorCode: "bridge_error"
                )
            }
            let response = MoaProviderBridgeHTTPResponse(
                statusCode: 500,
                json: errorJSON("bridge_error", error.localizedDescription)
            )
            try? response.write(to: clientFD)
        }
    }

    private func currentConfiguration() throws -> MoaProviderBridgeServerConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let configuration else {
            throw MoaProviderBridgeServerError.invalidRequest
        }
        return configuration
    }

    private func isAuthorized(_ request: MoaProviderBridgeHTTPRequest, token: String) -> Bool {
        guard let authorization = request.header("authorization") else {
            return false
        }
        let expected = "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))"
        return authorization.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    private func recordRequestSummary(
        _ request: MoaProviderBridgeHTTPRequest,
        config: MoaProviderBridgeServerConfiguration,
        startedAt: Date,
        statusCode: Int,
        upstreamStatus: Int? = nil,
        errorCode: String? = nil,
        stream: Bool = false
    ) {
        diagnostics.recordRequest(
            method: request.method,
            path: request.normalizedPath,
            localPort: config.port,
            upstreamBaseURL: config.upstreamBaseURL,
            upstreamProtocol: config.upstreamProtocol.rawValue,
            status: statusCode,
            upstreamStatus: upstreamStatus,
            errorCode: errorCode,
            stream: stream,
            startedAt: startedAt
        )
    }

    private func forwardNonStreaming(
        _ chatRequest: [String: Any],
        config: MoaProviderBridgeServerConfiguration,
        toolContext: MoaProviderBridgeToolContext
    ) async throws -> MoaProviderBridgeForwardResult {
        var request = try upstreamChatRequest(chatRequest, config: config)
        request.httpBody = try MoaProviderBridgeJSON.data(from: chatRequest)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return MoaProviderBridgeForwardResult(
                response: MoaProviderBridgeHTTPResponse(statusCode: 502, json: errorJSON("invalid_upstream_response", "Upstream did not return an HTTP response.")),
                upstreamStatus: nil,
                errorCode: "invalid_upstream_response"
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return MoaProviderBridgeForwardResult(
                response: MoaProviderBridgeHTTPResponse(
                    statusCode: httpResponse.statusCode,
                    json: MoaChatToResponsesConverter.errorEnvelope(
                        statusCode: httpResponse.statusCode,
                        message: upstreamErrorMessage(from: data)
                    )
                ),
                upstreamStatus: httpResponse.statusCode,
                errorCode: "upstream_http_status"
            )
        }

        let chatResponse = try MoaProviderBridgeJSON.object(from: data)
        let responsesResponse = try MoaChatToResponsesConverter.convert(chatResponse, toolContext: toolContext)
        return MoaProviderBridgeForwardResult(
            response: MoaProviderBridgeHTTPResponse(statusCode: 200, json: responsesResponse),
            upstreamStatus: httpResponse.statusCode,
            errorCode: nil
        )
    }

    private func handleStreamingResponsesRequest(
        _ chatRequest: [String: Any],
        request localRequest: MoaProviderBridgeHTTPRequest,
        config: MoaProviderBridgeServerConfiguration,
        toolContext: MoaProviderBridgeToolContext,
        clientFD: Int32,
        startedAt: Date
    ) async {
        var statusCode = 500
        var upstreamStatus: Int?
        var errorCode: String? = "bridge_error"
        defer {
            recordRequestSummary(
                localRequest,
                config: config,
                startedAt: startedAt,
                statusCode: statusCode,
                upstreamStatus: upstreamStatus,
                errorCode: errorCode,
                stream: true
            )
        }
        do {
            var request = try upstreamChatRequest(chatRequest, config: config)
            request.httpBody = try MoaProviderBridgeJSON.data(from: chatRequest)
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                statusCode = 502
                errorCode = "invalid_upstream_response"
                try MoaProviderBridgeHTTPResponse(statusCode: 502, json: errorJSON("invalid_upstream_response", "Upstream did not return an HTTP response.")).write(to: clientFD)
                return
            }
            upstreamStatus = httpResponse.statusCode

            guard (200..<300).contains(httpResponse.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                }
                statusCode = httpResponse.statusCode
                errorCode = "upstream_http_status"
                try MoaProviderBridgeHTTPResponse(
                    statusCode: httpResponse.statusCode,
                    json: MoaChatToResponsesConverter.errorEnvelope(
                        statusCode: httpResponse.statusCode,
                        message: upstreamErrorMessage(from: body)
                    )
                ).write(to: clientFD)
                return
            }

            try MoaProviderBridgeHTTPResponse.streamingHeaders().writeHeaders(to: clientFD)
            statusCode = 200
            errorCode = nil
            let converter = MoaChatSSEToResponsesSSEConverter(model: config.model, toolContext: toolContext)
            var pendingFrameLines: [String] = []
            var sawDone = false
            for try await line in bytes.lines {
                if line.isEmpty {
                    if !pendingFrameLines.isEmpty {
                        sawDone = try await writeSSEFrame(pendingFrameLines, converter: converter, clientFD: clientFD) || sawDone
                        pendingFrameLines.removeAll()
                    }
                } else {
                    if line.hasPrefix("data:"), isCompleteSSEFrame(pendingFrameLines) {
                        sawDone = try await writeSSEFrame(pendingFrameLines, converter: converter, clientFD: clientFD) || sawDone
                        pendingFrameLines.removeAll()
                    }
                    pendingFrameLines.append(line)
                }
            }
            if !pendingFrameLines.isEmpty {
                sawDone = try await writeSSEFrame(pendingFrameLines, converter: converter, clientFD: clientFD) || sawDone
            }
            if !sawDone {
                for frame in try converter.finish() {
                    try MoaProviderBridgeHTTPResponse.writeRaw(frame, to: clientFD)
                }
                try MoaProviderBridgeHTTPResponse.writeRaw("data: [DONE]\n\n", to: clientFD)
            }
        } catch {
            statusCode = 500
            errorCode = "bridge_error"
            let payload = MoaProviderBridgeHTTPResponse.sseEvent([
                "type": "response.failed",
                "response": MoaChatToResponsesConverter.errorEnvelope(statusCode: 500, message: error.localizedDescription)
            ])
            try? MoaProviderBridgeHTTPResponse.writeRaw(payload, to: clientFD)
            try? MoaProviderBridgeHTTPResponse.writeRaw("data: [DONE]\n\n", to: clientFD)
        }
    }

    private func writeSSEFrame(
        _ lines: [String],
        converter: MoaChatSSEToResponsesSSEConverter,
        clientFD: Int32
    ) async throws -> Bool {
        guard let payload = ssePayload(from: lines), !payload.isEmpty else { return false }
        if payload == "[DONE]" {
            for frame in try converter.finish() {
                try MoaProviderBridgeHTTPResponse.writeRaw(frame, to: clientFD)
            }
            try MoaProviderBridgeHTTPResponse.writeRaw("data: [DONE]\n\n", to: clientFD)
            return true
        }
        do {
            for frame in try converter.ingest(jsonPayload: payload) {
                try MoaProviderBridgeHTTPResponse.writeRaw(frame, to: clientFD)
            }
        } catch {
            throw MoaProviderBridgeProtocolError.malformedSSE(error.localizedDescription)
        }
        return false
    }

    private func isCompleteSSEFrame(_ lines: [String]) -> Bool {
        guard let payload = ssePayload(from: lines), !payload.isEmpty else {
            return false
        }
        if payload == "[DONE]" {
            return true
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return object is [String: Any]
    }

    private func ssePayload(from lines: [String]) -> String? {
        let payload = lines
            .filter { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return payload.isEmpty ? nil : payload
    }

    private func upstreamChatRequest(
        _ body: [String: Any],
        config: MoaProviderBridgeServerConfiguration
    ) throws -> URLRequest {
        let url = try MoaProviderBridgeEndpointNormalizer.chatCompletionsURL(baseURL: config.upstreamBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func modelsJSON(_ config: MoaProviderBridgeServerConfiguration) -> [String: Any] {
        [
            "object": "list",
            "data": config.models.map { model in
                [
                    "id": model,
                    "object": "model",
                    "created": 0,
                    "owned_by": config.providerName
                ]
            }
        ]
    }

    private func errorJSON(_ code: String, _ message: String) -> [String: Any] {
        [
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func upstreamErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct MoaProviderBridgeHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var normalizedPath: String {
        URLComponents(string: path)?.path ?? path
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func read(from fd: Int32) throws -> MoaProviderBridgeHTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        let maxBytes = 8 * 1024 * 1024

        while headerEnd == nil {
            let readCount = recv(fd, &buffer, buffer.count, 0)
            if readCount <= 0 {
                return nil
            }
            data.append(buffer, count: readCount)
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            if data.count > maxBytes {
                throw MoaProviderBridgeServerError.invalidRequest
            }
        }

        guard let headerEnd else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MoaProviderBridgeServerError.invalidRequest
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw MoaProviderBridgeServerError.invalidRequest
        }
        lines.removeFirst()
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw MoaProviderBridgeServerError.invalidRequest
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLengthText = headers["content-length"] ?? "0"
        guard let contentLength = Int(contentLengthText), contentLength >= 0, contentLength <= maxBytes else {
            throw MoaProviderBridgeServerError.invalidRequest
        }
        let bodyStart = headerEnd.upperBound
        var body = Data(data[bodyStart...])
        while body.count < contentLength {
            let readCount = recv(fd, &buffer, min(buffer.count, contentLength - body.count), 0)
            if readCount <= 0 {
                throw MoaProviderBridgeServerError.invalidRequest
            }
            body.append(buffer, count: readCount)
            if body.count > maxBytes {
                throw MoaProviderBridgeServerError.invalidRequest
            }
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        return MoaProviderBridgeHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }
}

private struct MoaProviderBridgeHTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    init(statusCode: Int, json: [String: Any]) {
        self.statusCode = statusCode
        headers = ["Content-Type": "application/json; charset=utf-8"]
        body = (try? MoaProviderBridgeJSON.data(from: json)) ?? Data(#"{"error":{"message":"serialization failed"}}"#.utf8)
    }

    private init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func streamingHeaders() -> MoaProviderBridgeHTTPResponse {
        MoaProviderBridgeHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache",
                "Connection": "close"
            ],
            body: Data()
        )
    }

    func write(to fd: Int32) throws {
        try writeHeaders(to: fd)
        if !body.isEmpty {
            try Self.writeRaw(body, to: fd)
        }
    }

    func writeHeaders(to fd: Int32) throws {
        var headerText = "HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\n"
        var responseHeaders = headers
        if !(body.isEmpty && headers["Content-Type"]?.hasPrefix("text/event-stream") == true) {
            responseHeaders["Content-Length"] = "\(body.count)"
        }
        responseHeaders["Connection"] = responseHeaders["Connection"] ?? "close"
        for (name, value) in responseHeaders {
            headerText += "\(name): \(value)\r\n"
        }
        headerText += "\r\n"
        try Self.writeRaw(headerText, to: fd)
    }

    static func sseEvent(_ object: [String: Any]) -> String {
        let data = (try? MoaProviderBridgeJSON.compactString(from: object)) ?? #"{"type":"response.failed"}"#
        return "data: \(data)\n\n"
    }

    static func writeRaw(_ string: String, to fd: Int32) throws {
        try writeRaw(Data(string.utf8), to: fd)
    }

    static func writeRaw(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                if count < 0 && errno == EINTR {
                    continue
                }
                if count <= 0 {
                    throw MoaProviderBridgeServerError.invalidRequest
                }
                sent += count
            }
        }
    }

    private func statusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
