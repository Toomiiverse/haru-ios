import Foundation

@main
struct AffectSettingsTests {
    static func main() async throws {
        let client = HaruClient(base: URL(string: CommandLine.arguments[1])!)
        let initial: AffectSettings = try await client.get("/api/affect/settings")
        precondition(initial.revision == 7 && initial.current.emotion == "curious")
        precondition(initial.controls.first?.label == "React to conversation")
        let command = AffectSettingsSave(expectedRevision: initial.revision,
                                        preferences: ["reactToConversation": false, "allowDecline": true])
        let saved = try await client.saveAffectSettings(command)
        precondition(saved.revision == 8 && saved.preferences["reactToConversation"] == false)
        do {
            _ = try await client.saveAffectSettings(command)
            fatalError("Stale save was accepted")
        } catch HaruError.server(let status, _) { precondition(status == 409) }
        do {
            _ = try await client.saveAffectSettings(AffectSettingsSave(expectedRevision: 8, preferences: saved.preferences))
            fatalError("Signed-out save was accepted")
        } catch HaruError.signedOut { }
        let refreshed: AffectSettings = try await client.get("/api/affect/settings")
        precondition(refreshed.revision == 8)
        print("Native affect transport: decode, exact revision-bound save, stale refusal, sign-out and explicit refresh passed.")
    }
}
