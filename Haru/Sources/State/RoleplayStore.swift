import Foundation
import Observation

/// Presentation and durable receipt polling. Core owns mode and scene state.
@MainActor @Observable
final class RoleplayStore {
    private let sessionId: String
    var state: RoleplayState?
    var characters: [VeniceCharacter] = []
    var problem: String?
    var changing = false
    var loadingCatalog = false
    var hasMore = false
    private var offset = 0
    private var search = ""
    private var poller: Task<Void, Never>?
    private var unconfirmedId: String?
    var waiting: Bool { changing || state?.pendingRequestId != nil || unconfirmedId != nil }

    init(defaults: UserDefaults = .standard) {
        let key = "haru.character.session"
        let saved = defaults.string(forKey: key)
        sessionId = saved.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        defaults.set(sessionId, forKey: key)
    }
    private func body(_ op: String, _ fields: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var result = fields
        result["op"] = .string(op)
        result["sessionId"] = .string(sessionId)
        return result
    }
    func load(_ client: HaruClient) async {
        do {
            state = try await client.post("/api/roleplay", body("state"))
            if let id = state?.pendingRequestId ?? unconfirmedId { startPolling(id, client) }
        } catch { problem = error.localizedDescription }
    }
    func catalog(_ client: HaruClient, search: String, more: Bool = false) async {
        guard !loadingCatalog else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let result: CharacterCatalog = try await client.post("/api/roleplay", body("catalog", [
                "search": .string(search), "offset": .number(Double(more ? offset : 0)),
            ]))
            self.search = search
            characters = more ? characters + result.characters : result.characters
            offset = result.offset + result.characters.count
            hasMore = result.hasMore
        } catch { problem = error.localizedDescription }
    }
    func more(_ client: HaruClient) async { await catalog(client, search: search, more: true) }
    func select(_ character: VeniceCharacter, _ client: HaruClient) async -> Bool {
        await change("select", ["slug": .string(character.slug)], client)
    }
    func mode(_ mode: String, _ client: HaruClient) async -> Bool {
        await change("mode", ["mode": .string(mode)], client)
    }
    func newScene(_ client: HaruClient) async { _ = await change("new-scene", [:], client) }
    private func change(_ op: String, _ fields: [String: JSONValue], _ client: HaruClient) async -> Bool {
        guard !waiting, let current = state else { return false }
        changing = true
        defer { changing = false }
        do {
            var fields = fields
            fields["revision"] = .number(Double(current.revision))
            state = try await client.post("/api/roleplay", body(op, fields))
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            await load(client)
            return false
        }
    }
    /// An uncertain POST is checked by its original ID and never resent.
    func send(_ text: String, _ client: HaruClient) async -> Bool {
        guard !waiting, let current = state, current.mode == "character", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        changing = true
        defer { changing = false }
        let id = UUID().uuidString
        unconfirmedId = id
        do {
            let receipt: RoleplayReceipt = try await client.post("/api/roleplay", body("send", [
                "text": .string(text), "requestId": .string(id), "revision": .number(Double(current.revision)),
            ]))
            await load(client)
            handle(receipt, client)
            return receipt.status != "missing"
        } catch {
            do {
                let receipt: RoleplayReceipt = try await client.post("/api/roleplay", body("receipt", ["requestId": .string(id)]))
                handle(receipt, client)
                await load(client)
                if receipt.status != "missing" { return true }
            } catch { startPolling(id, client) }
            problem = "Delivery could not be confirmed. Check the existing reply before sending again."
            return false
        }
    }
    private func handle(_ receipt: RoleplayReceipt, _ client: HaruClient) {
        if receipt.status == "pending" { startPolling(receipt.requestId, client) }
        else {
            unconfirmedId = nil
            if let error = receipt.error { problem = error }
        }
    }
    private func startPolling(_ id: String, _ client: HaruClient) {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            guard let self else { return }
            defer { self.poller = nil }
            for _ in 0..<150 {
                do {
                    let receipt: RoleplayReceipt = try await client.post("/api/roleplay", self.body("receipt", ["requestId": .string(id)]))
                    if receipt.status != "pending" {
                        self.unconfirmedId = nil
                        self.state = try await client.post("/api/roleplay", self.body("state"))
                        if let error = receipt.error { self.problem = error }
                        return
                    }
                    try await Task.sleep(for: .seconds(1.5))
                } catch {
                    self.problem = "Reply status is unreachable. Your message will not be resent."
                    return
                }
            }
            self.problem = "The reply is still unconfirmed. Refresh to check its original request."
        }
    }
}
