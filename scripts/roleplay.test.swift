import Foundation

actor CharacterTestServer {
    var sent = 0
    var receipts = 0
    var saves = 0
    var profile: [String: Any]?
    let state = #"{"mode":"character","revision":1,"character":{"slug":"batman","name":"Batman","description":"Detective","photoUrl":"","shareUrl":"","tags":[],"adult":false,"catalogModel":"other-model","model":"venice-uncensored-1-2"},"sceneId":"scene","messages":[],"pendingRequestId":null,"error":null,"model":"venice-uncensored-1-2"}"#
    func call(_ body: [String: JSONValue]) throws -> Data {
        let op = body["op"]?.stringValue ?? ""
        if op == "custom-save" {
            saves += 1
            profile = ["slug":"custom_test","name":body["name"]!.stringValue!,"description":body["description"]!.stringValue!,"instructions":body["instructions"]!.stringValue!,"background":body["background"]!.stringValue!,"profileId":body["profileId"]!.stringValue!.lowercased(),"profileRevision":1,"custom":true,"photoUrl":"","shareUrl":"","tags":[],"adult":false,"catalogModel":"venice-uncensored-1-2","model":"venice-uncensored-1-2"]
            throw URLError(.networkConnectionLost)
        }
        if op == "custom-list" {
            return try JSONSerialization.data(withJSONObject: ["characters":profile.map { [$0] } ?? [],"offset":0,"hasMore":false,"model":"venice-uncensored-1-2"])
        }
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
        precondition(store.state?.character?.slug == "batman")
        let accepted = await store.send("Begin the scene.", client)
        precondition(accepted, "An uncertain accepted reply must remain associated with its original request.")
        let sent = await server.sent
        let receipts = await server.receipts
        precondition(sent == 1, "A dropped POST must never resend the message.")
        precondition(receipts >= 1, "The original receipt must be checked.")
        precondition(!store.waiting, "Terminal unknown should permit the user to start a new turn.")
        precondition(store.problem == "Unconfirmed; not resent.")
        let profileId = UUID().uuidString
        let saved = await store.saveProfile(id: profileId, revision: 0, name: "Mira", description: "Navigator", instructions: "Speak warmly", background: "Starship Dawn", client: client)
        precondition(saved?.profileId == profileId.lowercased(), "A lost save must recover the persisted original profile.")
        precondition(store.myCharacters.count == 1)
        let saves = await server.saves
        precondition(saves == 1, "An uncertain save must not automatically post again.")
        precondition(!store.savingProfile)
        print("Custom character save recovery passed; one save and no automatic resend.")
        print("Roleplay receipt recovery passed; no automatic resend.")
    }
}
