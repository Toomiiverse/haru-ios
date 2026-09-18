import AVFoundation
import Observation

/// One audio stack for her voice and theirs, so the two share Apple's echo
/// cancellation: what she says through the speaker is subtracted from what
/// the microphone hears, and speaking over her works without her hearing
/// herself. Her lines play through the engine for that reason rather than
/// through a plain player.
@MainActor @Observable
final class Audio {
    private(set) var speaking = false
    private(set) var listening = false
    /// Whether Apple's voice processing took: without it her own voice comes
    /// back through the microphone and the detector takes it for theirs.
    private(set) var echoCancelled = false
    /// The room, 0–1, while listening; for the level bar.
    private(set) var level: Double = 0
    /// How loud she is, 0–1, while she talks; a 0 when she stops. Her mouth.
    var onLevel: ((Double) -> Void)?
    /// Her line has ended (or was cut).
    var onFinished: (() -> Void)?
    /// Their voice, by the activity detector: it started, or a stretch of it
    /// ended, as 16 kHz WAV bytes for her ears.
    var onVoiceStart: (() -> Void)?
    var onVoiceEnd: ((Data) -> Void)?
    /// The microphone as it comes, while a call is on: 16 kHz PCM16 frames of
    /// about forty milliseconds, no header, for the call socket.
    var onFrames: ((Data) -> Void)?
    /// Something else took the audio — a phone call, Siri, an alarm — or gave
    /// it back. `shouldResume` is iOS saying listening may start again.
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ear = Ear()
    private var playToken = 0
    private var playEndsAt: TimeInterval = 0
    private var mouthTapOn = false
    private var configurationWatcher: NSObjectProtocol?
    private var interruptionWatcher: NSObjectProtocol?

    init() {
        engine.attach(player)
        configurationWatcher = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
        interruptionWatcher = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in self?.onInterruption?(kind == .began, options.contains(.shouldResume)) }
        }
    }

    static func allowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Whether the microphone is run through Apple's voice processing while
    /// listening. On: her own voice out of the speaker is subtracted from what
    /// the mic hears, so speaking over her works. Off: she plays back untouched
    /// — clearer — but on speakerphone she may hear herself; fine on earphones.
    var echoCancelling = true

    /// Play and record through the same session, out of the speaker rather than
    /// the earpiece. Video-chat mode while listening: it carries the same echo
    /// cancellation as voice-chat mode but plays back wideband, where voice-chat
    /// mode narrowed her to a telephone.
    static func configureSession(listening: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: listening ? .videoChat : .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    // MARK: Her voice

    /// Starts her line. False when it could not start, so the caller can move
    /// the conversation on rather than wait for an ending that never comes.
    @discardableResult
    func play(_ wav: Data) -> Bool {
        stopPlayback()
        playToken += 1
        let token = playToken
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("her-\(token).wav")
        do {
            try wav.write(to: url)
            let file = try AVAudioFile(forReading: url)
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            if !engine.isRunning {
                Self.configureSession(listening: listening)
                engine.prepare()
                try engine.start()
            }
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            playEndsAt = ProcessInfo.processInfo.systemUptime + seconds
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.finished(token) }
            }
            installMouthTap()
            player.play()
            speaking = true
            ear.herTurn(true)
            return true
        } catch {
            speaking = false
            return false
        }
    }

    /// Stops her mid-line. Returns whether she was actually talking, which is
    /// what "interrupted" means to the server.
    @discardableResult
    func stop() -> Bool {
        let was = speaking
        stopPlayback()
        return was
    }

    /// How long the current line still runs, in seconds; 0 when she is quiet.
    var remaining: TimeInterval {
        speaking ? max(0, playEndsAt - ProcessInfo.processInfo.systemUptime) : 0
    }

    // MARK: Her voice, as it is made

    private var streamFormat: AVAudioFormat?
    private var streamPending = 0        // buffers scheduled and not yet played back
    private var streamEnded = false      // the server has sent the last of this line
    private var streamToken = 0
    private var streamCarry: UInt8?      // an odd trailing byte, half of the next sample
    private var streamPrimed = false     // playing; before that, buffers queue up
    private var streamQueued = 0.0       // seconds scheduled before playing began

    /// Her voice is about to arrive in pieces: mono 16-bit PCM at `sampleRate`.
    /// Each piece plays as it lands, one after another, so she starts talking
    /// at her first sentence rather than her last.
    func beginStream(sampleRate: Double) {
        // The next sentence of the same call: it queues behind the one still
        // sounding. Stopping here cut the tail of every line, since her voice
        // is made faster than it plays (2026-09-18, "drops in and out").
        if speaking, streamToken == playToken, let format = streamFormat, format.sampleRate == sampleRate {
            streamEnded = false
            return
        }
        stopPlayback()
        playToken += 1
        streamToken = playToken
        streamPending = 0
        streamEnded = false
        streamCarry = nil
        streamPrimed = false
        streamQueued = 0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }
        streamFormat = format
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            Self.configureSession(listening: listening)
            engine.prepare()
            try? engine.start()
        }
        installMouthTap()
        // Not playing yet: a quarter second queues first, so a late chunk does
        // not leave the player starved and silent mid-word. A stream that is
        // slow to reach that plays anyway after 400 ms.
        let token = streamToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.prime(token) }
        speaking = true
        ear.herTurn(true)
    }

    private func prime(_ token: Int) {
        guard token == streamToken, token == playToken, speaking, !streamPrimed else { return }
        streamPrimed = true
        player.play()
    }

    /// A stretch of her voice. Nothing happens without a beginStream first.
    /// Chunks come in any byte length: an odd one would put every sample after
    /// it half a sample out — static — so a trailing byte waits for the next.
    func feedStream(_ pcm: Data) {
        guard let format = streamFormat, speaking, streamToken == playToken else { return }
        var bytes = pcm
        if let carry = streamCarry { bytes.insert(carry, at: 0); streamCarry = nil }
        if bytes.count % 2 == 1 { streamCarry = bytes.removeLast() }
        let count = bytes.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        bytes.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | hi << 8)) / 32768
            }
        }
        streamPending += 1
        let token = streamToken
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.streamed(token) }
        }
        let seconds = Double(count) / format.sampleRate
        playEndsAt = max(playEndsAt, ProcessInfo.processInfo.systemUptime) + seconds
        if !streamPrimed {
            streamQueued += seconds
            if streamQueued >= 0.25 { prime(token) }
        }
    }

    /// The last of this line has been sent; she is done once it has played.
    func endStream() {
        guard streamToken == playToken else { return }
        streamEnded = true
        if !streamPrimed { prime(streamToken) }
        if streamPending == 0 { finished(streamToken) }
    }

    private func streamed(_ token: Int) {
        guard token == streamToken, token == playToken else { return }
        streamPending = max(0, streamPending - 1)
        if streamEnded, streamPending == 0 { finished(token) }
    }

    private func finished(_ token: Int) {
        guard token == playToken, speaking else { return }
        speaking = false
        ear.herTurn(false)
        removeMouthTap()
        onLevel?(0)
        onFinished?()
    }

    private func stopPlayback() {
        playToken += 1
        if player.isPlaying { player.stop() }
        speaking = false
        ear.herTurn(false)
        removeMouthTap()
        onLevel?(0)
    }

    private func installMouthTap() {
        guard !mouthTapOn else { return }
        mouthTapOn = true
        let format = player.outputFormat(forBus: 0)
        player.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            let samples = channels[0]
            var i = 0
            while i < n { sum += samples[i] * samples[i]; i += 1 }
            let rms = sqrt(sum / Float(max(n, 1)))
            // Speech peaks near 0.25 RMS; a little curve so quiet syllables still move the mouth.
            let open = Double(min(1, pow(rms / 0.25, 0.7)))
            Task { @MainActor in self?.mouth(open) }
        }
    }

    private func removeMouthTap() {
        guard mouthTapOn else { return }
        player.removeTap(onBus: 0)
        mouthTapOn = false
    }

    private func mouth(_ open: Double) {
        guard speaking else { return }
        onLevel?(open)
    }

    // MARK: Their voice

    func listen(_ on: Bool) throws {
        guard on != listening else { return }
        let wasSpeaking = speaking
        // Voice processing can only be switched with the engine stopped, which
        // cuts whatever she was saying.
        stopPlayback()
        engine.stop()
        if on {
            // The session first, then the input node: voice processing is built
            // for the mode the session is in when the node comes to exist.
            Self.configureSession(listening: true)
            let input = engine.inputNode
            do { try input.setVoiceProcessingEnabled(echoCancelling) } catch { echoCancelled = false }
            echoCancelled = input.isVoiceProcessingEnabled
            let format = input.outputFormat(forBus: 0)
            ear.reset(sampleRate: format.sampleRate)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let heard = self.ear.feed(buffer)
                Task { @MainActor in self.earSaid(heard) }
            }
            engine.prepare()
            try engine.start()
            listening = true
        } else {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            echoCancelled = false
            Self.configureSession(listening: false)
            listening = false
            level = 0
        }
        if wasSpeaking { onFinished?() }
    }

    /// Opens the ear again after something else had the audio, even though the
    /// session still thinks it is listening. Throws when iOS will not have it —
    /// with the phone locked it often will not, and only the app open again can.
    func reopen() throws {
        listening = false
        engine.inputNode.removeTap(onBus: 0)
        try listen(true)
    }

    /// Her name, listened for on the phone: every microphone buffer goes to it
    /// while no call is streaming. Nil stops it.
    func spot(_ wake: NameSpotter?) {
        ear.setSpotter(wake)
    }

    /// The last `seconds` the microphone heard, at its own rate — the voice
    /// that just said her name, for the gate (VoiceGate).
    func recent(seconds: Double) -> (samples: [Float], rate: Double) {
        ear.recent(seconds: seconds)
    }

    /// She heard her name: one of her own breaths — a "hmph", a soft "hmmm",
    /// a soft laugh — before the call opens. Hers, in her voice, rather than a
    /// tone. The clips are the ones her sighs come from (Resources/wake),
    /// brought up to just under full scale (2026-09-18: the raw breaths peaked
    /// at -20 dBFS and were lost across a room; +18 to +21 dB, 5 ms fades).
    func chime() {
        let names = ["wake-hmph", "wake-hmmm", "wake-laugh"]
        if let name = names.randomElement(), let url = Bundle.main.url(forResource: name, withExtension: "wav"),
           let data = try? Data(contentsOf: url) {
            play(data)
            return
        }
        tones()
    }

    /// Two short rising tones: the wake sound when no breath is in the bundle.
    private func tones() {
        let rate = 16_000.0
        var samples: [Float] = []
        for (frequency, seconds) in [(784.0, 0.07), (1_175.0, 0.11)] {
            let count = Int(rate * seconds)
            for i in 0..<count {
                let fade = min(1, Double(min(i, count - i)) / (rate * 0.01))
                samples.append(Float(sin(2 * .pi * frequency * Double(i) / rate) * 0.8 * fade))
            }
        }
        play(Wav.encode(frames: [samples], from: rate, to: rate))
    }

    private func earSaid(_ heard: Ear.Heard) {
        level = min(1, heard.level * 12)
        if let frame = heard.frame { onFrames?(frame) }
        if heard.started { onVoiceStart?() }
        if let segment = heard.segment { onVoiceEnd?(segment) }
    }

    /// Whether the microphone is streamed as frames (a call) as well as
    /// watched by the detector. The detector runs either way; on a call its
    /// findings go nowhere, since Hume decides when they have finished.
    func stream(_ on: Bool) {
        ear.streaming = on
    }

    /// Headphones in, a call over, a Bluetooth speaker gone: the engine needs
    /// starting again, and the ear re-opening if it was open.
    private func routeChanged() {
        guard listening else { return }
        listening = false
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        try? listen(true)
    }
}

/// The microphone's side of things, touched only from the audio thread: the
/// activity detector and a twenty-second ring of what was heard, so a stretch
/// of speech can be handed over whole once it ends.
final class Ear: @unchecked Sendable {
    struct Heard {
        let level: Double
        let started: Bool
        let segment: Data?
        /// This buffer as 16 kHz PCM16, only while streaming.
        let frame: Data?
    }

    /// Read racily on the audio thread, on purpose, like herTurn below.
    var streaming = false

    /// Listening for her name (WakeSpotter), under the lock: a class reference
    /// swapped while the audio thread reads it is not a race to leave in.
    private var spotter: NameSpotter?
    func setSpotter(_ wake: NameSpotter?) {
        lock.lock()
        spotter = wake
        lock.unlock()
    }

    /// While she is talking, and for half a second after: the detector then
    /// wants a much louder and longer sound before it believes anyone else is
    /// speaking. Read racily on the audio thread, on purpose.
    private var herTurnUntil = 0.0
    private var herTurnNow = false
    func herTurn(_ on: Bool) {
        let t = ProcessInfo.processInfo.systemUptime * 1000
        herTurnNow = on
        if !on { herTurnUntil = t + 500 }
    }
    private func hers(_ t: Double) -> Bool { herTurnNow || t < herTurnUntil }

    private let lock = NSLock()
    private var vad = Vad()
    private var ring: [(t: Double, samples: [Float])] = []
    private var ringSamples = 0
    private var sampleRate = 48_000.0

    func reset(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        vad = Vad()
        // Six hundred milliseconds of quiet ends what they said: a beat shorter
        // than the page's, because every one of them is waited through.
        vad.endAfterMs = 600
        ring = []
        ringSamples = 0
    }

    /// The tail of the ring, newest last: what was said just now.
    func recent(seconds: Double) -> (samples: [Float], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let want = Int(sampleRate * seconds)
        var parts: [[Float]] = []
        var have = 0
        var i = ring.count - 1
        while i >= 0, have < want {
            parts.append(ring[i].samples)
            have += ring[i].samples.count
            i -= 1
        }
        var out: [Float] = []
        out.reserveCapacity(have)
        for part in parts.reversed() { out.append(contentsOf: part) }
        if out.count > want { out.removeFirst(out.count - want) }
        return (out, sampleRate)
    }

    func feed(_ buffer: AVAudioPCMBuffer) -> Heard {
        guard let channels = buffer.floatChannelData else { return Heard(level: 0, started: false, segment: nil, frame: nil) }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: n))
        var sum: Float = 0
        for s in samples { sum += s * s }
        let level = Double(sqrt(sum / Float(max(n, 1))))
        let t = ProcessInfo.processInfo.systemUptime * 1000

        lock.lock()
        defer { lock.unlock() }
        // Not on a call: the call's own ear is on the server.
        if !streaming, let spotter { spotter.feed(samples, rate: sampleRate) }
        ring.append((t, samples))
        ringSamples += n
        let cap = Int(sampleRate * 20)
        while ringSamples > cap, !ring.isEmpty {
            ringSamples -= ring[0].samples.count
            ring.removeFirst()
        }
        var started = false
        var segment: Data?
        // Over her: seven times the room's floor and never under 0.03, held
        // for a quarter of a second — an echo that slipped past cancellation
        // is quieter and shorter than somebody actually talking over her.
        let over = hers(t)
        vad.startAfterMs = over ? 260 : 90
        if let event = vad.feed(level: level, t: t, ratio: over ? 7 : nil, least: over ? 0.03 : nil) {
            switch event.kind {
            case .start:
                started = true
            case .end:
                let frames = ring.filter { $0.t >= event.from && $0.t <= event.to }.map { $0.samples }
                segment = Wav.encode(frames: frames, from: sampleRate, to: 16_000)
            case .drop:
                break
            }
        }
        let frame: Data? = streaming ? Wav.pcm16(samples, from: sampleRate, to: 16_000) : nil
        return Heard(level: level, started: started, segment: segment, frame: frame)
    }
}
