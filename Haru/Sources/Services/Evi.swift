import Foundation

/// One call through the server's call socket (electron/webserver.ts,
/// `/api/call/session`): the microphone up as raw 16 kHz PCM frames, and back
/// down what was heard, what she said, her voice, and the events that shape
/// a turn — she was talked over, she has finished. Whichever engine the
/// server runs (its own ears and voice, or Hume's), the phone never sees a
/// key. Her voice comes either as raw PCM between `audio_start` and
/// `audio_end` — the phone says `hello` with `pcm: true` to get it that way,
/// and plays it as it arrives — or as whole sentences of WAV.
///
/// A call runs only while the mic is on. Typed messages keep their own voice.
final class EviCall: @unchecked Sendable {
    enum Event {
        case ready(pushToTalk: Bool)
        case inputMode(manual: Bool)
        case inputGate(active: Bool)
        case refused(String)
        /// What was heard them say. Interim while they are still talking.
        case heard(String, interim: Bool)
        /// One sentence of hers, as text, ahead of its audio.
        case said(String, id: String)
        /// Something she says while a tool runs — not part of the reply.
        case filler(String)
        /// Her voice for one sentence, whole, as WAV bytes.
        case voice(Data)
        /// Her voice is about to stream as raw PCM at this rate.
        case voiceStart(id: String, sampleRate: Double, turn: Int?)
        /// A stretch of that voice.
        case pcm(Data)
        case voiceEnd(id: String)
        /// The turn is over; the face it ended on, when the server read one.
        case turnEnded(emotion: String?)
        case interrupted
        case failed(String)
        case ended(String)
    }

    private let task: URLSessionWebSocketTask
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var closed = false
    private var inputGate = CallInputGate()
    private var inputSamples = 0
    private var captureFrames: [(start:Int, end:Int, at:Double)] = []
    private var turnCapture: [Int:Double] = [:]
    private var measuredTurns: Set<Int> = []

    init(client: HaruClient, onEvent: @escaping @Sendable (Event) -> Void) {
        var parts = URLComponents(url: client.base.appendingPathComponent("/api/call/session"), resolvingAgainstBaseURL: false) ?? URLComponents()
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
        // What this phone can play: her voice as it is made.
        task.send(.string("{\"type\":\"hello\",\"pcm\":true}")) { _ in }
        receive()
    }

    /// Whether she is audible through this phone's speaker right now, so the
    /// server's ear knows an echo of her from somebody talking over her.
    func her(speaking: Bool) {
        task.send(.string("{\"type\":\"her\",\"speaking\":\(speaking)}")) { _ in }
    }

    /// A stretch of the microphone: 16 kHz mono PCM16, no header.
    func send(_ pcm: Data, capturedAt:Double = .nan) {
        lock.lock()
        guard !closed, inputGate.sendsAudio else { lock.unlock(); return }
        let end = inputSamples + pcm.count / 2
        if capturedAt.isFinite { captureFrames.append((inputSamples,end,capturedAt)) }
        if captureFrames.count > 2048 { captureFrames.removeFirst(captureFrames.count - 2048) }
        inputSamples = end
        lock.unlock()
        task.send(.data(pcm)) { _ in }
    }

    func manualInput(_ enabled: Bool) {
        lock.lock()
        inputGate.select(enabled)
        lock.unlock()
        task.send(.string("{\"type\":\"input_mode\",\"manual\":\(enabled)}")) { _ in }
    }

    func holdInput(_ active: Bool) {
        lock.lock()
        guard !closed, inputGate.hold(active) else { lock.unlock(); return }
        lock.unlock()
        task.send(.string("{\"type\":\"input_gate\",\"active\":\(active)}")) { _ in }
    }

    /// Hardware capture to first non-silent player render plus reported output
    /// latency. This is a phone-side estimate, not an acoustic measurement.
    func playbackEstimate(turn:Int, id:String, renderedAt:Double, outputMs:Double, primeMs:Double, underruns:Int) {
        lock.lock()
        let captured = turnCapture.removeValue(forKey:turn)
        let permitted = !closed && !measuredTurns.contains(turn) && measuredTurns.count < 128
        if permitted, captured != nil { measuredTurns.insert(turn) }
        lock.unlock()
        guard permitted, let captured else { return }
        let elapsed = (renderedAt-captured)*1000
        guard elapsed.isFinite, elapsed >= 0, elapsed <= 180000 else { return }
        let payload:[String:Any] = ["type":"playback_timing","turn":turn,"id":id,
            "captureToRenderEstimateMs":elapsed,"outputLatencyMs":outputMs,"primeMs":primeMs,"underruns":underruns]
        if let data = try? JSONSerialization.data(withJSONObject:payload), let text = String(data:data,encoding:.utf8) {
            task.send(.string(text)) { _ in }
        }
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
                case .data(let data): self.onEvent(.pcm(data))
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
        case "ready": onEvent(.ready(pushToTalk: event.pushToTalk == true))
        case "input_mode":
            guard let enabled = event.manual else { return }
            lock.lock(); inputGate.acknowledge(enabled); lock.unlock()
            onEvent(.inputMode(manual: enabled))
        case "input_gate":
            guard let active = event.active else { return }
            lock.lock(); inputGate.serverGate(active); lock.unlock()
            onEvent(.inputGate(active: active))
        case "refused": onEvent(.refused(event.reason ?? "The call could not be placed."))
        case "user_message":
            if let turn = event.turn, let end = event.speechEndSample {
                lock.lock()
                if let frame = captureFrames.last(where: { $0.start < end && $0.end >= end }) {
                    turnCapture[turn] = frame.at + Double(end-frame.start)/16000
                    if turnCapture.count > 32, let oldest = turnCapture.keys.min() { turnCapture.removeValue(forKey:oldest) }
                }
                lock.unlock()
            }
            onEvent(.heard(event.text ?? "", interim: event.interim ?? false))
        case "assistant_message": onEvent(.said(event.text ?? "", id: event.id ?? ""))
        case "audio_output":
            if let encoded = event.data, let wav = Data(base64Encoded: encoded) { onEvent(.voice(wav)) }
        case "audio_start": onEvent(.voiceStart(id: event.id ?? "", sampleRate: event.sampleRate ?? 24_000, turn:event.filler == false ? event.turn : nil))
        case "audio_end": onEvent(.voiceEnd(id: event.id ?? ""))
        case "filler": onEvent(.filler(event.text ?? ""))
        case "assistant_end": onEvent(.turnEnded(emotion: event.emotion))
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
    let sampleRate: Double?
    let emotion: String?
    let turn: Int?
    let speechEndSample: Int?
    let filler: Bool?
    let pushToTalk: Bool?
    let manual: Bool?
    let active: Bool?
}
