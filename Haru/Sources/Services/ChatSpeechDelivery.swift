import Foundation

/// Buffers server-authored delivery events for the device's audio queue.
/// Mood changes remain separate takes; the device never infers a new mood.
struct ChatSpeechDelivery {
    struct Line: Equatable {
        let text: String
        let emotion: String?
    }

    private var pending = ""
    private var pendingEmotion: String?
    private var emitted = false
    private var receivedSentences = false
    private var finished = false

    mutating func receive(_ text: String, emotion: String?) -> [Line] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finished, !text.isEmpty else { return [] }
        receivedSentences = true
        var lines: [Line] = []
        if !pending.isEmpty, emotion != pendingEmotion {
            lines.append(contentsOf: flush())
        }
        pendingEmotion = emotion
        pending += pending.isEmpty ? text : " " + text
        if pending.count >= (emitted ? 160 : 40) {
            lines.append(contentsOf: flush())
        }
        return lines
    }

    mutating func finish(fallbackText: String) -> [Line] {
        guard !finished else { return [] }
        finished = true
        if receivedSentences { return flush() }
        let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Line(text: text, emotion: nil)]
    }

    mutating func reset() { self = Self() }

    private mutating func flush() -> [Line] {
        guard !pending.isEmpty else { return [] }
        let line = Line(text: pending, emotion: pendingEmotion)
        pending = ""
        pendingEmotion = nil
        emitted = true
        return [line]
    }
}
