import AVFoundation
import Observation

/// Her voice on the phone: one player, the clip /api/speak hands back.
@MainActor @Observable
final class Voice: NSObject, AVAudioPlayerDelegate {
    private(set) var speaking = false
    private var player: AVAudioPlayer?

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
            player = next
            speaking = next.play()
        } catch {
            speaking = false
        }
    }

    /// Stops her mid-line. Returns whether she was actually talking, which is
    /// what "interrupted" means to the server.
    @discardableResult
    func stop() -> Bool {
        let was = speaking
        player?.stop()
        player = nil
        speaking = false
        return was
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.speaking = false }
    }
}
