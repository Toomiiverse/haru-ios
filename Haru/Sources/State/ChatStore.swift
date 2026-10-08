import Foundation
import Observation
import UIKit
import UserNotifications
import WidgetKit

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
    /// The pictures among them, shown in the bubble rather than named.
    var pictures: [Picture] = []
    /// His message answers this line of hers: shown above his words.
    var quote: String? = nil

    var parts: [String] {
        guard kind == .her, !aside else { return [text] }
        let pieces = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [text] : pieces
    }
}

/// A picture in a bubble: the bytes the phone already had when it was sent, or
/// the kept copy's name on her machine for one that came back with the day.
struct Picture: Identifiable, Hashable {
    let id = UUID()
    var data: Data?
    var saved: String?
    /// Blurred until he taps it: a picture she drew, not one he sent.
    var isPrivate = false
}

/// A file already copied into her keeping, waiting to ride the next message.
struct StagedFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let record: JSONValue
    /// The picture itself, for the preview above the composer; nil for a file.
    var preview: Data?
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
    /// She is asleep, from /api/status (ChatView keeps it): the stage holds
    /// her sleeping face, and no line's expression lifts it — a reply while
    /// she sleeps is her asleep-answer, not her waking up.
    var herAsleep = false {
        didSet {
            guard herAsleep != oldValue else { return }
            if herAsleep { emotion = "sleepy"; stage.express("sleepy") }
        }
    }
    var staged: [StagedFile] = []
    /// The line of hers he is about to answer, set by a swipe on her bubble.
    var replyingTo: Entry?
    /// She was stopped mid-line by a tap; rides the next message as `interrupted`.
    private var cutOff = false
    var transcribing = false
    /// Something worth an alert. Cleared by the view.
    var notice: String?
    /// The conversation by voice: off, or where it stands.
    private(set) var talkState = TalkState.off
    /// The call, when the mic is on and she is being reached through Hume.
    private(set) var call: EviCall?
    private(set) var callState = CallState.off {
        didSet { PhoneTools.shared.activity(callActive: callState == .listening || callState == .thinking || callState == .speaking) }
    }
    /// What she said while a tool ran, for the pill; nil once the reply comes.
    private(set) var callFiller: String?
    /// Whether a call can be placed, from the server; nil until asked.
    private(set) var eviStatus: EviStatus?
    /// Standby: the microphone open with the phone locked, listening on the
    /// phone for "Hey Haru" and nothing else, and a call when she hears it.
    private(set) var standby = false
    /// Standby is on but not listening: something else took the microphone,
    /// and iOS would not give it back while the phone was locked.
    private(set) var standbyPaused = false

    let session: Session
    let audio = Audio()
    let stage = Stage()
    private var talk: Talk?
    private var ticker: Timer?
    private var lastAskedAt = Date.distantPast
    /// Her lines being fetched, in the order she will say them, each with the
    /// breath (in milliseconds) she takes before it — none before the first.
    private enum VoiceFetch {
        case stream(SpeechDownload)
        case clip(Task<Data?, Never>)

        func cancel() {
            switch self {
            case .stream(let download): download.cancel()
            case .clip(let task): task.cancel()
            }
        }
    }
    private var lines: [(gap: Int, fetch: VoiceFetch)] = []
    private var activeLine: VoiceFetch?
    private var drainTask: Task<Void, Never>?
    private var voiceGeneration = 0
    private var draining = false
    private var spokeSomething = false
    /// Her reply on the call, as it arrives a sentence at a time, and its bubble.
    private var callReply = ""
    private var callReplyID: String?
    private var wake: NameSpotter?
    /// Which ears are listening for her name, for the More screen.
    private(set) var wakeEngine = ""
    private var gate: VoiceGate?
    /// Teaching her his voice: takes so far, nil when not.
    private(set) var enrolling: Int?
    private var enrolOpenedEar = false
    /// Wakes in another voice she let pass, since launch; for the More screen.
    private(set) var strangerWakes = 0
    var strangerLine: String { strangerWakes == 0 ? "" : "\(strangerWakes) in another voice ignored" }
    /// This call came from her name in standby, so it hangs itself up when the
    /// talking stops — nobody is holding a phone to end it.
    private var callFromStandby = false
    private var lastCallActivity = Date()
    private var idleWatch: Timer?
    private var batteryWatcher: NSObjectProtocol?
    /// Standby while she sleeps: the ear stays open (iOS would not open it
    /// again with the phone locked) but her name goes unheard until she wakes.
    private(set) var standbyAsleep = false
    private var sleepWatch: Timer?
    private var wakeAlarm: Timer?

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
            self?.lastCallActivity = Date()
            guard let self, let talk = self.talk else { return }
            // Asked for one thing and they have started saying it: the window
            // opens again from here, so it cannot close on them mid-sentence.
            if self.askingOnce, talk.state == .awake { self.act(talk.start(self.now, awake: true)) }
            self.act(talk.voiceStarted(self.now))
            if talk.state != .asleep { self.stage.attend("typing", ms: 1_500) }
        }
        audio.onVoiceEnd = { [weak self] wav in
            guard let self else { return }
            if self.enrolling != nil { Task { await self.enrolTake(wav) }; return }
            Task { await self.hear(wav) }
        }
        audio.onCapturedFrames = { [weak self] pcm, captured in self?.call?.send(pcm, capturedAt:captured) }
        audio.onPlaybackEstimate = { [weak self] turn, id, rendered, output, prime, underruns in
            self?.call?.playbackEstimate(turn:turn,id:id,renderedAt:rendered,outputMs:output,primeMs:prime,underruns:underruns)
        }
        audio.onInterruption = { [weak self] began, _ in
            guard let self, self.standby else { return }
            if began {
                self.standbyPaused = true
                if self.call != nil { self.endCall() }
            } else {
                self.resumeStandby(notifyIfNot: true)
            }
        }
        watchLive()
    }

    // MARK: The lock screen (Live Activity)

    /// What the Live Activity should say, or nil for none: a call over
    /// standby, standby's three conditions otherwise.
    private var livePhase: Live.Phase? {
        switch callState {
        case .connecting: return .connecting
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .off: break
        }
        guard standby else { return nil }
        if standbyPaused { return .paused }
        return standbyAsleep ? .asleep : .standby
    }

    /// Follows the properties `livePhase` reads, so no call site has to
    /// remember the lock screen. onChange fires before the change lands, hence
    /// the hop; tracking is one-shot, hence the re-arm.
    private func watchLive() {
        withObservationTracking { _ = livePhase } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshLive()
                self?.watchLive()
            }
        }
    }

    /// Also called when the app comes to the front: the only time iOS lets an
    /// activity start, and standby may have outlived the last one (8 hours).
    func refreshLive() { Live.show(livePhase) }

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
                    reaction: m.reaction,
                    attachmentNames: m.attachments.filter { $0.kind != "image" }.map(\.name),
                    pictures: m.attachments.filter { $0.kind == "image" }.map { Picture(saved: $0.saved, isPrivate: $0.isPrivate) },
                    quote: m.replyTo?.excerpt
                )
            }
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            notice = error.localizedDescription
        }
    }


    /// A harder task from the phone's conversation uses the normal authenticated server chat stream.
    /// The caller owns the visible/persistent transcript. No automatic replay after an unknown outcome.
    func replyForLocalHandoff(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard session.signedIn == true else {
                    continuation.finish(throwing: LocalChatError.message("Sign in to Haru’s server for this task. Local conversation remains available."))
                    return
                }
                guard !busy, call == nil, !micOn else {
                    continuation.finish(throwing: LocalChatError.message("Finish the current server reply or call before sending this task."))
                    return
                }
                busy = true
                defer { busy = false }
                var body: [String: JSONValue] = ["text": .string(text)]
                let files = staged
                if !files.isEmpty { body["attachments"] = .array(files.map(\.record)) }
                staged = []
                _ = tapToHush()
                stage.attend("thinking", ms: 20_000)
                var reply = ""
                var done = false
                var speech = ChatSpeechDelivery()
                do {
                    for try await event in client.stream("/api/chat/stream", body) {
                        try Task.checkCancellation()
                        if let error = event.error { throw LocalChatError.message(error) }
                        if event.text == "\u{FFFD}" {
                            reply = ""; speech.reset(); _ = tapToHush(); continuation.yield("")
                        } else if let chunk = event.text, !chunk.isEmpty {
                            reply += chunk; continuation.yield(reply)
                        } else if let sentence = event.sentence {
                            for line in speech.receive(sentence, emotion: event.emotion) { say(line.text, emotion: line.emotion) }
                        } else if event.done == true {
                            guard event.ignored != true else { throw LocalChatError.message("The server did not answer this request.") }
                            if let final = event.reply { reply = final; continuation.yield(final) }
                            done = true
                        }
                    }
                    guard done, !reply.isEmpty else {
                        throw LocalChatError.message("The server connection ended before the reply was confirmed. The task was not retried; check its outcome before sending it again.")
                    }
                    for line in speech.finish(fallbackText: reply) { say(line.text, emotion: line.emotion) }
                    continuation.finish()
                } catch {
                    _ = tapToHush()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
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
        // Taken here, after the wait: a send that gives up above keeps its target,
        // so text that goes back into the box goes back with the line it answered.
        let answering = replyingTo
        replyingTo = nil
        // Said over her, while she was still speaking: she is told so.
        let interrupted = hush() || spokeOver || cutOff
        cutOff = false

        entries.append(Entry(
            id: UUID().uuidString, kind: .me, text: text,
            attachmentNames: files.filter { $0.preview == nil }.map(\.name),
            pictures: files.compactMap { file in file.preview.map { Picture(data: $0) } },
            quote: answering.map { Self.excerpt(of: $0.text) }
        ))
        let waitID = UUID().uuidString
        entries.append(Entry(id: waitID, kind: .her, text: "", waiting: true))

        var body: [String: JSONValue] = ["text": .string(text)]
        if !files.isEmpty { body["attachments"] = .array(files.map(\.record)) }
        if interrupted { body["interrupted"] = true }
        if let answering {
            // The id when the phone has one; the start of the line when it is a
            // reply just streamed. The server checks either against what she said.
            if let id = answering.serverID { body["replyTo"] = .string(id) }
            body["quoted"] = .string(Self.excerpt(of: answering.text))
        }
        stage.attend("thinking", ms: 20_000)
        await run(client.stream("/api/chat/stream", body), into: waitID)
        return true
    }

    /// Enough of her line to know it by: the first 140 characters, cut at a word.
    /// Whitespace flattened the way the server flattens it, so its match holds.
    nonisolated static func excerpt(of text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > 140 else { return flat }
        let cut = flat.prefix(140)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
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
        var delivery = ChatSpeechDelivery()
        do {
            for try await event in stream {
                if let error = event.error {
                    failure = error
                } else if event.text == "\u{FFFD}" {
                    // The round was thrown away; back to waiting, and whatever
                    // she had started saying of it goes too.
                    said = ""
                    delivery.reset()
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
                } else if let sentence = event.sentence {
                    for line in delivery.receive(sentence, emotion: event.emotion) {
                        say(line.text, emotion: line.emotion)
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
        // Sentence events carry the server's delivery; visible text is never
        // voiced a second time. Older servers without events use one final take.
        for line in delivery.finish(fallbackText: final) {
            say(line.text, emotion: line.emotion)
        }
        drain()
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
        guard !herAsleep else { stage.express("sleepy"); return }
        let mood: Expression? = try? await client.post("/api/expression", ["text": .string(line)])
        if let e = mood?.emotion, !e.isEmpty, !herAsleep {
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
        // 503 when her voice is switched off for the web: the right amount of fuss is none.
        lines.append((gap: gap, fetch: .stream(client.speech(text, emotion: emotion))))
        if !draining && !audio.speaking { drain() }
    }

    /// One of her recorded sighs or grunts, in her current mood, for the gap
    /// between two paragraphs. Fetched like a line and played in its turn; a
    /// 404 (she has none for that) simply plays nothing.
    func sigh() {
        let client = self.client
        let mood = emotion
        lines.append((gap: 350, fetch: .clip(Task { try? await client.bytes("/api/sigh", query: ["emotion": mood]) })))
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
        activeLine = next.fetch
        let generation = voiceGeneration
        drainTask = Task {
            var streaming = false
            var playingFile = false
            do {
                // No pause before the first line. Later lines can download
                // during this breath and during the preceding sentence.
                if spokeSomething, next.gap > 0 { try await Task.sleep(for: .milliseconds(next.gap)) }
                try Task.checkCancellation()
                guard generation == voiceGeneration else { return }
                switch next.fetch {
                case .clip(let fetch):
                    let data = await fetch.value
                    try Task.checkCancellation()
                    guard generation == voiceGeneration else { return }
                    if let data { playingFile = audio.play(data) }
                case .stream(let download):
                    for try await part in download.parts {
                        try Task.checkCancellation()
                        guard generation == voiceGeneration else { return }
                        switch part {
                        case .format(let rate):
                            audio.beginStream(sampleRate: rate)
                            streaming = true
                        case .pcm(let data):
                            audio.feedStream(data)
                            spokeSomething = true
                            stage.attend("talking", ms: Int(audio.remaining * 1000) + 500)
                        case .file(let data): playingFile = audio.play(data)
                        }
                    }
                }
                guard generation == voiceGeneration else { return }
                activeLine = nil
                if playingFile {
                    spokeSomething = true
                    stage.attend("talking", ms: Int(audio.remaining * 1000) + 500)
                }
                if streaming { audio.endStream() }
                else if !playingFile { drain() }
            } catch {
                guard generation == voiceGeneration else { return }
                activeLine = nil
                // Finish any audio already queued; onFinished advances the
                // queue. An interrupted old request can never restart it.
                if streaming { audio.endStream() }
                else { drain() }
            }
        }
    }

    private func cancelLines() {
        voiceGeneration += 1
        drainTask?.cancel()
        drainTask = nil
        activeLine?.cancel()
        activeLine = nil
        for line in lines { line.fetch.cancel() }
        lines = []
        draining = false
        spokeSomething = false
    }

    /// Stops her mid-line and forgets what she was about to say. Returns
    /// whether she was actually talking.
    @discardableResult
    private func hush() -> Bool {
        cancelLines()
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

    /// What was wrong with a reply of hers, and what it should have been.
    ///
    /// Not a rating. Nothing of this reaches her — it lands in the tuning log
    /// on the desk, for him to read at the end of a day — so the bubble does
    /// not change and she never answers back. True when it was written down.
    func tune(_ entry: Entry, wrong: String, rather: String) async -> Bool {
        guard let id = entry.serverID else { return false }
        do {
            let _: Okay = try await client.post("/api/chat/tune", ["id": .string(id), "wrong": .string(wrong), "rather": .string(rather)])
            return true
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            notice = error.localizedDescription
        }
        return false
    }

    // MARK: Her ears

    /// What she heard against what was said. She keeps the word that differs
    /// and rewrites it on every take from now on, calls included.
    @discardableResult
    func teach(heard: String, meant: String) async -> Bool {
        do {
            let taught: HearingTaught = try await client.post("/api/hearing", ["heard": .string(heard), "meant": .string(meant)])
            if let pair = taught.learned {
                notice = "She'll hear “\(pair.heard)” as “\(pair.meant)” from now on."
            } else {
                notice = "Nothing to learn from that — the sentences are the same, or too different to pin on a word."
            }
            return true
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            notice = error.localizedDescription
        }
        return false
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
            staged.append(StagedFile(name: name, record: answer.attachment, preview: type.hasPrefix("image/") ? data : nil))
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

    func refreshEvi() async {
        eviStatus = try? await client.get("/api/evi/status")
    }

    /// Whether the ear is open for one question only — a tap — and closes
    /// itself once that question is on its way, or when nothing was said.
    private(set) var askingOnce = false
    /// How long a tap waits for the question before the ear closes on its own.
    private static let askOnceMs = 10_000.0

    /// A tap on the mic. Off if anything is on; else her ears for one question
    /// — she listens, writes it down, answers as she does a message, in her
    /// voice, and the mic closes itself. Hands free: no keyboard, no dictation.
    func toggleMic() async {
        if call != nil { endCall(); return }
        if talk != nil { stopTalking(); return }
        await askOnce()
    }

    /// Holding the mic: a call, where she can take one.
    func holdMic() async {
        if call != nil { endCall(); return }
        if talk != nil { stopTalking() }
        await refreshEvi()
        guard eviStatus?.enabled == true else {
            notice = "She can't take a call right now — \(callReason)."
            return
        }
        await startCall()
    }

    private var callReason: String {
        switch eviStatus?.reason {
        case "off": return "calls are switched off on her server"
        case "not set up": return "calls are not set up on her server"
        case "asleep": return "she is asleep"
        case "cap": return "that's the day's allowance"
        default: return "not available"
        }
    }

    /// Her model tapped while she is mid-line: she stops, and the next thing
    /// said to her is said over her — which she is told, as when spoken over.
    /// False when she was not talking, so the tap can mean what it used to.
    /// A picture she was sent, back from her keeping, for a bubble that came
    /// with the day rather than from this phone's camera roll.
    func picture(saved: String) async -> Data? {
        let name = (saved as NSString).lastPathComponent
        guard let data = try? await client.bytes("/api/attach/file", query: ["saved": name]), !data.isEmpty else { return nil }
        return data
    }

    func tapToHush() -> Bool {
        guard audio.speaking || draining else { return false }
        hush()
        cutOff = true
        return true
    }

    func askOnce() async {
        guard call == nil, talk == nil else { return }
        // Tapped while she is talking: they have something to ask over it.
        if audio.speaking { hush() }
        askingOnce = true
        await startTalking()
        if talk == nil { askingOnce = false }
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
        defer { if standby { Task { await refreshEvi(); applySleep() } } }
        guard let call else { return }
        audio.stream(false)
        call.stop()
        self.call = nil
        hush()
        // In standby the microphone stays open — iOS will not start it again
        // with the phone locked — and goes back to listening for her name.
        if standby { wake?.reset() } else { try? audio.listen(false) }
        callFromStandby = false
        idleWatch?.invalidate()
        idleWatch = nil
        callState = .off
        callFiller = nil
        callReply = ""
        callReplyID = nil
    }

    private func handleCall(_ event: EviCall.Event) {
        guard call != nil else { return }
        switch event {
        case .heard, .said, .filler, .voiceStart, .pcm, .interrupted:
            lastCallActivity = Date()
        default:
            break
        }
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
        case .voiceStart(let id, let sampleRate, let turn):
            // Streamed: whatever whole lines were queued are hers no longer.
            cancelLines()
            audio.beginStream(sampleRate: sampleRate, timingTurn:turn, timingID:id)
            call?.her(speaking: true)
            stage.attend("talking", ms: 4_000)
        case .pcm(let data):
            audio.feedStream(data)
        case .voiceEnd:
            audio.endStream()
        case .turnEnded(let emotion):
            callFiller = nil
            if herAsleep {
                stage.express("sleepy")
            } else if let emotion, !emotion.isEmpty {
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
        lines.append((gap: 0, fetch: .clip(Task<Data?, Never> { wav })))
        if !draining && !audio.speaking { drain() }
    }

    // MARK: Standby

    /// Switched on or off from More. On needs the app open: iOS lets a
    /// recording that began in the foreground carry on with the phone locked,
    /// but never lets one begin there.
    func setStandby(_ on: Bool) async {
        // Whatever comes of it, the control's switch shows what is true (Controls.swift).
        defer {
            Shared.standby = standby
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: "com.toomiiverse.haru.control.standby") }
        }
        UserDefaults.standard.set(on, forKey: "standby.on")
        if !on {
            standby = false
            standbyPaused = false
            standbyAsleep = false
            sleepWatch?.invalidate(); sleepWatch = nil
            wakeAlarm?.invalidate(); wakeAlarm = nil
            audio.spot(nil)
            if call == nil, talk == nil { try? audio.listen(false) }
            updateDocked()
            return
        }
        guard !standby else { return }
        guard await Audio.allowed() else {
            notice = "The microphone is switched off for Haru in Settings."
            UserDefaults.standard.set(false, forKey: "standby.on")
            return
        }
        // The model trained on her name when the build carries it; the general
        // spotter otherwise (WakeModel.swift says why the model is preferred).
        if wake == nil {
            if let model = WakeModel() {
                wake = model
                wakeEngine = "trained on “Hey Haru”"
                // The model cannot score (it has happened in the background): the
                // general spotter takes over without the microphone closing.
                model.onBroken = { [weak self] in
                    guard let self, let spotter = WakeSpotter() else { return }
                    spotter.onWake = { [weak self] in Task { await self?.woken() } }
                    self.wake = spotter
                    self.wakeEngine = "keyword spotter (the trained model failed)"
                    if self.standby, !self.standbyAsleep { self.audio.spot(spotter) }
                }
            }
            else if let spotter = WakeSpotter() { wake = spotter; wakeEngine = "keyword spotter" }
        }
        guard let wake else {
            notice = "Her ears for “Hey Haru” are missing from this build."
            UserDefaults.standard.set(false, forKey: "standby.on")
            return
        }
        wake.onWake = { [weak self] in Task { await self?.woken() } }
        audio.echoCancelling = UserDefaults.standard.object(forKey: "talk.echoCancel") as? Bool ?? true
        do {
            try audio.listen(true)
        } catch {
            notice = "The microphone would not start: \(error.localizedDescription)"
            UserDefaults.standard.set(false, forKey: "standby.on")
            return
        }
        wake.reset()
        audio.spot(wake)
        standby = true
        standbyPaused = false
        watchBattery()
        updateDocked()
        startSleepWatch()
    }

    /// The app is open again: standby back on if it was wanted, and listening
    /// again if something had taken the microphone.
    func standbyOnActive() async {
        let wanted = UserDefaults.standard.bool(forKey: "standby.on")
        if wanted, !standby { await setStandby(true); return }
        if standby, standbyPaused || !audio.listening { resumeStandby(notifyIfNot: false) }
        updateDocked()
    }

    var standbyLine: String {
        if !standby { return "off" }
        if standbyPaused { return "paused — open Haru to listen again" }
        if standbyAsleep { return "she's asleep" + (wakesAtLine.map { " — until \($0)" } ?? "") }
        if call != nil { return "on a call" }
        return "listening for “Hey Haru”"
    }

    /// Her name, heard on the phone. A chime so they know, then the call.
    private func woken() async {
        guard standby, !standbyPaused, !standbyAsleep, call == nil, talk == nil, !audio.speaking, !busy, enrolling == nil else { return }
        // Whose voice: the two seconds around the phrase against his takes.
        if onlyMyVoice, let gate = loadedGate(), gate.isEnrolled {
            let (samples, rate) = audio.recent(seconds: 2)
            guard let vector = await gate.embedding(samples, rate: rate) else { return }
            let score = gate.score(vector)
            if score < VoiceGate.threshold {
                strangerWakes += 1
                return
            }
        }
        await refreshEvi()
        applySleep()
        guard eviStatus?.enabled == true, !standbyAsleep else {
            if !standbyAsleep { notice = "She heard her name, but can't take a call right now — \(callReason)." }
            return
        }
        audio.chime()
        stage.attend("thinking", ms: 3_000)
        callFromStandby = true
        await startCall()
        guard call != nil else {
            callFromStandby = false
            return
        }
        lastCallActivity = Date()
        idleWatch?.invalidate()
        idleWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hangUpIfIdle() }
        }
    }

    /// Nobody has said anything for a while, and she is not talking or
    /// thinking: the call from standby ends, and standby listens again.
    private static let standbyCallIdle: TimeInterval = 45
    private func hangUpIfIdle() {
        guard callFromStandby, call != nil else { return }
        if audio.speaking || draining || callState == .thinking || callState == .speaking || callState == .connecting {
            lastCallActivity = Date()
            return
        }
        if Date().timeIntervalSince(lastCallActivity) > Self.standbyCallIdle { endCall() }
    }

    // MARK: His voice

    /// Whether only his voice wakes her. On by default once she has been taught it.
    var onlyMyVoice: Bool {
        get { UserDefaults.standard.object(forKey: "voice.onlyMine") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice.onlyMine") }
    }

    var voiceTakes: Int { loadedGate()?.enrolled.count ?? 0 }
    var voiceKnown: Bool { loadedGate()?.isEnrolled ?? false }
    var voiceGateAvailable: Bool { loadedGate() != nil }

    /// The gate, loaded on first need with the takes it saved. It used to be
    /// made only by enrolment, so a relaunch or an update showed "not taught"
    /// and — worse — standby skipped the check and woke for anyone (build 58).
    private func loadedGate() -> VoiceGate? {
        if gate == nil { gate = VoiceGate() }
        return gate
    }

    /// Teaching her: the ear opens (if it is not already), and the next few
    /// stretches of speech are his "Hey Haru", each kept as a voice print and
    /// sent to her server for the wake-word model of his voice.
    func startEnrolment() async {
        guard enrolling == nil else { return }
        guard loadedGate() != nil else {
            notice = "Her ears for voices are missing from this build."
            return
        }
        guard await Audio.allowed() else {
            notice = "The microphone is switched off for Haru in Settings."
            return
        }
        if call != nil { endCall() }
        if talk != nil { stopTalking() }
        if !audio.listening {
            audio.echoCancelling = UserDefaults.standard.object(forKey: "talk.echoCancel") as? Bool ?? true
            do { try audio.listen(true) } catch {
                notice = "The microphone would not start: \(error.localizedDescription)"
                return
            }
            enrolOpenedEar = true
        }
        gate?.forget()
        enrolling = 0
    }

    func cancelEnrolment() {
        guard enrolling != nil else { return }
        enrolling = nil
        if enrolOpenedEar, !standby { try? audio.listen(false) }
        enrolOpenedEar = false
    }

    func forgetVoice() {
        loadedGate()?.forget()
        strangerWakes = 0
    }

    private func enrolTake(_ wav: Data) async {
        guard let count = enrolling, let gate = loadedGate(), let (samples, rate) = VoiceGate.samples(ofWav: [UInt8](wav)) else { return }
        let seconds = Double(samples.count) / rate
        // A take is her name and little else: under half a second is a cough,
        // over four is a sentence.
        guard seconds >= 0.5, seconds <= 4 else { return }
        guard let vector = await gate.embedding(samples, rate: rate) else { return }
        guard enrolling == count else { return }
        gate.enrol(vector)
        enrolling = count + 1
        Task {
            // For the wake-word model of his voice, trained on her server. Best effort.
            let _: Ignored? = try? await client.upload("/api/voice/enrol", data: wav, type: "audio/wav")
        }
        if count + 1 >= VoiceGate.takes {
            enrolling = nil
            if enrolOpenedEar, !standby { try? audio.listen(false) }
            enrolOpenedEar = false
            onlyMyVoice = true
            notice = "She knows your voice now. Only you wake her."
        }
    }

    // Her sleep, while standby is on: asked every few minutes (the open
    // microphone keeps the app running, so a timer fires even locked) and once
    // more at her wake time, so she is back listening within a minute of it.
    private static let sleepWatchEvery: TimeInterval = 5 * 60

    private func startSleepWatch() {
        sleepWatch?.invalidate()
        sleepWatch = Timer.scheduledTimer(withTimeInterval: Self.sleepWatchEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.standby else { return }
                await self.refreshEvi()
                self.applySleep()
            }
        }
        Task { await refreshEvi(); applySleep() }
    }

    private var wakesAtLine: String? {
        guard let text = eviStatus?.wakesAt, let date = ISO8601DateFormatter.withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Detaches or reattaches the spotter to match her sleep; nothing else changes.
    private func applySleep() {
        guard standby else { return }
        let asleep = eviStatus?.asleep == true
        if asleep != standbyAsleep {
            standbyAsleep = asleep
            audio.spot(asleep ? nil : wake)
            if !asleep { wake?.reset() }
        }
        wakeAlarm?.invalidate(); wakeAlarm = nil
        if asleep, let text = eviStatus?.wakesAt, let at = ISO8601DateFormatter.withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
            let delay = max(30, at.timeIntervalSinceNow + 45)
            wakeAlarm = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.standby else { return }
                    await self.refreshEvi()
                    self.applySleep()
                }
            }
        }
    }

    private func resumeStandby(notifyIfNot: Bool) {
        guard standby else { return }
        do {
            try audio.reopen()
            wake?.reset()
            standbyPaused = false
        } catch {
            standbyPaused = true
            guard notifyIfNot, UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = "Haru stopped listening"
            content.body = "Something else took the microphone. Open Haru to put standby back on."
            content.threadIdentifier = "haru-standby"
            let request = UNNotificationRequest(identifier: "haru-standby-paused", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Docked: on the charger with standby on, the screen stays awake, so the
    /// app stays in front and nothing about listening depends on the lock.
    private func updateDocked() {
        let state = UIDevice.current.batteryState
        UIApplication.shared.isIdleTimerDisabled = standby && (state == .charging || state == .full)
    }

    private func watchBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard batteryWatcher == nil else { return }
        batteryWatcher = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDocked() }
        }
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
        if askingOnce { talk.awakeMs = Self.askOnceMs }
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
        askingOnce = false
        act(talk.stop())
        self.talk = nil
        ticker?.invalidate()
        ticker = nil
        if !standby { try? audio.listen(false) }
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
        var asked = false
        for action in actions {
            switch action {
            case .say(let text, let interrupted):
                asked = true
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
        // One question: the mic closes once it is on its way, or once the
        // window has passed with nothing said. Her answer needs no ear.
        if askingOnce, asked || talkState == .asleep { stopTalking() }
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
            if let e = word.emotion, !e.isEmpty, !herAsleep {
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


extension ISO8601DateFormatter {
    /// The server's dates carry milliseconds; the plain formatter refuses them.
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
