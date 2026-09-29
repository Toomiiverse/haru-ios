import Foundation

enum SpeechPart: Sendable {
    case format(Double)
    case pcm(Data)
    case file(Data)
}

/// Starts fetching while earlier lines are playing. Cancellation belongs to
/// the queued line too, so interrupting her also stops prefetched requests.
struct SpeechDownload: Sendable {
    let parts: AsyncThrowingStream<SpeechPart, Error>
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}

enum HaruError: LocalizedError {
    /// A 401: the cookie is gone or was never set. The app goes back to sign-in.
    case signedOut
    /// Any other refusal, with the server's own wording.
    case server(Int, String)
    case badAddress

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in first."
        case .server(_, let message): return message
        case .badAddress: return "That is not a web address."
        }
    }
}

/// The phone's side of electron/webserver.ts. Cookies do the remembering:
/// /api/login sets `haru_device`, URLSession's shared jar keeps it across
/// launches, and every request here carries it without being told to.
struct HaruClient: Sendable {
    let base: URL
    let session: URLSession

    /// `quick`: a short timeout and no waiting for connectivity, for the
    /// notification delegate's reply inside iOS's thirty-second background
    /// budget. The server keeps answering after the socket drops, so the caller
    /// must not retry — a retry would be a second message.
    init(base: URL, quick: Bool = false) {
        self.base = base
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        // A reply can take a while to start when she is thinking; this is the
        // gap allowed between bytes, not the whole call.
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        // Her model is 29 MB across forty files and marked immutable by the
        // server; a cache this size keeps it on the phone between launches.
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        if quick {
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 25
            config.waitsForConnectivity = false
        }
        session = URLSession(configuration: config)
    }

    private func request(_ path: String, method: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            ?? URLComponents()
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url ?? base)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        if http.statusCode == 401 { throw HaruError.signedOut }
        let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            ?? "Something went wrong (\(http.statusCode))."
        throw HaruError.server(http.statusCode, message)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(for: request(path, method: "GET"))
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Every POST past the login must be JSON, or the server answers 415 —
    /// including the ones with nothing to say, which send `{}`.
    func post<T: Decodable>(_ path: String, _ body: [String: JSONValue] = [:]) async throws -> T {
        var req = request(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A raw body — a recording, a file — for the two routes that take one.
    func upload<T: Decodable>(_ path: String, data: Data, type: String, query: [String: String] = [:]) async throws -> T {
        var req = request(path, method: "POST", query: query)
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        let (out, response) = try await session.upload(for: req, from: data)
        try Self.check(response, out)
        return try JSONDecoder().decode(T.self, from: out)
    }

    /// Bytes back rather than JSON: her voice, her face, her portrait.
    func bytes(_ path: String, post body: [String: JSONValue]? = nil, query: [String: String] = [:]) async throws -> Data {
        var req = request(path, method: body == nil ? "GET" : "POST", query: query)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        return data
    }

    /// Breeze's first PCM reaches the player immediately. Servers or voices
    /// without PCM support still return a regular audio file on this route.
    func speech(_ text: String, emotion: String?) -> SpeechDownload {
        let (parts, continuation) = AsyncThrowingStream<SpeechPart, Error>.makeStream()
        let task = Task {
            do {
                var query = ["text": text, "format": "pcm"]
                if let emotion { query["emotion"] = emotion }
                var req = request("/api/speak", method: "GET", query: query)
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: req)
                guard let http = response as? HTTPURLResponse else { throw HaruError.server(502, "No voice response.") }
                if !(200..<300).contains(http.statusCode) {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    try Self.check(response, data)
                }
                let pcm = http.mimeType == "audio/pcm"
                if pcm {
                    guard let value = http.value(forHTTPHeaderField: "X-Haru-Sample-Rate"),
                          let rate = Double(value), (8_000...192_000).contains(rate) else {
                        throw HaruError.server(502, "Unknown voice sample rate.")
                    }
                    continuation.yield(.format(rate))
                }
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if pcm, data.count >= 4096 {
                        try Task.checkCancellation()
                        continuation.yield(.pcm(data))
                        data = Data()
                    }
                }
                try Task.checkCancellation()
                if !data.isEmpty { continuation.yield(pcm ? .pcm(data) : .file(data)) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
        return SpeechDownload(parts: parts, task: task)
    }

    /// The server-sent stream behind /api/chat/stream and /api/chat/retry: one
    /// `data: {...}` line per event, blank lines between, nothing else.
    func stream(_ path: String, _ body: [String: JSONValue]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request(path, method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try Self.check(response, data)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Forgets the cookies for this server — the client half of signing out.
    func forgetCookies() {
        for cookie in HTTPCookieStorage.shared.cookies(for: base) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
