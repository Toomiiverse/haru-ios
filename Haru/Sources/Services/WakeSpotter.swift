import Foundation
import SherpaOnnxC

/// "Hey Haru", heard on the phone itself.
///
/// Standby keeps the microphone open with the phone locked, and nothing it
/// hears leaves the phone until her name is heard: a 3.3-million-parameter
/// keyword spotter (sherpa-onnx, the gigaspeech zipformer, int8) listens for
/// the phrase, and only then is a call placed. The framework and the model are
/// fetched when the app is built (scripts/build-ipa.sh), not kept in git.
///
/// Every call into the C side happens on `queue`; the audio thread only hands
/// buffers over. The spotter copies its configuration, so the strings given to
/// it need to live only as long as the call that creates it.
final class WakeSpotter: @unchecked Sendable {
    /// The phrase as the model's own pieces (its bpe.model says "HEY HARU" is
    /// these four), with the boost it gets while decoding and the probability
    /// it must reach to count. Measured offline (2026-09-17, seven synthetic
    /// voices, an hour of real speech): boost 2 / threshold 0.05 hears 64% of
    /// clean "Hey Haru" clips against 44% at 1.5 / 0.2, and two and a half
    /// times as many from a voice 12 dB quieter — the 60 cm problem — for one
    /// near miss ("Hey, hurry up") in 378 and no false wakes in the hour.
    /// Spelling variants of "Haru" and a gain stage in front both hurt.
    static let keywords = "▁HE Y ▁HA RU :2.0 #0.05 @HEY_HARU"

    /// Where the model files are in the bundle: a folder reference, kept whole.
    static let folder = "kws"

    /// Her name was heard. On the main queue.
    var onWake: (() -> Void)?

    private let queue = DispatchQueue(label: "com.toomiiverse.haru.wake", qos: .userInitiated)
    private let spotter: OpaquePointer
    private let stream: OpaquePointer
    private let pendingLock = NSLock()
    private var pending = 0
    private var lastWake: TimeInterval = 0

    init?(bundle: Bundle = .main) {
        let dir = bundle.bundleURL.appendingPathComponent(Self.folder)
        let files = [
            "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            "decoder-epoch-12-avg-2-chunk-16-left-64.onnx",
            "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            "tokens.txt",
        ].map { dir.appendingPathComponent($0).path }
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }

        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar>? {
            guard let copy = strdup(text) else { return nil }
            owned.append(copy)
            return UnsafePointer(copy)
        }

        // Zeroed, then filled: fields a newer sherpa-onnx adds stay zero, which
        // is what its own defaults are, instead of breaking the build.
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(files[0])
        config.model_config.transducer.decoder = c(files[1])
        config.model_config.transducer.joiner = c(files[2])
        config.model_config.tokens = c(files[3])
        config.model_config.num_threads = 1
        config.model_config.provider = c("cpu")
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = 1.0
        config.keywords_threshold = 0.25
        config.keywords_buf = c(Self.keywords)
        config.keywords_buf_size = Int32(Self.keywords.utf8.count)

        guard let spotter = SherpaOnnxCreateKeywordSpotter(&config) else { return nil }
        guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            return nil
        }
        self.spotter = spotter
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    /// A buffer from the microphone at its own rate, from the audio thread.
    /// Dropped rather than queued when decoding has fallen a second behind:
    /// a late "Hey Haru" is worth less than a phone that keeps up.
    func feed(_ samples: [Float], rate: Double) {
        pendingLock.lock()
        let behind = pending > 25
        if !behind { pending += 1 }
        pendingLock.unlock()
        guard !behind else { return }
        queue.async { [self] in
            defer {
                pendingLock.lock()
                pending -= 1
                pendingLock.unlock()
            }
            let pcm: [Float] = rate == 16_000
                ? samples
                : Wav.resample(samples, from: rate, to: 16_000).map { Float($0) / 32_767 }
            pcm.withUnsafeBufferPointer { buffer in
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
            }
            while SherpaOnnxIsKeywordStreamReady(spotter, stream) == 1 {
                SherpaOnnxDecodeKeywordStream(spotter, stream)
                guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
                let heard = result.pointee.keyword.map { String(cString: $0) } ?? ""
                SherpaOnnxDestroyKeywordResult(result)
                guard !heard.isEmpty else { continue }
                // The stream must be reset right after a hit, or it fires again on
                // the same audio.
                SherpaOnnxResetKeywordStream(spotter, stream)
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastWake > 2 else { continue }
                lastWake = now
                DispatchQueue.main.async { [weak self] in self?.onWake?() }
            }
        }
    }

    /// Forget what was half-heard: after a call, before listening again.
    func reset() {
        queue.async { [self] in SherpaOnnxResetKeywordStream(spotter, stream) }
    }
}
