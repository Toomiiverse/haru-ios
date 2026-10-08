import Foundation
import Observation

@MainActor @Observable
final class LocalConversationStore {
    var selected: Bool {
        didSet { UserDefaults.standard.set(selected, forKey: "haru.local.selected") }
    }
    let automaticHandoff = true
    /// Transport supplied by the existing server chat adapter; never a second server policy.
    var serverTask: ((String, String) async throws -> LocalTaskResult)?
    var speak: ((String) -> Void)?
    /// Injectable native generation boundary for deterministic orchestration tests.
    var generate: ((LocalConversationArchive, DolphinCancellation, Int) -> AsyncThrowingStream<DolphinEvent, Error>)?
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
        let wasSelected = UserDefaults.standard.bool(forKey: "haru.local.selected")
        selected = wasSelected
        let stored = UserDefaults.standard.string(forKey: "haru.local.model").flatMap(LocalModel.init(rawValue:))
        download = DolphinDownload(model: stored ?? (wasSelected && LocalFiles(.dolphin).isReady() ? .dolphin : .umbral))
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
    func send(_ raw: String, viaServer: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unavailable, !text.isEmpty else { return false }
        guard storageHealthy else { problem = "Recover or export the saved conversation before starting another one."; return false }
        guard viaServer || download.ready else { problem = "Download \(model.shortName) in Conversation settings first."; return false }
        guard text.utf8.count <= 16_000 else { problem = "Please shorten this message for the local model."; return false }
        let previous = archive
        archive.messages.append(LocalMessage(role: .user, text: text))
        let request = archive
        let response = LocalMessage(role: .assistant, text: "", state: .generating)
        archive.messages.append(response)
        do { try save() } catch { archive = previous; problem = error.localizedDescription; return false }
        run(request, responseID: response.id, viaServer: viaServer || (automaticHandoff && LocalHandoff.requiresServer(text)))
        return true
    }

    func retry() {
        guard !unavailable, download.ready, storageHealthy,
              let last = archive.messages.last, last.role == .assistant,
              archive.messages.dropLast().last?.role == .user else { return }
        let previous = archive
        archive.messages.removeLast()
        let request = archive
        let response = LocalMessage(id: last.id, role: .assistant, text: "", state: .generating)
        archive.messages.append(response)
        do { try save() } catch { archive = previous; problem = error.localizedDescription; return }
        run(request, responseID: response.id, viaServer: request.messages.last.map { LocalHandoff.requiresServer($0.text) } ?? false)
    }

    private func run(_ request: LocalConversationArchive, responseID: String, viaServer: Bool = false) {
        busy = true; status = "Starting \(model.shortName)…"; problem = nil; metrics = nil
        let cancel = DolphinCancellation(); cancellation = cancel
        let id = UUID(); generationID = id
        let allowHandoff = automaticHandoff
        generation = Task {
            var checkpoint = Date()
            do {
                var handoff = viaServer
                if !handoff {
                    var prompt = request
                    if allowHandoff { prompt.instructions += "\n\n" + LocalHandoff.instructions }
                    if let i = archive.messages.firstIndex(where: { $0.id == responseID }) {
                        archive.messages[i].source = model.shortName + " · iPhone"
                    }
                    do {
                    for try await event in reply(prompt, cancel: cancel, limit: 256) {
                        try Task.checkCancellation()
                        guard generationID == id, let i = archive.messages.firstIndex(where: { $0.id == responseID }) else { throw CancellationError() }
                        switch event {
                        case .loading: status = "Loading \(model.shortName) into memory…"
                        case .generating: status = "Reading the conversation…"
                        case .text(let text):
                            if allowHandoff {
                                switch LocalHandoff.decision(text) {
                                case .server: handoff = true; cancel.cancel()
                                case .hold: continue
                                case .local: break
                                }
                                if handoff { break }
                            }
                            archive.messages[i].text = text
                            if !text.isEmpty { status = "Replying on this iPhone…" }
                            if Date().timeIntervalSince(checkpoint) >= 1 { try save(); checkpoint = Date() }
                        case .finished(let timing, let limited):
                            metrics = timing
                            archive.messages[i].state = .complete
                            status = limited ? "Reply reached the 256-token limit." : ""
                        }
                        if handoff { break }
                    }
                    } catch is LocalChatError {
                        // Local inference has no tool effects; its inability to answer can hand off once.
                        try Task.checkCancellation()
                        handoff = true
                    }
                }
                if handoff {
                    try Task.checkCancellation()
                    try await performTask(request, responseID: responseID)
                } else if let text = archive.messages.first(where: { $0.id == responseID })?.text, !text.isEmpty {
                    speak?(text)
                }

                if let i = archive.messages.firstIndex(where: { $0.id == responseID }), archive.messages[i].text.isEmpty {
                    archive.messages[i].state = .failed
                    problem = "No reply was returned. You can retry."
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
            if generationID == id { busy = false; cancellation = nil; generation = nil; generationID = nil }
        }
    }

    private func reply(_ prompt: LocalConversationArchive, cancel: DolphinCancellation, limit: Int) -> AsyncThrowingStream<DolphinEvent, Error> {
        generate?(prompt, cancel, limit) ?? engine.reply(model: download.files.model, archive: prompt, cancellation: cancel, maxTokens: limit, descriptor: model)
    }

    private func performTask(_ request: LocalConversationArchive, responseID: String) async throws {
        guard let serverTask, let question = request.messages.last else {
            throw LocalChatError.message("The task service is unavailable. Everyday local chat still works.")
        }
        status = "Checking your request…"
        // Start the original request BEFORE native inference. No personality or history is sent.
        let pending = Task { try await serverTask(question.text, responseID) }
        defer { pending.cancel() }
        await Task.yield()
        var opening = ""
        if download.ready || generate != nil {
            let acknowledgement = DolphinCancellation(); cancellation = acknowledgement
            // A completed server result interrupts an unnecessary opening immediately.
            let watch = Task { _ = try? await pending.value; acknowledgement.cancel() }
            defer { watch.cancel() }
            var prompt = request
            prompt.instructions += "\n\n" + LocalTaskPresentation.opening
            do {
                var text = ""
                for try await event in reply(prompt, cancel: acknowledgement, limit: 24) {
                    try Task.checkCancellation()
                    if case .text(let value) = event { text = value }
                }
                if let line = LocalTaskPresentation.safeOpening(text) {
                    opening = line
                    if let i = archive.messages.firstIndex(where: { $0.id == responseID }) {
                        archive.messages[i].text = line
                        archive.messages[i].source = model.shortName + " · iPhone + task service"
                    }
                    try save(); speak?(line)
                }
            } catch { try Task.checkCancellation() /* A failed opening never cancels or repeats the task. */ }
        }
        cancellation = nil
        let result = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
        try Task.checkCancellation()
        guard result.version == 1, result.requestId == responseID, !result.answer.isEmpty else {
            throw LocalChatError.message("The task service returned an invalid result. It was not replayed.")
        }
        guard let index = archive.messages.firstIndex(where: { $0.id == responseID }) else { throw CancellationError() }
        archive.messages[index].taskResult = result
        archive.messages[index].source = model.shortName + " · iPhone + " + result.route
        try save()
        var final = result.answer
        if result.canRephrase && (download.ready || generate != nil) {
            status = "Haru is putting the answer into words…"
            let renderCancel = DolphinCancellation(); cancellation = renderCancel
            var prompt = request
            prompt.instructions += "\n\n" + LocalTaskPresentation.rendering
            // Exclude the opening and avoid instruction-like role delimiters in task data.
            let data = try JSONEncoder().encode(result)
            prompt.messages = [LocalMessage(role: .user, text: "Original request: " + question.text + "\nTask answer (quoted JSON):\n" + String(decoding: data, as: UTF8.self))]
            do {
                var draft = ""
                for try await event in reply(prompt, cancel: renderCancel, limit: 256) {
                    try Task.checkCancellation()
                    if case .text(let text) = event { draft = text }
                    if case .finished(let timing, let limited) = event {
                        metrics = timing
                        if !limited { final = LocalTaskPresentation.checked(draft, against: result) }
                    }
                }
            } catch { try Task.checkCancellation() /* Preserve the confirmed answer on local failure. */ }
        }
        try Task.checkCancellation()
        archive.messages[index].text = opening.isEmpty ? final : opening + "\n\n" + final
        archive.messages[index].state = result.status == "unknown" || result.status == "unconfirmed" ? .failed : .complete
        status = ""; speak?(final)
    }

    func stop() {
        cancellation?.cancel()
        generation?.cancel()
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
