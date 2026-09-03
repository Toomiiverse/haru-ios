import AVFoundation
import Observation

/// The microphone, recorded as 16 kHz mono PCM WAV — the shape the server's
/// /api/listen maps straight to a `.wav` for Whisper, with no conversion.
@MainActor @Observable
final class Ear {
    private(set) var recording = false
    /// 0–1, for the little level bar while they talk.
    private(set) var level: Double = 0
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("speech.wav")

    /// About a minute of speech at this rate is 2MB; the server allows 8.
    static let longest: TimeInterval = 90

    func allowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() -> Bool {
        Voice.configureSession()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let next = try AVAudioRecorder(url: file, settings: settings)
            next.isMeteringEnabled = true
            guard next.record(forDuration: Self.longest) else { return false }
            recorder = next
            recording = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let live = self.recorder else { return }
                    live.updateMeters()
                    // -50 dB is silence, 0 is as loud as it gets.
                    self.level = max(0, min(1, Double(live.averagePower(forChannel: 0) + 50) / 50))
                }
            }
            return true
        } catch {
            return false
        }
    }

    func stop() -> Data? {
        meter?.invalidate()
        meter = nil
        guard let live = recorder else { return nil }
        live.stop()
        recorder = nil
        recording = false
        level = 0
        return try? Data(contentsOf: file)
    }
}
