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

    let session: Session
    let voice = Voice()
    let stage = Stage()
    private var lastAskedAt = Date.distantPast

    init(session: Session) {
        self.session = session
        voice.onLevel = { [weak self] level in self?.stage.mouth(level) }
    }

    private var client: HaruClient { session.client }

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
        let interrupted = voice.stop() || spokeOver

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
        voice.stop()
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
        do {
            for try await event in stream {
                if let error = event.error {
                    failure = error
                } else if event.text == "\u{FFFD}" {
                    // The round was thrown away; back to waiting.
                    said = ""
                    paint(id, "", waiting: true)
                } else if let chunk = event.text, !chunk.isEmpty {
                    if !begun {
                        // The thinking is over, whatever the mood turns out to be.
                        begun = true
                        stage.attend("talking", ms: 2_500)
                    }
                    said += chunk
                    paint(id, said, waiting: false)
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
            return
        }
        let final = (reply ?? said).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            entries[i] = Entry(id: id, kind: .system, text: ignored ? "Seen. She is not answering that." : "She had nothing to say.")
            return
        }
        entries[i].text = final
        entries[i].waiting = false
        // Her face and voice cost round trips of their own; the composer does
        // not wait for them.
        Task { await react(to: final) }
        // The reply's id — what a thumb or a retry needs — only exists on the
        // server. A quiet reload picks it up, and anything she added since.
        await load()
    }

    private func paint(_ id: String, _ text: String, waiting: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].text = text
        entries[i].waiting = waiting
    }

    /// What her face does and how she sounds saying a line — asked for after the
    /// words are on screen, the way the phone page does it.
    func react(to line: String) async {
        let mood: Expression? = try? await client.post("/api/expression", ["text": .string(line)])
        if let e = mood?.emotion, !e.isEmpty { emotion = e }
        // The server picks the Live2D expression, because only it knows what
        // this model carries; nil lets her face rest.
        stage.express(mood?.expression)
        await speak(line, emotion: mood?.emotion)
    }

    func speak(_ text: String, emotion: String?) async {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let emotion { body["emotion"] = .string(emotion) }
        // 503 when her voice is switched off for the web: the right amount of fuss is none.
        guard let audio = try? await client.bytes("/api/speak", post: body) else { return }
        voice.play(audio)
        // Looking at them for as long as the line runs.
        stage.attend("talking", ms: Int(voice.remaining * 1000) + 500)
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

    // MARK: Files and the microphone

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

    /// A WAV recording to words, through her ears on the server.
    func transcribe(_ wav: Data) async -> String? {
        transcribing = true
        defer { transcribing = false }
        do {
            let heard: Heard = try await client.upload("/api/listen", data: wav, type: "audio/wav")
            return heard.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }
}
