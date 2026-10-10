import Foundation

/// A snapshot of Core's profile. The phone never computes a speaker match.
struct SpeakerProfile: Decodable {
    let enrolled: Bool
    let validated: Bool
    let enabled: Bool
    let message: String
    let deferVoiceStart: Bool
    let check: Check?
    struct Check: Decodable { let speaker: String; let reason: String }
}

struct VoiceDictationReply: Decodable {
    let text: String?
    let notice: String?
    let speaker: String?
}

/// Bounded microphone transport, always 16 kHz mono PCM16. No identity policy.
struct SpeakerRecording {
    let seconds: Int
    private(set) var pcm = Data()
    var capacity: Int { seconds * 32_000 }
    var complete: Bool { pcm.count == capacity }
    var elapsed: Int { pcm.count / 32_000 }
    mutating func append(_ frame: Data) {
        let remaining = capacity - pcm.count
        guard remaining > 0 else { return }
        let count = min(remaining, frame.count - frame.count % 2)
        pcm.append(frame.prefix(count))
    }
    func wav() -> Data {
        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count))
        out.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        out.append(contentsOf: "data".utf8); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }
}
