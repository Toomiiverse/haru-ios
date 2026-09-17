import Foundation
import SherpaOnnxC

/// Whose voice said her name.
///
/// "Hey Haru" from anyone used to wake her. Now the two seconds around the
/// phrase go through a speaker-embedding model (sherpa-onnx, the same
/// framework as the spotter) and are compared with his own takes, taught in
/// More: a stranger's voice scores low and she stays asleep. Enrolment and the
/// check both happen on the phone; the takes he teaches her are also sent to
/// her server, where they are the seeds for a wake-word model of his voice.
final class VoiceGate: @unchecked Sendable {
    /// Picked offline (2026-09-17, spk_bench.py, seven synthetic voices and an
    /// hour of real speech, three takes enrolled): 3D-Speaker's ERes2Net puts
    /// the same voice at 0.74 (worst tenth 0.51) and any other voice under
    /// 0.34, real speech under 0.37; the best split was 0.33 at 1–2% each way.
    /// A little above it, since a stranger waking her is the worse mistake.
    /// 62 ms a check on this box's CPU.
    static let model = "3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx"
    static let threshold: Float = 0.38
    /// Takes he says at enrolment. Three would do; six covers a quiet one and a
    /// tired one.
    static let takes = 6

    private let queue = DispatchQueue(label: "com.toomiiverse.haru.voice", qos: .userInitiated)
    private let extractor: OpaquePointer
    private let dim: Int
    private let file: URL
    /// His takes, as unit vectors. Read and written on the main thread.
    private(set) var enrolled: [[Float]] = []

    init?(bundle: Bundle = .main) {
        let path = bundle.bundleURL.appendingPathComponent(WakeSpotter.folder).appendingPathComponent(Self.model).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar>? {
            guard let copy = strdup(text) else { return nil }
            owned.append(copy)
            return UnsafePointer(copy)
        }
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.model = c(path)
        config.num_threads = 1
        config.provider = c("cpu")
        guard let extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else { return nil }
        self.extractor = extractor
        dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        file = support.appendingPathComponent("voice-takes.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([[Float]].self, from: data) {
            enrolled = saved.filter { $0.count == dim }
        }
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
    }

    var isEnrolled: Bool { enrolled.count >= 3 }

    /// The voice in `samples` (any rate) as a unit vector, or nil when there
    /// was too little of it to say.
    func embedding(_ samples: [Float], rate: Double) async -> [Float]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let pcm: [Float] = rate == 16_000 ? samples : Wav.resample(samples, from: rate, to: 16_000).map { Float($0) / 32_767 }
                guard pcm.count >= 4_800, let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else {
                    continuation.resume(returning: nil); return
                }
                defer { SherpaOnnxDestroyOnlineStream(stream) }
                pcm.withUnsafeBufferPointer { buffer in
                    SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
                }
                SherpaOnnxOnlineStreamInputFinished(stream)
                guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1,
                      let raw = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else {
                    continuation.resume(returning: nil); return
                }
                defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(raw) }
                let vector = Array(UnsafeBufferPointer(start: raw, count: dim))
                continuation.resume(returning: Self.unit(vector))
            }
        }
    }

    /// How much like his takes a voice is: cosine against their mean, -1…1.
    func score(_ vector: [Float]) -> Float {
        guard isEnrolled, vector.count == dim else { return 0 }
        var mean = [Float](repeating: 0, count: dim)
        for take in enrolled { for i in 0..<dim { mean[i] += take[i] } }
        let centroid = Self.unit(mean)
        var dot: Float = 0
        for i in 0..<dim { dot += vector[i] * centroid[i] }
        return dot
    }

    func enrol(_ vector: [Float]) {
        guard vector.count == dim else { return }
        enrolled.append(vector)
        save()
    }

    func forget() {
        enrolled = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(enrolled) { try? data.write(to: file, options: .atomic) }
    }

    private static func unit(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = max(norm.squareRoot(), 1e-9)
        return v.map { $0 / norm }
    }

    /// The samples in a WAV of the ear's own making (Wav.encode: 16-bit mono).
    static func samples(ofWav data: [UInt8]) -> (samples: [Float], rate: Double)? {
        guard data.count > 44, String(bytes: data[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        let rate = Double(UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24)
        let body = data[44...]
        var out = [Float](repeating: 0, count: body.count / 2)
        var i = body.startIndex
        for k in 0..<out.count {
            let v = Int16(bitPattern: UInt16(body[i]) | UInt16(body[i + 1]) << 8)
            out[k] = Float(v) / 32_767
            i += 2
        }
        return (out, rate)
    }
}
