import Foundation

/// Retire the downloaded conversation engines without deleting the user's transcript.
enum RetiredModelCleanup {
    static func run(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                              in: .userDomainMask)[0]
        .appendingPathComponent("LocalConversation", isDirectory: true),
                    defaults: UserDefaults = .standard) throws {
        defaults.removeObject(forKey: "haru.local.selected")
        defaults.removeObject(forKey: "haru.local.model")
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let retired: Set<String> = [
            "L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf",
            "dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf",
            "model-verified.json", "umbral-model-verified.json",
            "download.resume", "umbral-download.resume",
            "download-progress.json", "umbral-download-progress.json"
        ]
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where retired.contains(file.lastPathComponent) || file.lastPathComponent.hasPrefix("incoming-") {
            try fm.removeItem(at: file)
        }
        // No completion flag: a protected or busy file is retried on the next launch.
        // conversation.json holds personal notes and history and deliberately stays on disk.
    }
}
