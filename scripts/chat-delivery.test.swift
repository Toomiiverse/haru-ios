import Foundation

@main
struct ChatDeliveryTests {
    static func require(_ value: Bool, _ detail: String) {
        precondition(value, detail)
    }

    static func event(_ json: String) -> StreamEvent {
        try! JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
    }

    static func main() {
        let sleepy = event(#"{"sentence":"Mm. Give me a minute, you midnight menace.","emotion":"sleepy"}"#)
        require(sleepy.sentence == "Mm. Give me a minute, you midnight menace." && sleepy.emotion == "sleepy", "Server delivery was discarded")
        let text = event(#"{"text":"Visible words stay exactly as she wrote them."}"#)
        require(text.sentence == nil && text.emotion == nil, "Text was mistaken for speech")
        var delivery = ChatSpeechDelivery()
        var lines = delivery.receive(sleepy.sentence!, emotion: sleepy.emotion)
        require(lines.count == 1 && lines[0].emotion == "sleepy", "First sleepy sentence did not stream")
        lines += delivery.receive("Fine.", emotion: "smug")
        lines += delivery.receive("Don't get used to it.", emotion: "smug")
        lines += delivery.receive("I'm still half asleep.", emotion: "sleepy")
        lines += delivery.finish(fallbackText: "This final visible text must never be repeated.")
        require(lines.map(\.emotion) == ["sleepy", "smug", "sleepy"], "Mood boundaries were combined or replaced")
        require(lines.map(\.text) == [sleepy.sentence!, "Fine. Don't get used to it.", "I'm still half asleep."], "Her exact words were rewritten or duplicated")
        require(delivery.finish(fallbackText: "No replay").isEmpty, "Completed delivery was replayed")

        delivery.reset()
        require(delivery.receive("Discard this unfinished take.", emotion: "annoyed").isEmpty, "Short pending take did not buffer")
        delivery.reset()
        require(delivery.finish(fallbackText: "Replacement after reset.") == [.init(text: "Replacement after reset.", emotion: nil)], "Retry kept a discarded take")

        var legacy = ChatSpeechDelivery()
        require(legacy.receive(" \n ", emotion: "sleepy").isEmpty, "Empty speech changed delivery mode")
        require(legacy.finish(fallbackText: "Older server's complete answer.") == [.init(text: "Older server's complete answer.", emotion: nil)], "Legacy server lost its complete answer")
        require(legacy.finish(fallbackText: "Older server's complete answer.").isEmpty, "Legacy final speech was repeated")
        var short = ChatSpeechDelivery()
        require(short.receive("Mm.", emotion: "sleepy").isEmpty, "Short first take did not buffer")
        require(short.finish(fallbackText: "Mm.") == [.init(text: "Mm.", emotion: "sleepy")], "Short final take lost its sleepy delivery")

        var long = ChatSpeechDelivery()
        let first = "You woke me up, but I can still give you the answer."
        require(long.receive(first, emotion: "sleepy").count == 1, "First audible sentence waited for completion")
        let tail = String(repeating: "Still sleepy. ", count: 13).trimmingCharacters(in: .whitespaces)
        require(long.receive(tail, emotion: "sleepy") == [.init(text: tail, emotion: "sleepy")], "Long same-mood speech stalled")
        print("Chat delivery: exact server words/moods, early speech, batching, reset, no duplicate final speech and legacy fallback passed.")
    }
}
