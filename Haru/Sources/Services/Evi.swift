import Foundation

/// One call through the server's call socket (electron/webserver.ts,
/// `/api/evi/session`): the microphone up as raw 16 kHz PCM frames, and back
/// down what Hume heard, what she said, her voice a sentence at a time as
/// WAV, and the two events that shape a turn — she was talked over, she has
/// finished. The server owns the Hume side; the phone never sees a key.
///
/// A call runs only while the mic is on. Typed messages keep their own voice.
final class EviCall: @unchecked Sendable {
    enum Event {
        case ready
        case refused(String)
        /// What Hume heard them say. Interim while they are still talking.
        case heard(String, interim: Bool)
        /// One sentence of hers, as text, ahead of its audio.
        case said(String, id: String)
        /// Her voice for one sentence, as WAV bytes.
        case voice(Data)
        case turnEnded
        case interrupted
        case failed(String)
        case ended(String)
    }

    private let task: URLSessionWebSocketTask
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var closed = false

    init(client: HaruClient, onEvent: @escaping @Sendable (Event) -> Void) {
        var parts = URLComponents(url: client.base.appendingPathComponent("/api/evi/session"), resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: parts.url ?? client.base)
        // The cookie by hand: a WebSocket handshake does not reliably read the
        // session's jar, and without it the server answers 401 and hangs up.
        if let cookies = HTTPCookieStorage.shared.cookies(for: client.base) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        task = client.session.webSocketTask(with: request)
        self.onEvent = onEvent
    }

    func start() {
        task.resume()
        receive()
    }

    /// A stretch of the microphone: 16 kHz mono PCM16, no header.
    func send(_ pcm: Data) {
        task.send(.data(pcm)) { _ in }
    }

    /// Hangs up. The server's own `ended` for this is not reported back —
    /// the phone already knows.
    func stop() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        let task = self.task
        task.send(.string("{\"type\":\"stop\"}")) { _ in
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(error.localizedDescription)
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(CallEvent.self, from: data) else { return }
        switch event.type {
        case "ready": onEvent(.ready)
        case "refused": onEvent(.refused(event.reason ?? "The call could not be placed."))
        case "user_message": onEvent(.heard(event.text ?? "", interim: event.interim ?? false))
        case "assistant_message": onEvent(.said(event.text ?? "", id: event.id ?? ""))
        case "audio_output":
            if let encoded = event.data, let wav = Data(base64Encoded: encoded) { onEvent(.voice(wav)) }
        case "assistant_end": onEvent(.turnEnded)
        case "user_interruption": onEvent(.interrupted)
        case "error": onEvent(.failed(event.message ?? "Something went wrong on the call."))
        case "ended": finish(event.reason ?? "The call ended.")
        default: break
        }
    }

    private func finish(_ reason: String) {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        onEvent(.ended(reason))
    }
}

/// One frame down the call socket. Every field but `type` belongs to some
/// events and not others.
private struct CallEvent: Decodable {
    let type: String
    let reason: String?
    let text: String?
    let interim: Bool?
    let id: String?
    let data: String?
    let message: String?
}
