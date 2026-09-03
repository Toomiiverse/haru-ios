import Foundation
import Observation

/// One bubble group on screen. Her replies split on blank lines into the
/// bubbles she would have sent; an aside is one bubble with a mark down its side.
struct Entry: Identifiable, Hashable {
    enum Kind: Hashable { case me, her, system }
    let id: String
    var serverID: String?
    var kind: Kind
    var text: String
    var aside = false
    var reaction: String?
    /// Streaming: the bubble exists but she has not started yet.
    var waiting = false
    var attachmentNames: [String] = []

    var parts: [String] {
        guard kind == .her, !aside else { return [text] }
        let pieces = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [text] : pieces
    }
}

/// A file already copied into her keeping, waiting to ride the next message.
struct StagedFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let record: JSONValue
}

@MainActor @Observable
final class ChatStore {
    var entries: [Entry] = []
    /// A message is on its way and the composer waits for it.
    var busy = false
    var loading = false
    var emotion = "neutral"
    var staged: [StagedFile] = []
    var transcribing = false
    /// Something worth an alert. Cleared by the view.
    var notice: String?
    /// The conversation by voice: off, or where it stands.
    private(set) var talkState = TalkState.off

    let session: Session
    let audio = Audio()
    let stage = Stage()
    private var talk: Talk?
    private var ticker: Timer?
    private var lastAskedAt = Date.distantPast
    /// Her lines being fetched, in the order she will say them.
    private var lines: [Task<Data?, Never>] = []
    private var draining = false

    init(session: Session) {
        self.session = session
        audio.onLevel = { [weak self] level in self?.stage.mouth(level) }
        audio.onFinished = { [weak self] in self?.drain() }
        audio.onVoiceStart = { [weak self] in
            guard let self, let talk = self.talk else { return }
            self.act(talk.voiceStarted(self.now))
            if talk.state != .asleep { self.stage.attend("typing", ms: 1_500) }
        }
        audio.onVoiceEnd = { [weak self] wav in
            guard let self else { return }
            Task { await self.hear(wav) }
        }
    }

    private var client: HaruClient { session.client }
    /// Milliseconds on a clock that does not jump.
    private var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    // MARK: The day

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let page: ChatPage = try await client.get("/api/chat")
            entries = page.messages.enumerated().map { n, m in
                Entry(
                    id: m.id ?? "line-\(n)",
                    serverID: m.id,
                    kind: m.role == "user" ? .me : m.role == "assistant" ? .her : .system,
                    text: m.content,
                    aside: m.aside,
                    reaction: m.reaction
                )
            }
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Saying something

    func send(_ raw: String, spokeOver: Bool = false) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = staged
        guard !busy, !text.isEmpty || !files.isEmpty else { return }
        busy = true
        defer { busy = false }
        staged = []
        // Said over her, while she was still speaking: she is told so.
        let interrupted = hush() || spokeOver

        entries.append(Entry(id: UUID().uuidString, kind: .me, text: text, attachmentNames: files.map(\.name)))
        let waitID = UUID().uuidString
        entries.append(Entry(id: waitID, kind: .her, text: "", waiting: true))

        var body: [String: JSONValue] = ["text": .string(text)]
        if !files.isEmpty { body["attachments"] = .array(files.map(\.record)) }
        if interrupted { body["interrupted"] = true }
        stage.attend("thinking", ms: 20_000)
        await run(client.stream("/api/chat/stream", body), into: waitID)
    }

    /// Her last reply, done again. The bubble is swapped, not added.
    func retry() async {
        guard !busy, let last = lastReply else { return }
        busy = true
        defer { busy = false }
        hush()
        if let i = entries.firstIndex(where: { $0.id == last.id }) {
            entries[i].text = ""
            entries[i].waiting = true
            entries[i].reaction = nil
        }
        stage.attend("thinking", ms: 20_000)
        await run(client.stream("/api/chat/retry", [:]), into: last.id)
    }

    var lastReply: Entry? {
        entries.last(where: { $0.kind == .her && !$0.aside && $0.serverID != nil })
    }

    private func run(_ stream: AsyncThrowingStream<StreamEvent, Error>, into id: String) async {
        var said = ""
        var reply: String?
        var ignored = false
        var failure: String?
        var begun = false
        // How much of what is on screen she has already been given to say.
        var spoken = 0
        do {
            for try await event in stream {
                if let error = event.error {
                    failure = error
                } else if event.text == "\u{FFFD}" {
                    // The round was thrown away; back to waiting, and whatever
                    // she had started saying of it goes too.
                    said = ""
                    spoken = 0
                    hush()
                    paint(id, "", waiting: true)
                } else if let chunk = event.text, !chunk.isEmpty {
                    if !begun {
                        // The thinking is over, whatever the mood turns out to be.
                        begun = true
                        stage.attend("talking", ms: 2_500)
                    }
                    said += chunk
                    paint(id, said, waiting: false)
                    // A sentence that has ended is a sentence she can start
                    // saying while the rest is still being written.
                    // Short ones ride with the next, so "Fine." is not a line of its own.
                    var cursor = spoken
                    while let end = Self.sentenceEnd(in: said, after: cursor) {
                        let piece = String(said.dropFirst(spoken).prefix(end - spoken)).trimmingCharacters(in: .whitespacesAndNewlines)
                        cursor = end
                        if piece.count >= 40 {
                            say(piece, emotion: nil)
                            spoken = end
                        }
                    }
                } else if event.done == true {
                    reply = event.reply
                    ignored = event.ignored ?? false
                }
            }
        } catch HaruError.signedOut {
            session.signedIn = false
            return
        } catch {
            failure = error.localizedDescription
        }

        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let failure {
            entries[i] = Entry(id: id, kind: .system, text: failure)
            if let talk { act(talk.replied(now, willSpeak: false)) }
            return
        }
        let final = (reply ?? said).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            entries[i] = Entry(id: id, kind: .system, text: ignored ? "Seen. She is not answering that." : "She had nothing to say.")
            if let talk { act(talk.replied(now, willSpeak: false)) }
            return
        }
        entries[i].text = final
        entries[i].waiting = false
        // By voice, she is now speaking until her last line ends; if no voice
        // ever starts, the queue hands the turn back on its own.
        if let talk { act(talk.replied(now, willSpeak: true)) }
        // The rest of it, and her face for the whole. Neither is waited for.
        let rest = String(final.dropFirst(min(spoken, final.count))).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { say(rest, emotion: nil) } else { drain() }
        Task { await express(final) }
        // The reply's id — what a thumb or a retry needs — only exists on the
        // server. A quiet reload picks it up, and anything she added since.
        await load()
    }

    private func paint(_ id: String, _ text: String, waiting: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].text = text
        entries[i].waiting = waiting
    }

    /// A line she said on her own — a nudge, a comeback: her face and her
    /// voice, both at once. Neither waits for the other.
    func react(to line: String) async {
        say(line, emotion: nil)
        await express(line)
    }

    /// What her face does about a line: a round trip to a model, so it lands
    /// when it lands. The mood word is what the stage's SVG faces are keyed
    /// by, the same way the phone page keys them.
    func express(_ line: String) async {
        let mood: Expression? = try? await client.post("/api/expression", ["text": .string(line)])
        if let e = mood?.emotion, !e.isEmpty {
            emotion = e
            stage.express(e)
        }
    }

    /// Where a sentence ends after `start`, as a character offset into `text`,
    /// or nil when none has ended yet. A full stop, question or exclamation
    /// mark followed by a capital (or a new paragraph) — never an ellipsis or a
    /// "Hmm." that runs on in lower case: those are her pauses, and cutting a
    /// clip there made a breath into a splice.
    static func sentenceEnd(in text: String, after start: Int) -> Int? {
        let rest = text.dropFirst(start)
        guard let hit = rest.range(of: #"[.!?]+["”’)\]]*(?=\s+(?:[A-Z"“‘(\[]|\n)|\n)"#, options: .regularExpression) else { return nil }
        return start + rest.distance(from: rest.startIndex, to: hit.upperBound)
    }

    // MARK: Her voice, in order

    /// Queues a line for her to say. Fetching starts at once, in order; each
    /// line plays when the one before it ends.
    func say(_ text: String, emotion: String?) {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let emotion { body["emotion"] = .string(emotion) }
        let client = self.client
        // 503 when her voice is switched off for the web: the right amount of fuss is none.
        lines.append(Task { try? await client.bytes("/api/speak", post: body) })
        if !draining && !audio.speaking { drain() }
    }

    /// Plays the next fetched line, or, with nothing left, hands the turn back.
    private func drain() {
        guard !lines.isEmpty else {
            draining = false
            if let talk { act(talk.spokeEnd(now)) }
            return
        }
        draining = true
        let next = lines.removeFirst()
        Task {
            let data = await next.value
            guard draining else { return }
            if let data, audio.play(data) {
                // Looking at them for as long as the line runs.
                stage.attend("talking", ms: Int(audio.remaining * 1000) + 500)
            } else {
                drain()
            }
        }
    }

    /// Stops her mid-line and forgets what she was about to say. Returns
    /// whether she was actually talking.
    @discardableResult
    private func hush() -> Bool {
        for line in lines { line.cancel() }
        lines = []
        draining = false
        return audio.stop()
    }

    // MARK: Thumbs

    func rate(_ entry: Entry, _ reaction: String) async {
        guard let id = entry.serverID else { return }
        do {
            let rated: Rated = try await client.post("/api/chat/rate", ["id": .string(id), "reaction": .string(reaction)])
            if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].reaction = reaction }
            if let line = rated.line, !line.isEmpty {
                entries.append(Entry(id: UUID().uuidString, kind: .her, text: line))
                Task { await react(to: line) }
            }
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Her speaking first

    /// Asked on opening, when the app comes back, and every few minutes while it
    /// is open. The deciding is all on her side; most of these return nothing.
    func askIfSheHasSomethingToSay() async {
        guard !busy, Date().timeIntervalSince(lastAskedAt) > 30 else { return }
        lastAskedAt = Date()
        do {
            let nudge: Nudge = try await client.get("/api/nudge")
            guard let line = nudge.line, !line.isEmpty else { return }
            entries.append(Entry(id: UUID().uuidString, kind: .her, text: line))
            Task { await react(to: line) }
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            // She is out of reach for a moment; nothing to say about it.
        }
    }

    // MARK: Files

    func attach(name: String, data: Data, type: String) async {
        do {
            let answer: Staged = try await client.upload("/api/attach", data: data, type: type, query: ["name": name])
            staged.append(StagedFile(name: name, record: answer.attachment))
        } catch {
            notice = error.localizedDescription
        }
    }

    func discard(_ file: StagedFile) async {
        staged.removeAll { $0.id == file.id }
        let _: Okay? = try? await client.post("/api/attach/discard", ["attachment": file.record])
    }

    // MARK: By voice

    /// Opens the ear. Awake from the start: the tap is already her name. From
    /// then on she listens for "Haru" or "Hey Haru" and for anything said
    /// while she is awake, and speaking over her cuts her off.
    func startTalking() async {
        guard talk == nil else { return }
        guard await Audio.allowed() else {
            notice = "The microphone is switched off for Haru in Settings."
            return
        }
        do {
            try audio.listen(true)
        } catch {
            notice = "The microphone would not start: \(error.localizedDescription)"
            return
        }
        let talk = Talk()
        self.talk = talk
        act(talk.start(now, awake: true))
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let talk = self.talk else { return }
                self.act(talk.tick(self.now))
            }
        }
    }

    func stopTalking() {
        guard let talk else { return }
        act(talk.stop())
        self.talk = nil
        ticker?.invalidate()
        ticker = nil
        try? audio.listen(false)
    }

    /// A stretch of their voice, through her ears on the server, then to the
    /// conversation.
    private func hear(_ wav: Data) async {
        guard talk != nil else { return }
        transcribing = true
        defer { transcribing = false }
        do {
            let heard: Heard = try await client.upload("/api/listen", data: wav, type: "audio/wav")
            guard let text = heard.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let talk else { return }
            act(talk.heard(text, now))
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            // A missed stretch is not worth a word; the next one comes on its own.
        }
    }

    private func act(_ actions: [TalkAction]) {
        for action in actions {
            switch action {
            case .say(let text, let interrupted):
                Task { await send(text, spokeOver: interrupted) }
            case .ack:
                Task { await acknowledge() }
            case .interrupt:
                hush()
            case .off, .asleep, .awake, .speaking:
                break
            }
        }
        talkState = talk?.state ?? .off
    }

    /// Her name and nothing else: a word from her, in a mood, and an open ear.
    private func acknowledge() async {
        do {
            let word: WakeWord = try await client.post("/api/wake")
            guard let line = word.line, !line.isEmpty else {
                // Nothing to say — no sign they are up, or she said hello not long ago.
                if let talk { act(talk.spokeEnd(now)) }
                return
            }
            entries.append(Entry(id: UUID().uuidString, kind: .her, text: line))
            if let e = word.emotion, !e.isEmpty {
                emotion = e
                stage.express(e)
            }
            stage.attend("talking", ms: 2_500)
            say(line, emotion: word.emotion)
        } catch {
            if let talk { act(talk.spokeEnd(now)) }
        }
    }
}
