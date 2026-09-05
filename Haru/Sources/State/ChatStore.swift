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

/// Where a call through Hume stands. Off is the ordinary state; the rest
/// only while the mic is on and she is being reached speech to speech.
enum CallState { case off, connecting, listening, thinking, speaking }

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
    /// The call, when the mic is on and she is being reached through Hume.
    private(set) var call: EviCall?
    private(set) var callState = CallState.off
    /// What she said while a tool ran, for the pill; nil once the reply comes.
    private(set) var callFiller: String?
    /// Whether a call can be placed, from the server; nil until asked.
    private(set) var eviStatus: EviStatus?

    let session: Session
    let audio = Audio()
    let stage = Stage()
    private var talk: Talk?
    private var ticker: Timer?
    private var lastAskedAt = Date.distantPast
    /// Her lines being fetched, in the order she will say them, each with the
    /// breath (in milliseconds) she takes before it — none before the first.
    private var lines: [(gap: Int, fetch: Task<Data?, Never>)] = []
    private var draining = false
    private var spokeSomething = false
    /// Her reply on the call, as it arrives a sentence at a time, and its bubble.
    private var callReply = ""
    private var callReplyID: String?

    init(session: Session) {
        self.session = session
        audio.onLevel = { [weak self] level in self?.stage.mouth(level) }
        audio.onFinished = { [weak self] in
            guard let self else { return }
            // She has gone quiet: the server's ear can stop discounting her echo.
            self.call?.her(speaking: false)
            self.drain()
        }
        audio.onVoiceStart = { [weak self] in
            guard let self, let talk = self.talk else { return }
            self.act(talk.voiceStarted(self.now))
            if talk.state != .asleep { self.stage.attend("typing", ms: 1_500) }
        }
        audio.onVoiceEnd = { [weak self] wav in
            guard let self else { return }
            Task { await self.hear(wav) }
        }
        audio.onFrames = { [weak self] pcm in self?.call?.send(pcm) }
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

    /// Sent while she is still answering — the composer has already let go
    /// of the text — it waits for her to finish rather than drop it. False
    /// when she took too long, so the composer can put the text back.
    @discardableResult
    func send(_ raw: String, spokeOver: Bool = false) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = staged
        guard !text.isEmpty || !files.isEmpty else { return true }
        // One voice at a time: something typed ends the call, and is answered
        // the ordinary way, in her ordinary voice.
        if call != nil { endCall() }
        let since = Date()
        while busy {
            if Date().timeIntervalSince(since) > 90 {
                notice = "She is still answering. Say it again in a moment."
                return false
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
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
        return true
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
        // The first line goes out as soon as one sentence has ended, for the
        // sake of her first word; after that, whole paragraphs or a good run
        // of sentences — one take per stretch keeps her timbre steady, where a
        // take per sentence made her sound assembled.
        var firstLineOut = false
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
                        let raw = String(said.dropFirst(spoken).prefix(end - spoken))
                        let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        cursor = end
                        let paragraphEnds = said.dropFirst(end).hasPrefix("\n")
                        let enough = piece.count >= (firstLineOut ? 160 : 40)
                        if piece.count >= 40 && (enough || paragraphEnds) {
                            // A new paragraph is where she breathes: one of her
                            // recorded sighs goes in the gap, as it does at the desk.
                            let newParagraph = spoken > 0 && (raw.hasPrefix("\n") || said.dropFirst(max(0, spoken - 2)).prefix(2) == "\n\n")
                            if newParagraph { sigh() }
                            // In the mood she is in — the new one lands after
                            // the words, and the lines after it take it up.
                            say(piece, emotion: emotion, gap: newParagraph ? 450 : 280)
                            spoken = end
                            firstLineOut = true
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
        if !rest.isEmpty {
            let newParagraph = spoken > 0 && String(final.dropFirst(min(spoken, final.count))).hasPrefix("\n")
            if newParagraph { sigh() }
            say(rest, emotion: emotion, gap: newParagraph ? 450 : 280)
        } else {
            drain()
        }
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
        say(line, emotion: emotion)
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
    /// line plays when the one before it ends, after `gap` milliseconds of
    /// breath — a sentence's worth by default. Two lines run together sound
    /// like one person reading; a pause between them sounds like one talking.
    func say(_ text: String, emotion: String?, gap: Int = 280) {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let emotion { body["emotion"] = .string(emotion) }
        let client = self.client
        // 503 when her voice is switched off for the web: the right amount of fuss is none.
        lines.append((gap: gap, fetch: Task { try? await client.bytes("/api/speak", post: body) }))
        if !draining && !audio.speaking { drain() }
    }

    /// One of her recorded sighs or grunts, in her current mood, for the gap
    /// between two paragraphs. Fetched like a line and played in its turn; a
    /// 404 (she has none for that) simply plays nothing.
    func sigh() {
        let client = self.client
        let mood = emotion
        lines.append((gap: 350, fetch: Task { try? await client.bytes("/api/sigh", query: ["emotion": mood]) }))
        if !draining && !audio.speaking { drain() }
    }

    /// Plays the next fetched line, or, with nothing left, hands the turn back.
    private func drain() {
        guard !lines.isEmpty else {
            draining = false
            spokeSomething = false
            if let talk { act(talk.spokeEnd(now)) }
            if call != nil, callState == .speaking { callState = .listening }
            return
        }
        draining = true
        let next = lines.removeFirst()
        Task {
            let data = await next.fetch.value
            guard draining else { return }
            // The breath before this line, once something has been said.
            if spokeSomething, next.gap > 0 {
                try? await Task.sleep(for: .milliseconds(next.gap))
                guard draining else { return }
            }
            if let data, audio.play(data) {
                spokeSomething = true
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
        for line in lines { line.fetch.cancel() }
        lines = []
        draining = false
        spokeSomething = false
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

    // MARK: On a call

    /// Whether the mic button is lit: a call, or the ordinary talk mode.
    var micOn: Bool { call != nil || talk != nil }

    /// The user's choice in More: the mic opens a call through Hume when the
    /// server can place one, else the ordinary talk mode. On by default.
    private var prefersCall: Bool {
        UserDefaults.standard.object(forKey: "talk.evi") as? Bool ?? true
    }

    func refreshEvi() async {
        eviStatus = try? await client.get("/api/evi/status")
    }

    /// The mic button. Off if anything is on; else a call if the phone wants
    /// one and she can take it, else the ordinary ear.
    func toggleMic() async {
        if call != nil { endCall(); return }
        if talk != nil { stopTalking(); return }
        if prefersCall {
            await refreshEvi()
            if eviStatus?.enabled == true { await startCall(); return }
        }
        await startTalking()
    }

    /// Places the call: the microphone streams up as it comes, and Hume does
    /// the hearing, the deciding and the saying. Her words still come from
    /// her own brain, through the server's hook.
    func startCall() async {
        guard call == nil, talk == nil else { return }
        guard await Audio.allowed() else {
            notice = "The microphone is switched off for Haru in Settings."
            return
        }
        audio.echoCancelling = UserDefaults.standard.object(forKey: "talk.echoCancel") as? Bool ?? true
        do {
            try audio.listen(true)
        } catch {
            notice = "The microphone would not start: \(error.localizedDescription)"
            return
        }
        callState = .connecting
        callReply = ""
        callReplyID = nil
        let call = EviCall(client: client) { [weak self] event in
            Task { @MainActor in self?.handleCall(event) }
        }
        self.call = call
        audio.stream(true)
        call.start()
    }

    /// Hangs up, from this end or because the far end did.
    func endCall() {
        guard let call else { return }
        audio.stream(false)
        call.stop()
        self.call = nil
        hush()
        try? audio.listen(false)
        callState = .off
        callFiller = nil
        callReply = ""
        callReplyID = nil
    }

    private func handleCall(_ event: EviCall.Event) {
        guard call != nil else { return }
        switch event {
        case .ready:
            callState = .listening
        case .refused(let why):
            notice = why
            endCall()
        case .heard(let text, let interim):
            guard !interim, !text.isEmpty else { return }
            // What Hume heard is what her brain is answering: their bubble.
            entries.append(Entry(id: UUID().uuidString, kind: .me, text: text))
            callReply = ""
            callReplyID = nil
            callState = .thinking
            stage.attend("thinking", ms: 20_000)
        case .filler(let text):
            callFiller = text
            callState = .speaking
        case .said(let text, _):
            guard !text.isEmpty else { return }
            callFiller = nil
            if let id = callReplyID, let i = entries.firstIndex(where: { $0.id == id }) {
                callReply += " " + text
                entries[i].text = callReply
            } else {
                let id = UUID().uuidString
                callReply = text
                callReplyID = id
                entries.append(Entry(id: id, kind: .her, text: text))
            }
            callState = .speaking
        case .voice(let wav):
            play(wav)
        case .voiceStart(_, let sampleRate):
            // Streamed: whatever whole lines were queued are hers no longer.
            for line in lines { line.fetch.cancel() }
            lines = []
            draining = false
            audio.beginStream(sampleRate: sampleRate)
            call?.her(speaking: true)
            stage.attend("talking", ms: 4_000)
        case .pcm(let data):
            audio.feedStream(data)
        case .voiceEnd:
            audio.endStream()
        case .turnEnded(let emotion):
            callFiller = nil
            if let emotion, !emotion.isEmpty {
                // The face came with the turn; no model to ask.
                self.emotion = emotion
                stage.express(emotion)
            } else if !callReply.isEmpty {
                let line = callReply
                Task { await express(line) }
            }
            if callState == .thinking || (callState == .speaking && !draining && !audio.speaking) { callState = .listening }
        case .interrupted:
            hush()
            callFiller = nil
            callState = .listening
            stage.attend("typing", ms: 1_500)
        case .failed(let message):
            notice = message
        case .ended(let reason):
            endCall()
            notice = "The call ended — \(reason)."
        }
    }

    /// Her voice off the call, a sentence at a time, played in order.
    private func play(_ wav: Data) {
        lines.append((gap: 0, fetch: Task<Data?, Never> { wav }))
        if !draining && !audio.speaking { drain() }
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
        audio.echoCancelling = UserDefaults.standard.object(forKey: "talk.echoCancel") as? Bool ?? true
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
