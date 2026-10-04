import Foundation

actor CharacterTestServer {
    var sent = 0
    var receipts = 0
    var saves = 0
    var regenerations = 0
    var sessionSaves = 0
    var savedSession: [String: Any]?
    var regenerationTarget: String?
    var profile: [String: Any]?
    let state = #"{"mode":"character","revision":1,"character":{"slug":"custom_test","name":"Batman","description":"Detective","photoUrl":"","shareUrl":"","tags":[],"adult":false,"catalogModel":"other-model","model":"venice-uncensored-1-2"},"sceneId":"scene","messages":[],"pendingRequestId":null,"error":null,"model":"venice-uncensored-1-2"}"#
    func call(_ body: [String: JSONValue]) throws -> Data {
        let op = body["op"]?.stringValue ?? ""
        if op == "custom-save" {
            saves += 1
            profile = ["slug":"custom_test","name":body["name"]!.stringValue!,"description":body["description"]!.stringValue!,"instructions":body["instructions"]!.stringValue!,"background":body["background"]!.stringValue!,"profileId":body["profileId"]!.stringValue!.lowercased(),"profileRevision":1,"custom":true,"photoUrl":"","shareUrl":"","tags":[],"adult":false,"catalogModel":"venice-uncensored-1-2","model":"venice-uncensored-1-2"]
            if let creator = body["creator"] { profile?["creator"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(creator)) }
            throw URLError(.networkConnectionLost)
        }
        if op == "custom-list" {
            return try JSONSerialization.data(withJSONObject: ["characters":profile.map { [$0] } ?? [],"offset":0,"hasMore":false,"model":"venice-uncensored-1-2"])
        }
        if op == "session-save" {
            sessionSaves += 1
            savedSession = ["id":body["savedSessionId"]!.stringValue!.lowercased(), "revision":1, "label":body["label"]!.stringValue!, "characterName":"Mira", "model":"venice-uncensored-1-2", "messageCount":2, "savedAt":0]
            throw URLError(.networkConnectionLost)
        }
        if op == "session-list" { return try JSONSerialization.data(withJSONObject:["sessions":savedSession.map { [$0] } ?? []]) }
        if op == "regenerate" { regenerations += 1; regenerationTarget = body["messageId"]?.stringValue; throw URLError(.networkConnectionLost) }
        if op == "send" { sent += 1; throw URLError(.networkConnectionLost) }
        if op == "receipt" {
            receipts += 1
            return Data(#"{"requestId":"original","status":"unknown","reply":null,"error":"Unconfirmed; not resent.","sceneId":"scene"}"#.utf8)
        }
        return Data(state.utf8)
    }
}
struct HaruClient: Sendable {
    let server: CharacterTestServer
    func post<T: Decodable>(_ path: String, _ body: [String: JSONValue]) async throws -> T {
        try JSONDecoder().decode(T.self, from: await server.call(body))
    }
}
@main struct RoleplayTests {
    @MainActor static func main() async throws {
        let name = "haru-roleplay-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = RoleplayStore(defaults: defaults)
        let server = CharacterTestServer()
        let client = HaruClient(server: server)
        await store.load(client)
        precondition(store.state?.character?.slug == "custom_test")
        let accepted = await store.send("Begin the scene.", client)
        precondition(accepted, "An uncertain accepted reply must remain associated with its original request.")
        let sent = await server.sent
        let receipts = await server.receipts
        precondition(sent == 1, "A dropped POST must never resend the message.")
        precondition(receipts >= 1, "The original receipt must be checked.")
        precondition(!store.waiting, "Terminal unknown should permit the user to start a new turn.")
        precondition(store.problem == "Unconfirmed; not resent.")
        let regenerated = await store.regenerate("existing:assistant", client)
        precondition(regenerated)
        let regenerationCount = await server.regenerations
        let regenerationTarget = await server.regenerationTarget
        precondition(regenerationCount == 1 && regenerationTarget == "existing:assistant", "Lost regeneration response must check its receipt, not send a second generation.")
        let savedSessionId = UUID().uuidString
        let sessionSaved = await store.saveSession(id: savedSessionId, label: "Voyage", client)
        let sessionSaveCount = await server.sessionSaves
        precondition(sessionSaved && sessionSaveCount == 1, "Lost snapshot save must recover the original UUID without saving twice.")
        precondition(store.savedSessions.first?.id == savedSessionId.lowercased())
        let profileId = UUID().uuidString
        var creator = CreatorFields()
        creator.model = "zai-org-glm-5-1"
        creator.intro = "Welcome aboard."
        creator.documents = [CreatorDocument(name: "lore.md", text: "The Dawn orbits a blue moon.")]
        creator.insightsEnabled = true
        creator.insights = ["relationship": ["tone": "Warm and playful"]]
        let saved = await store.saveProfile(id: profileId, revision: 0, name: "Mira", description: "Navigator", instructions: "Speak warmly", background: "Starship Dawn", creator: creator, client: client)
        precondition(saved?.profileId == profileId.lowercased(), "A lost save must recover the persisted original profile.")
        precondition(store.myCharacters.count == 1)
        precondition(saved?.creator == creator, "Lost save recovery must preserve model, documents and insights.")
        let saves = await server.saves
        precondition(saves == 1, "An uncertain save must not automatically post again.")
        precondition(!store.savingProfile)
        print("Custom character save recovery passed; one save and no automatic resend.")
        print("Roleplay receipt recovery passed; no automatic resend.")
        print("Regeneration and saved-session lost-response recovery passed.")
    }
}
