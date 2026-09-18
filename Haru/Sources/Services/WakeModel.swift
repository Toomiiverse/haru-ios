import Foundation
import LiveKitWakeWord

/// Her name, in a model trained on it.
///
/// The spotter (WakeSpotter) is a general keyword model told to listen for
/// "hey haru"; this is a classifier trained for the phrase alone, on twenty
/// thousand synthetic sayings and his own six takes, with rooms and noise
/// laid over them (2026-09-18, ~/oww-train). Measured on the same bench: a
/// voice 12 dB quieter is heard 78% of the time against the spotter's 17%,
/// his takes 6 of 6, and not one false wake in an hour of real speech.
///
/// The pipeline (openWakeWord's mel front end and Google's speech embedding,
/// bundled by livekit-wakeword) scores the last two seconds of audio each
/// time it is asked; here that is every 200 ms, on its own queue, with a
/// two-second lull after a wake. Audio arrives from the ear at the
/// microphone's rate and is boxed down to 16 kHz Int16 on the way in.
final class WakeModel: NameSpotter, @unchecked Sendable {
    /// Score the phrase has to reach, out of 1. Picked offline (eval_oww.py).
    static let threshold: Float = 0.6
    static let resource = "hey_haru"
    private static let window = 32_000      // 2 s at 16 kHz, what the model wants
    private static let hop = 3_200          // 200 ms between scorings
    private static let minimum = 24_000     // 1.5 s before the first

    var onWake: (() -> Void)?

    private let model: WakeWordModel
    private let queue = DispatchQueue(label: "com.toomiiverse.haru.wakemodel", qos: .userInitiated)
    private let lock = NSLock()
    private var ring: [Int16] = []
    private var sinceScored = 0
    private var scoring = false
    private var lastWake: TimeInterval = 0

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: Self.resource, withExtension: "onnx") else { return nil }
        do {
            model = try WakeWordModel(models: [url], sampleRate: 16_000, executionProvider: .coreML)
        } catch {
            return nil
        }
        ring.reserveCapacity(Self.window)
    }

    /// A buffer from the microphone at its own rate, from the audio thread.
    func feed(_ samples: [Float], rate: Double) {
        let pcm: [Int16] = rate == 16_000
            ? samples.map { Int16(max(-32_768, min(32_767, ($0 * 32_767).rounded()))) }
            : Wav.resample(samples, from: rate, to: 16_000)
        lock.lock()
        ring.append(contentsOf: pcm)
        if ring.count > Self.window { ring.removeFirst(ring.count - Self.window) }
        sinceScored += pcm.count
        let due = sinceScored >= Self.hop && ring.count >= Self.minimum && !scoring
        if due { scoring = true; sinceScored = 0 }
        let snapshot = due ? ring : []
        lock.unlock()
        guard due else { return }
        queue.async { [self] in
            defer {
                lock.lock(); scoring = false; lock.unlock()
            }
            let score = (try? snapshot.withUnsafeBufferPointer { try model.predict($0) })?[Self.resource] ?? 0
            guard score >= Self.threshold else { return }
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let fresh = now - lastWake > 2
            if fresh { lastWake = now }
            lock.unlock()
            guard fresh else { return }
            DispatchQueue.main.async { [weak self] in self?.onWake?() }
        }
    }

    /// Forget what was half-heard: after a call, before listening again.
    func reset() {
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        sinceScored = 0
        lastWake = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
}
