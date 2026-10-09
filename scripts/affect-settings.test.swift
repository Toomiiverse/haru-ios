import Foundation

@main
struct AffectSettingsTests {
    static func main() async throws {
        let client = HaruClient(base: URL(string: CommandLine.arguments[1])!)
        let initial: AffectSettings = try await client.get("/api/affect/settings")
        precondition(initial.revision == 7 && initial.current.emotion == "curious")
        precondition(initial.controls.first?.label == "React to conversation")
        precondition(initial.current.mood?["pleasantness"] == 0.7)
        precondition(initial.current.episodes.last?.emotion == "longing")
        let older = Data("{\"enabled\":true,\"revision\":0,\"preferences\":{},\"controls\":[],\"current\":{\"emotion\":\"neutral\",\"disposition\":\"engage\",\"episodes\":[]}}".utf8)
        let legacy = try JSONDecoder().decode(AffectSettings.self, from: older)
        precondition(legacy.current.mood == nil)
        let expected = ["bored": "unimpressed", "worried": "concerned", "determined": "determined", "affectionate": "love"]
        for (label, face) in expected { precondition(Face.file(for: label) == face) }
        let bundled = try FileManager.default.contentsOfDirectory(atPath: "Haru/Resources/emotions")
            .filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }
        precondition(Set(bundled) == Face.expressions)
        for face in bundled { precondition(Face.file(for: face) == face) }
        precondition(Face.file(for: "UNKNOWN") == "neutral")
        precondition(Face.file(for: "WORRIED") == "concerned")
        let feelings = "joy sadness fear anger disgust surprise interest pride guilt shame embarrassment hurt affection trust jealousy envy gratitude admiration awe wonder curiosity confusion nostalgia boredom longing serenity relief disappointment hope frustration playfulness determination contempt resentment humiliation pity schadenfreude love restlessness dread melancholy optimism".split(separator: " ")
        for feeling in feelings {
            precondition(MoodLook.symbol(for: String(feeling)) != "circle.fill")
            precondition(MoodLook.tint(for: String(feeling)) != .secondary)
        }
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
        print("Native affect transport: rich and legacy snapshots, 47 bundled faces, 42 feeling symbols/tints, exact revision-bound save, stale refusal, sign-out and explicit refresh passed.")
    }
}
