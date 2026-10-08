import Foundation
import Observation

@MainActor @Observable
final class LocalConversationStore {
    var selected: Bool {
        didSet { UserDefaults.standard.set(selected, forKey: "haru.local.selected") }
    }
    private(set) var archive = LocalConversationArchive()
    private(set) var download: DolphinDownload
    var model: LocalModel { download.model }
    func chooseModel(_ model: LocalModel) async {
        guard !unavailable, !download.working, model != self.model else { return }
        releasing = true
        defer { releasing = false }
        await engine.unload()
        download = DolphinDownload(model: model)
        UserDefaults.standard.set(model.rawValue, forKey: "haru.local.model")
        metrics = nil; status = ""; problem = nil
        // Keep the local route selected: an unavailable model must never fall back to the server.
    }
    private(set) var busy = false
    private(set) var releasing = false
    var unavailable: Bool { busy || releasing }
    private(set) var status = ""
    private(set) var metrics: LocalReplyMetrics?
    var problem: String?
    private let engine = DolphinEngine()
    private var cancellation: DolphinCancellation?
    private var generation: Task<Void, Never>?
    private var generationID: UUID?
    private var storageHealthy = true

    init() {
        selected = UserDefaults.standard.bool(forKey: "haru.local.selected")
        let stored = UserDefaults.standard.string(forKey: "haru.local.model").flatMap(LocalModel.init(rawValue:))
        download = DolphinDownload(model: stored ?? (selected && LocalFiles(.dolphin).isReady() ? .dolphin : .umbral))
        do {
            try LocalFiles.prepare()
            if FileManager.default.fileExists(atPath: LocalFiles.conversation.path) {
                archive = try JSONDecoder().decode(LocalConversationArchive.self, from: Data(contentsOf: LocalFiles.conversation))
                guard archive.version == 1 else { throw LocalChatError.message("This saved local conversation belongs to a newer Haru version.") }
                archive.recover()
            }
            try save()
        } catch {
            storageHealthy = false
            problem = "The saved local conversation could not be opened. It has been kept on disk. " + error.localizedDescription
        }
    }

    func copyConversation(_ messages: [LocalMessage]) {
        guard !unavailable, storageHealthy else { return }
        let previous = archive
        let known = Set(archive.messages.map(\.id))
        var i = 0
        while i + 1 < messages.count {
            let user = messages[i], reply = messages[i + 1]
            if user.role == .user && reply.role == .assistant && !user.text.isEmpty && !reply.text.isEmpty
                && user.state == .complete && reply.state == .complete {
                if !known.contains(user.id) && !known.contains(reply.id) { archive.messages += [user, reply] }
                i += 2
            } else { i += 1 }
        }
        do { try save(); problem = nil } catch { archive = previous; problem = error.localizedDescription }
    }

    func updateSettings(instructions: String, notes: String, contextSize: Int) {
        guard !unavailable, storageHealthy else { problem = "Local settings cannot be saved while the conversation is busy or its file needs recovery."; return }
        let previous = archive
        archive.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if archive.instructions.isEmpty { archive.instructions = DolphinModel.defaultInstructions }
        archive.notes = notes
        archive.contextSize = contextSize == 2048 ? 2048 : 1024
        do { try save() } catch { archive = previous; problem = error.localizedDescription }
    }

    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unavailable, !text.isEmpty else { return false }
        guard storageHealthy else { problem = "Recover or export the saved conversation before starting another one."; return false }
        guard download.ready else { problem = "Download \(model.shortName) in Conversation settings first."; return false }
        guard text.utf8.count <= 16_000 else { problem = "Please shorten this message for the local model."; return false }
        let previous = archive
        archive.messages.append(LocalMessage(role: .user, text: text))
        let request = archive
        let response = LocalMessage(role: .assistant, text: "", state: .generating)
        archive.messages.append(response)
        do { try save() } catch { archive = previous; problem = error.localizedDescription; return false }
        run(request, responseID: response.id)
        return true
    }

    func retry() {
        guard !unavailable, download.ready, storageHealthy,
              let last = archive.messages.last, last.role == .assistant,
              archive.messages.dropLast().last?.role == .user else { return }
        let previous = archive
        archive.messages.removeLast()
        let request = archive
        let response = LocalMessage(role: .assistant, text: "", state: .generating)
        archive.messages.append(response)
        do { try save() } catch { archive = previous; problem = error.localizedDescription; return }
        run(request, responseID: response.id)
    }

    private func run(_ request: LocalConversationArchive, responseID: String) {
        busy = true; status = "Starting \(model.shortName)…"; problem = nil; metrics = nil
        let cancel = DolphinCancellation(); cancellation = cancel
        let id = UUID(); generationID = id
        generation = Task {
            var checkpoint = Date()
            do {
                for try await event in engine.reply(model: download.files.model, archive: request, cancellation: cancel, descriptor: model) {
                    guard generationID == id, let i = archive.messages.firstIndex(where: { $0.id == responseID }) else { break }
                    switch event {
                    case .loading: status = "Loading \(model.shortName) into memory…"
                    case .generating: status = "Reading the conversation…"
                    case .text(let text):
                        archive.messages[i].text = text
                        if !text.isEmpty { status = "Replying on this iPhone…" }
                        if Date().timeIntervalSince(checkpoint) >= 1 {
                            try save(); checkpoint = Date()
                        }
                    case .finished(let timing, let limited):
                        metrics = timing
                        archive.messages[i].state = .complete
                        status = limited ? "Reply reached the 256-token limit." : ""
                    }
                }
                if let i = archive.messages.firstIndex(where: { $0.id == responseID }), archive.messages[i].text.isEmpty {
                    archive.messages[i].state = .failed
                    problem = "\(model.shortName) returned an empty reply. You can retry."
                }
            } catch {
                cancel.cancel()
                if let i = archive.messages.firstIndex(where: { $0.id == responseID }) {
                    archive.messages[i].state = error is CancellationError ? .interrupted : .failed
                }
                if error is CancellationError { status = "Stopped. The partial reply is saved." }
                else { problem = error.localizedDescription; status = "" }
            }
            do { try save() } catch { problem = "The last reply could not be saved: " + error.localizedDescription }
            if generationID == id {
                busy = false; cancellation = nil; generation = nil; generationID = nil
            }
        }
    }

    func stop() {
        cancellation?.cancel()
        if busy { status = "Stopping…" }
    }

    func releaseMemory() async {
        guard !releasing else { return }
        releasing = true
        defer { releasing = false }
        stop()
        await generation?.value
        await engine.unload()
    }

    func removeModel() async {
        guard !unavailable, !download.working else { return }
        releasing = true
        defer { releasing = false }
        await engine.unload()
        do { try download.remove() } catch { problem = error.localizedDescription }
    }

    func clearConversation() {
        guard !unavailable else { return }
        if !storageHealthy {
            do {
                let backup = LocalFiles.directory.appendingPathComponent("conversation-recovery-" + UUID().uuidString + ".json")
                if FileManager.default.fileExists(atPath: LocalFiles.conversation.path) {
                    try FileManager.default.copyItem(at: LocalFiles.conversation, to: backup)
                }
                archive = LocalConversationArchive()
                try save(); storageHealthy = true; problem = nil; metrics = nil; status = ""
            } catch { problem = error.localizedDescription }
            return
        }
        let previous = archive
        archive.messages = []
        do { try save(); metrics = nil; status = "" }
        catch { archive = previous; problem = error.localizedDescription }
    }

    private func save() throws {
        try JSONEncoder().encode(archive).write(to: LocalFiles.conversation, options: .atomic)
    }
}
