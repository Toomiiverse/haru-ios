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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ear = Ear()
    private var playToken = 0
    private var playEndsAt: TimeInterval = 0
    private var mouthTapOn = false
    private var configurationWatcher: NSObjectProtocol?

    init() {
        engine.attach(player)
        configurationWatcher = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    static func allowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Play and record through the same session, out of the speaker rather than
    /// the earpiece. Voice chat mode while listening: that is where the echo
    /// cancellation lives.
    static func configureSession(listening: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: listening ? .voiceChat : .default,
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
            ear.herTurn = true
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

    private func finished(_ token: Int) {
        guard token == playToken, speaking else { return }
        speaking = false
        ear.herTurn = false
        removeMouthTap()
        onLevel?(0)
        onFinished?()
    }

    private func stopPlayback() {
        playToken += 1
        if player.isPlaying { player.stop() }
        speaking = false
        ear.herTurn = false
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
        let input = engine.inputNode
        let wasSpeaking = speaking
        // Voice processing can only be switched with the engine stopped, which
        // cuts whatever she was saying.
        stopPlayback()
        engine.stop()
        if on {
            Self.configureSession(listening: true)
            try? input.setVoiceProcessingEnabled(true)
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
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            Self.configureSession(listening: false)
            listening = false
            level = 0
        }
        if wasSpeaking { onFinished?() }
    }

    private func earSaid(_ heard: Ear.Heard) {
        level = min(1, heard.level * 12)
        if heard.started { onVoiceStart?() }
        if let segment = heard.segment { onVoiceEnd?(segment) }
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
    }

    /// Set while she is talking; the detector then wants a much louder room
    /// before it believes anyone else is. A flag, read racily on purpose.
    var herTurn = false

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
        ring = []
        ringSamples = 0
    }

    func feed(_ buffer: AVAudioPCMBuffer) -> Heard {
        guard let channels = buffer.floatChannelData else { return Heard(level: 0, started: false, segment: nil) }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: n))
        var sum: Float = 0
        for s in samples { sum += s * s }
        let level = Double(sqrt(sum / Float(max(n, 1))))
        let t = ProcessInfo.processInfo.systemUptime * 1000

        lock.lock()
        defer { lock.unlock() }
        ring.append((t, samples))
        ringSamples += n
        let cap = Int(sampleRate * 20)
        while ringSamples > cap, !ring.isEmpty {
            ringSamples -= ring[0].samples.count
            ring.removeFirst()
        }
        var started = false
        var segment: Data?
        if let event = vad.feed(level: level, t: t, ratio: herTurn ? 7 : nil) {
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
        return Heard(level: level, started: started, segment: segment)
    }
}
