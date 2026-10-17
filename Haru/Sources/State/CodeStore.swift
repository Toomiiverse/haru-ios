import Foundation
import Observation

/// Coding mode: his own session with the OpenCode coder on the server (/api/code/*), Codex / Claude
/// Code-style. Nothing here goes through Haru's chat or into her memory; leaving tells her once.
@MainActor @Observable
final class CodeStore {
    var items: [CodeItem] = []
    var folder: String?
    var model = ""
    var models: [CodeModel] = []
    var projects: [String] = []
    var running = false
    var spent: CodeSpent?
    var tokens = 0
    var problem: String?
    var diff: CodeDiff?
    var busy = false
    /// Set by /exit; ConversationView switches back to her.
    var exitRequested = false
    /// A folder named with /code <folder> before the screen opened.
    var pendingFolder: String?
    private var streamTask: Task<Void, Never>?

    var modelName: String { models.first { $0.id == model }?.name ?? "Model" }

    func open(_ client: HaruClient) async {
        exitRequested = false
        if let folder = pendingFolder, !folder.isEmpty {
            pendingFolder = nil
            await start(folder, client)
            return
        }
        pendingFolder = nil
        do { apply(try await client.get("/api/code/state") as CodeFrame) } catch { problem = error.localizedDescription }
        if folder != nil { listen(client) }
    }

    func close() { streamTask?.cancel(); streamTask = nil }

    /// The live stream: the whole state first, then each change. Dropped streams reconnect while the screen is open.
    func listen(_ client: HaruClient) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do { for try await frame in client.codeEvents() { self?.apply(frame) } } catch {}
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func apply(_ f: CodeFrame) {
        switch f.kind ?? "state" {
        case "state":
            folder = f.folder; model = f.model ?? model; models = f.models ?? models; projects = f.projects ?? projects
            items = f.items ?? []; running = f.running ?? false; spent = f.spent
        case "run":
            running = f.running ?? false
            if let e = f.error { items.append(CodeItem(kind: "error", id: UUID().uuidString, text: e)) }
            if !running { Task { await self.refreshSpend() } }
        case "usage": tokens = f.tokens ?? tokens
        case let kind:
            guard let id = f.id else { return }
            if let at = items.firstIndex(where: { $0.kind == kind && $0.id == id }) { items[at].merge(f) }
            else { var item = CodeItem(kind: kind, id: id); item.merge(f); items.append(item) }
        }
    }

    private var client: HaruClient?
    private func refreshSpend() async {
        guard let client, let state: CodeFrame = try? await client.get("/api/code/state") else { return }
        spent = state.spent
    }

    func start(_ folder: String, _ client: HaruClient) async {
        self.client = client
        await call(client) {
            let state: CodeFrame = try await client.post("/api/code/session", ["folder": .string(folder), "model": .string(self.model)])
            self.apply(state)
            self.listen(client)
        }
    }

    /// What he typed: a slash command, or words for the coder.
    func send(_ text: String, _ client: HaruClient) async -> Bool {
        self.client = client
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let word = t.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let rest = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        switch word {
        case "/exit": exitRequested = true; return true
        case "/stop": await stop(client); return true
        case "/diff": await loadDiff(client); return true
        case "/new": await start(folder ?? "", client); return true   // no project yet: a quick session
        case "/cd", "/code": await start(rest, client); return true   // no folder named: a quick session
        case "/model":
            let wanted = rest.lowercased()
            if let m = models.first(where: { $0.name.lowercased().contains(wanted) || $0.id.lowercased().contains(wanted) }), !wanted.isEmpty { await setModel(m.id, client) }
            else { problem = "Models: " + models.map(\.name).joined(separator: ", ") }
            return true
        default: break
        }
        guard folder != nil else { problem = "Pick a project folder first."; return false }
        // !command: his own terminal line in the project folder; its card arrives on the stream.
        if let command = terminalCommand(t) {
            guard !command.isEmpty else { problem = "Type a command after the !."; return false }
            return await call(client) { let _: CodeOK = try await client.post("/api/code/shell", ["command": .string(command)]) }
        }
        items.append(CodeItem(kind: "you", id: "local-" + UUID().uuidString, text: t))
        running = true
        let sent = await call(client) { let _: CodeOK = try await client.post("/api/code/prompt", ["text": .string(t)]) }
        if !sent { items.removeLast(); running = false }
        return sent
    }

    func answer(_ id: String, _ decision: String, _ client: HaruClient) async {
        await call(client) { let _: CodeOK = try await client.post("/api/code/permission", ["id": .string(id), "decision": .string(decision)]) }
    }

    func stop(_ client: HaruClient) async {
        await call(client) { let _: CodeOK = try await client.post("/api/code/stop") }
    }

    func setModel(_ id: String, _ client: HaruClient) async {
        await call(client) { let _: CodeOK = try await client.post("/api/code/model", ["model": .string(id)]); self.model = id }
    }

    func loadDiff(_ client: HaruClient) async {
        await call(client) { let diff: CodeDiff = try await client.get("/api/code/diff"); self.diff = diff }
    }

    /// Back to her: the stream closes, and she is told once what was worked on.
    func leave(_ client: HaruClient) async {
        close()
        let _: CodeOK? = try? await client.post("/api/code/leave")
    }

    @discardableResult
    private func call(_ client: HaruClient, _ work: @escaping () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do { try await work(); return true } catch { problem = error.localizedDescription; return false }
    }
}
