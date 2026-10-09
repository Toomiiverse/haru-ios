import Foundation

@main struct RetiredModelCleanupTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "haru.cleanup.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "haru.local.selected")
        defaults.set("umbral", forKey: "haru.local.model")
        defaults.set(true, forKey: "speech.enabled")
        try RetiredModelCleanup.run(directory: root, defaults: defaults)
        precondition(defaults.object(forKey: "haru.local.selected") == nil)
        precondition(defaults.object(forKey: "haru.local.model") == nil)
        precondition(defaults.bool(forKey: "speech.enabled"))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let retained = Data("private conversation and personality notes".utf8)
        for name in ["conversation.json", "unrelated.json"] {
            try retained.write(to: root.appendingPathComponent(name))
        }
        for name in ["L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf",
                     "dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf", "incoming-test",
                     "model-verified.json", "umbral-model-verified.json",
                     "download.resume", "umbral-download.resume",
                     "download-progress.json", "umbral-download-progress.json"] {
            try Data("retired weights or download".utf8).write(to: root.appendingPathComponent(name))
        }
        try RetiredModelCleanup.run(directory: root, defaults: defaults)
        try RetiredModelCleanup.run(directory: root, defaults: defaults)
        let files = try fm.contentsOfDirectory(atPath: root.path)
        let transcript = try Data(contentsOf: root.appendingPathComponent("conversation.json"))
        precondition(Set(files) == ["conversation.json", "unrelated.json"])
        precondition(transcript == retained)
        print("Retired model cleanup passed: absent directory, preferences, both models, partial downloads, history preservation, repeated launch")
    }
}
