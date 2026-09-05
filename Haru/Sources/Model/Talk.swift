import Foundation

// The conversation by voice, ported from the phone page (electron/webpage.ts,
// VOICE) and the desktop's wake phrase (electron/wake.ts). All three parts are
// pure: they take levels, words and a clock and hand back things to do.

/// The wake phrase: her name, with or without a greeting, and whatever came in
/// the same breath. Whisper's spellings of "Haru" included.
enum Wake {
    static let pattern = try! NSRegularExpression(
        pattern: #"^[\s"'“”.,!?-]*(?:(?:hey|hi|hay|ok|okay|yo|oi|hello|hiya)[,\s]+)?(?:haru|haroo|harew|harue|halu|hallu|hulu|harry|hara)\b[\s,.!?:;"'“”-]*([\s\S]*)$"#,
        options: [.caseInsensitive]
    )

    static func phrase(in text: String) -> (woke: Bool, rest: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(said.startIndex..., in: said)
        guard let match = pattern.firstMatch(in: said, range: whole),
              match.numberOfRanges > 1,
              let rest = Range(match.range(at: 1), in: said) else { return (false, said) }
        return (true, String(said[rest]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Voice activity: energy against a floor that follows the room. Speech is a
/// level well above the floor held for a beat; it ends after a stretch of
/// quiet; the floor only learns while nobody is speaking, drops quickly and
/// climbs slowly. The caller raises the ratio while she is talking, so her own
/// voice through the speaker is not taken for theirs.
struct VadEvent {
    enum Kind { case start, end, drop }
    let kind: Kind
    /// Milliseconds on the caller's clock; meaningful for start and end.
    let from: Double
    let to: Double
}

final class Vad {
    var startAfterMs = 90.0
    var endAfterMs = 700.0
    var minMs = 350.0
    var maxMs = 15_000.0
    var prerollMs = 300.0
    var ratio = 3.5
    var floorMin = 0.004

    private enum State { case quiet, maybe, speech }
    private var floor = 0.01
    private var state = State.quiet
    private var since = 0.0
    private var startedAt = 0.0
    private var lastLoud = 0.0

    func threshold(_ ratio: Double? = nil, least: Double? = nil) -> Double { max(least ?? floorMin, floorMin, floor * (ratio ?? self.ratio)) }
    var speaking: Bool { state == .speech }
    func reset() { state = .quiet }

    func feed(level: Double, t: Double, ratio: Double? = nil, least: Double? = nil) -> VadEvent? {
        let loud = level > threshold(ratio, least: least)
        switch state {
        case .quiet:
            floor = level < floor ? floor * 0.7 + level * 0.3 : floor + (level - floor) * 0.02
            if loud { state = .maybe; since = t }
            return nil
        case .maybe:
            if !loud { state = .quiet; return nil }
            if t - since >= startAfterMs {
                state = .speech
                startedAt = since
                lastLoud = t
                return VadEvent(kind: .start, from: max(0, since - prerollMs), to: t)
            }
            return nil
        case .speech:
            if loud { lastLoud = t }
            let over = t - startedAt >= maxMs
            if (!loud && t - lastLoud >= endAfterMs) || over {
                state = .quiet
                let to = over ? t : lastLoud
                if to - startedAt < minMs { return VadEvent(kind: .drop, from: startedAt, to: to) }
                return VadEvent(kind: .end, from: max(0, startedAt - prerollMs), to: to + 100)
            }
            return nil
        }
    }
}

/// off → asleep (her name wakes her) → awake (whatever is said is for her) →
/// thinking → speaking → awake again for a while → asleep. Speaking over her
/// cuts her off and counts as awake; what is said in the same breath as her
/// name is the message. Everything here is a list of things to do.
enum TalkState: String {
    case off, asleep, awake, thinking, speaking
}

enum TalkAction: Equatable {
    case off, asleep, awake, speaking, ack, interrupt
    case say(String, interrupted: Bool)
}

final class Talk {
    var awakeMs = 25_000.0
    var speakingMaxMs = 90_000.0
    private(set) var state = TalkState.off
    private(set) var until = 0.0
    private var interrupted = false

    private func go(_ next: TalkState, _ t: Double, _ ms: Double = 0) {
        state = next
        until = ms > 0 ? t + ms : 0
    }

    /// Awake from the start when they opened the ear themselves: a tap is
    /// already her name.
    func start(_ t: Double, awake: Bool) -> [TalkAction] {
        interrupted = false
        if awake { go(.awake, t, awakeMs); return [.awake] }
        go(.asleep, t)
        return [.asleep]
    }

    func stop() -> [TalkAction] {
        go(.off, 0)
        interrupted = false
        return [.off]
    }

    func heard(_ text: String, _ t: Double) -> [TalkAction] {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty || state == .off || state == .thinking { return [] }
        let wake = Wake.phrase(in: said)
        if state == .asleep {
            if !wake.woke { return [] }
            if !wake.rest.isEmpty { go(.thinking, t); return [.say(wake.rest, interrupted: false)] }
            go(.speaking, t, speakingMaxMs)
            return [.ack]
        }
        let message = wake.woke ? wake.rest : said
        if message.isEmpty { go(.awake, t, awakeMs); return [] }
        let was = interrupted
        interrupted = false
        go(.thinking, t)
        return [.say(message, interrupted: was)]
    }

    func voiceStarted(_ t: Double) -> [TalkAction] {
        guard state == .speaking else { return [] }
        interrupted = true
        go(.awake, t, awakeMs)
        return [.interrupt]
    }

    func replied(_ t: Double, willSpeak: Bool) -> [TalkAction] {
        guard state == .thinking else { return [] }
        if willSpeak { go(.speaking, t, speakingMaxMs); return [.speaking] }
        go(.awake, t, awakeMs)
        return [.awake]
    }

    func spokeEnd(_ t: Double) -> [TalkAction] {
        guard state == .speaking else { return [] }
        go(.awake, t, awakeMs)
        return [.awake]
    }

    func tick(_ t: Double) -> [TalkAction] {
        if (state == .awake || state == .speaking), until > 0, t >= until {
            go(.asleep, t)
            interrupted = false
            return [.asleep]
        }
        return []
    }
}

/// Frames of float samples at the microphone's rate, boxed down to 16 kHz
/// (averaging, so the higher frequencies fold into hiss rather than words)
/// and written as 16-bit PCM with a 44-byte header. Whisper wants nothing more.
enum Wav {
    /// The samples at the new rate, box-averaged down, as 16-bit integers.
    static func resample(_ all: [Float], from: Double, to: Double) -> [Int16] {
        let ratio = from / to
        let count = Int(Double(all.count) / ratio)
        var out = [Int16](repeating: 0, count: max(0, count))
        for i in 0..<out.count {
            let a = Int(Double(i) * ratio)
            let b = max(a + 1, Int(Double(i + 1) * ratio))
            let end = min(b, all.count)
            var sum: Float = 0
            var k = a
            while k < end { sum += all[k]; k += 1 }
            let v = sum / Float(max(1, end - a))
            out[i] = Int16(max(-32768, min(32767, (v * 32767).rounded())))
        }
        return out
    }

    /// The same bytes without the header: a stretch of a stream, for the call socket.
    static func pcm16(_ samples: [Float], from: Double, to: Double) -> Data {
        let out = resample(samples, from: from, to: to)
        var data = Data(capacity: out.count * 2)
        out.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func encode(frames: [[Float]], from: Double, to: Double) -> Data {
        let out = resample(frames.flatMap { $0 }, from: from, to: to)
        var data = Data(capacity: 44 + out.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + out.count * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(to)); u32(UInt32(to) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(out.count * 2))
        out.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
