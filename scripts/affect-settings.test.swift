import Foundation

@main
struct AffectSettingsTests {
    @MainActor static func main() async throws {
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
        // The reported screen: eight Longing episodes crowded out Relief and Interest.
        let repeated = [0.14, 0.12, 0.14, 0.14, 0.14, 0.14, 0.12, 0.14].map {
            AffectSettings.Current.Episode(emotion: "longing", intensity: $0)
        } + [.init(emotion: "interest", intensity: 0.4), .init(emotion: "relief", intensity: 0.5)]
        let screen = AffectSettings.Current(emotion: "sleepy", disposition: "engage", episodes: repeated, mood: nil)
        precondition(screen.displayFeelings.map(\.emotion) == ["relief", "interest", "longing"])
        precondition(screen.displayFeelings.map(\.intensity) == [0.5, 0.4, 0.14], "Repeats inflated feeling intensity")
        precondition(screen.episodes.count == 10, "Display grouping altered the raw episodes")
        precondition(screen.displayFeelings.prefix(3).count == 3 && screen.displayFeelings.count == 3,
                     "Quick menu claimed more feelings just because episodes repeated")
        let tied = repeated + [.init(emotion: "sadness", intensity: 0.4)]
        let more = AffectSettings.Current(emotion: "neutral", disposition: "engage", episodes: tied, mood: nil)
        let reordered = AffectSettings.Current(emotion: "neutral", disposition: "engage", episodes: Array(tied.reversed()), mood: nil)
        precondition(more.displayFeelings.map(\.emotion) == ["relief", "interest", "sadness", "longing"])
        precondition(more.displayFeelings.map(\.emotion) == reordered.displayFeelings.map(\.emotion),
                     "Equal-strength feelings changed order on refresh")
        precondition(Array(more.displayFeelings.prefix(3)).map(\.emotion) == ["relief", "interest", "sadness"])
        precondition(legacy.current.displayFeelings.isEmpty)
        print("Distinct feelings: screenshot duplicates, strongest intensity, top three, stable ties and empty state passed.")
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
        let statusClient = HaruClient(base: URL(string: CommandLine.arguments[1] + "/status-test")!)
        let status = AffectStatus()
        let olderRead = Task { try await status.refresh(client: statusClient) }
        try await Task.sleep(for: .milliseconds(80))
        try await status.refresh(client: statusClient)
        try await olderRead.value
        precondition(status.snapshot?.current.emotion == "worried", "Late status replaced current feelings")
        do {
            try await status.refresh(client: statusClient)
            fatalError("Status failure was swallowed")
        } catch HaruError.server(let code, _) { precondition(code == 503) }
        precondition(status.snapshot == nil && status.problem != nil && !status.loading,
                     "Failed refresh left stale feelings presented as current")
        try await status.refresh(client: statusClient)
        precondition(status.snapshot?.enabled == false && status.snapshot?.current.episodes.isEmpty == true)
        precondition(status.problem == nil && !status.loading, "Retry failed to recover status")
        precondition(initial.current.responseDescription == "Ready to talk")
        precondition(MoodDimension.all.map(\.key) == ["pleasantness", "activation", "tension", "energy", "sleepiness"])
        print("Mood status: out-of-order reads, stale-data clearing, disabled/empty state and retry recovery passed.")
        print("Native affect transport: rich and legacy snapshots, 47 bundled faces, 42 feeling symbols/tints, exact revision-bound save, stale refusal, sign-out and explicit refresh passed.")
    }
}
