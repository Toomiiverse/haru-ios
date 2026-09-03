import AVFoundation
import Observation

/// Her voice on the phone: one player, the clip /api/speak hands back.
@MainActor @Observable
final class Voice: NSObject, AVAudioPlayerDelegate {
    private(set) var speaking = false
    private var player: AVAudioPlayer?
    private var meter: Timer?
    /// How loud she is right now, 0–1, twenty times a second while she talks;
    /// a final 0 when she stops. The stage moves her mouth with it.
    var onLevel: ((Double) -> Void)?

    /// Play and record through the same session, out of the speaker rather than
    /// the earpiece, so her voice and the microphone do not fight each other.
    static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    func play(_ data: Data) {
        Self.configureSession()
        do {
            let next = try AVAudioPlayer(data: data)
            next.delegate = self
            next.isMeteringEnabled = true
            player = next
            speaking = next.play()
            if speaking { startMetering() }
        } catch {
            speaking = false
        }
    }

    /// How long the current line runs, in seconds; 0 when she is quiet.
    var remaining: TimeInterval {
        guard let player, speaking else { return 0 }
        return max(0, player.duration - player.currentTime)
    }

    private func startMetering() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let live = self.player, self.speaking else { return }
                live.updateMeters()
                // Speech sits around -25 to -5 dB; below -40 the mouth is shut.
                let open = max(0, min(1, (Double(live.averagePower(forChannel: 0)) + 40) / 32))
                self.onLevel?(open)
            }
        }
    }

    private func stopMetering() {
        meter?.invalidate()
        meter = nil
        onLevel?(0)
    }

    /// Stops her mid-line. Returns whether she was actually talking, which is
    /// what "interrupted" means to the server.
    @discardableResult
    func stop() -> Bool {
        let was = speaking
        player?.stop()
        player = nil
        speaking = false
        stopMetering()
        return was
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.speaking = false
            self.stopMetering()
        }
    }
}
