import Foundation

enum DolphinModel {
    static let name = "Dolphin 2.9.3 Mistral 7B"
    static let filename = "dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf"
    static let bytes: Int64 = 3_022_780_608
    static let sha256 = "3c4a71f5c97d1bc3ce81feb3afac63205059c8e8bf24ddbd45f8fb415270a99f"
    static let url = URL(string: "https://huggingface.co/bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF/resolve/740ce4567b3392bd065637d2ac29127ca417cc45/" + filename)!
    static let defaultInstructions = """
    You are Haru, a thoughtful conversational companion. Speak naturally and warmly, with your own opinions. Keep ordinary replies concise and follow the conversation closely. Ask questions when useful, without ending every reply with one. Be honest about uncertainty. You are running on this phone in a text-only conversation. You cannot browse, see images, set reminders, use tools, or change anything on the server. Never claim you performed an action. Only refer to personal memories supplied below or in this conversation; do not invent a shared past.
    """
}

struct LocalMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum State: String, Codable { case complete, interrupted, failed, generating }
    var id = UUID().uuidString
    let role: Role
    var text: String
    var state: State = .complete
    var createdAt = Date()
}

struct LocalConversationArchive: Codable {
    var version = 1
    var messages: [LocalMessage] = []
    var instructions = DolphinModel.defaultInstructions
    var notes = ""
    var contextSize = 1024

    mutating func recover() {
        contextSize = contextSize == 2048 ? 2048 : 1024
        for i in messages.indices where messages[i].state == .generating {
            messages[i].state = .interrupted
        }
    }
}

enum LocalChatError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct LocalPrompt {
    let text: String
    let tokens: Int
    let omittedMessages: Int

    /// Keep the current question and system instructions intact; discard only
    /// whole older exchanges. Count using the actual model tokenizer.
    static func build(instructions: String, notes: String, messages: [LocalMessage],
                      contextSize: Int, outputTokens: Int,
                      count: (String) throws -> Int) throws -> LocalPrompt {
        guard let last = messages.last, last.role == .user, !last.text.isEmpty else {
            throw LocalChatError.message("Write a message first.")
        }
        var exchanges: [[LocalMessage]] = []
        var index = 0
        let history = Array(messages.dropLast())
        while index + 1 < history.count {
            if history[index].role == .user, history[index + 1].role == .assistant,
               history[index + 1].state == .complete {
                exchanges.append([history[index], history[index + 1]])
                index += 2
            } else { index += 1 }
        }
        let system = instructions + (notes.isEmpty ? "" : "\n\nUser-selected background notes (may be outdated):\n" + notes)
        while true {
            let included = exchanges.flatMap { $0 } + [last]
            let text = "<|im_start|>system\n" + escape(system) + "<|im_end|>\n"
                + included.map { "<|im_start|>\($0.role.rawValue)\n" + escape($0.text) + "<|im_end|>\n" }.joined()
                + "<|im_start|>assistant\n"
            let tokens = try count(text)
            if tokens + outputTokens + 8 <= contextSize {
                return LocalPrompt(text: text, tokens: tokens, omittedMessages: history.count - exchanges.count * 2)
            }
            guard !exchanges.isEmpty else {
                throw LocalChatError.message("This message and your saved notes exceed the local context. Shorten them or choose 2,048 context tokens in On-device settings.")
            }
            exchanges.removeFirst()
        }
    }

    /// A quoted ChatML delimiter must remain ordinary content, not a new role.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "\u{0000}", with: " ")
    }
}

/// Tokens can end halfway through a UTF-8 character or a ChatML stop marker.
struct LocalTextBuffer {
    private var bytes = Data()
    private var pending = ""
    private(set) var text = ""
    private(set) var stopped = false
    private let stops = ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "</s>"]

    mutating func append(_ fragment: Data) -> String? {
        guard !stopped else { return nil }
        bytes.append(fragment)
        guard let decoded = String(data: bytes, encoding: .utf8) else { return nil }
        bytes.removeAll(keepingCapacity: true)
        pending += decoded
        if let range = stops.compactMap({ pending.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            text += pending[..<range.lowerBound]
            pending = ""
            stopped = true
            return text
        }
        var held = 0
        for marker in stops {
            for size in 1..<marker.count where pending.hasSuffix(marker.prefix(size)) {
                held = max(held, size)
            }
        }
        let ready = pending.dropLast(held)
        guard !ready.isEmpty else { return nil }
        text += ready
        pending = String(pending.suffix(held))
        return text
    }

    mutating func finish() -> String {
        if !stopped {
            text += pending + String(decoding: bytes, as: UTF8.self)
            pending = ""; bytes.removeAll()
        }
        return text
    }
}

struct LocalReplyMetrics: Sendable {
    let firstTextSeconds: Double?
    let totalSeconds: Double
    let generatedTokens: Int
    let generationSeconds: Double
    let promptTokens: Int
    let omittedMessages: Int
    let loadedThisTurn: Bool
}
