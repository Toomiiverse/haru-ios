import ActivityKit
import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

/// "Wake me up", as an alarm: iOS 26's AlarmKit rings through silent mode and
/// any Focus, full screen, like the Clock app's own — a push cannot. It rings
/// every day at the "Up by" hour under More, in her voice when the server
/// gives a line as a WAV (kept in Library/Sounds, where iOS looks for alarm
/// sounds), and with the system's alarm sound otherwise. The alarm lives on
/// the phone: it rings whether or not the server can be reached.
@MainActor
enum WakeAlarm {
    private static let idKey = "alarm.id"
    private static let onKey = "alarm.on"
    private static let timeKey = "alarm.time"
    private static let soundName = "haru-wake.wav"
    /// What she says, over and over, until "I'm up". His to reword.
    static let line = "Hey. Wake up. It's morning, and I'm not going to stop until you're up."

    static var supported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static var on: Bool { UserDefaults.standard.bool(forKey: onKey) }

    /// Switch it on or off. Returns what went wrong, in words, or nil.
    static func set(_ wanted: Bool, upBy: String, client: HaruClient) async -> String? {
        guard #available(iOS 26.0, *) else { return "Alarms need iOS 26." }
        #if canImport(AlarmKit)
        cancel()
        UserDefaults.standard.set(false, forKey: onKey)
        guard wanted else { return nil }
        let parts = upBy.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return "Set an “Up by” hour first." }
        do {
            let manager = AlarmManager.shared
            var state = manager.authorizationState
            if state == .notDetermined { state = try await manager.requestAuthorization() }
            guard state == .authorized else { return "Alarms are switched off for Haru in Settings." }
            let voiced = await fetchVoice(client)
            let stop = AlarmButton(text: "I'm up", textColor: .white, systemImageName: "sun.max.fill")
            let alert = AlarmPresentation.Alert(title: "Haru says get up", stopButton: stop, secondaryButton: nil, secondaryButtonBehavior: nil)
            let attributes = AlarmAttributes<HaruAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: Color("AccentColor"))
            let days: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            let schedule = Alarm.Schedule.relative(.init(time: .init(hour: parts[0], minute: parts[1]), repeats: .weekly(days)))
            let sound: AlertConfiguration.AlertSound = voiced ? .named(soundName) : .default
            let configuration = AlarmManager.AlarmConfiguration<HaruAlarmMetadata>(countdownDuration: nil, schedule: schedule, attributes: attributes, stopIntent: nil, secondaryIntent: nil, sound: sound)
            let id = UUID()
            _ = try await manager.schedule(id: id, configuration: configuration)
            UserDefaults.standard.set(id.uuidString, forKey: idKey)
            UserDefaults.standard.set(upBy, forKey: timeKey)
            UserDefaults.standard.set(true, forKey: onKey)
            return voiced ? nil : "Set, with the phone's own alarm sound: her voice could not be fetched as a WAV just now. Switch it off and on again to retry."
        } catch {
            return "The alarm would not set: \(error.localizedDescription)"
        }
        #else
        return "This build was made without AlarmKit."
        #endif
    }

    /// The "Up by" hour moved: the alarm moves with it.
    static func follow(upBy: String, client: HaruClient) async -> String? {
        guard on, UserDefaults.standard.string(forKey: timeKey) != upBy else { return nil }
        return await set(!upBy.isEmpty, upBy: upBy, client: client)
    }

    private static func cancel() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let raw = UserDefaults.standard.string(forKey: idKey), let id = UUID(uuidString: raw) {
            try? AlarmManager.shared.cancel(id: id)
        }
        #endif
        UserDefaults.standard.removeObject(forKey: idKey)
    }

    /// Her line from /api/speak into Library/Sounds. Only a RIFF/WAVE file will
    /// do there (an MP3 from a hosted voice would ring as silence), so anything
    /// else is refused and the system sound stands in.
    private static func fetchVoice(_ client: HaruClient) async -> Bool {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return false }
        let folder = library.appendingPathComponent("Sounds", isDirectory: true)
        let file = folder.appendingPathComponent(soundName)
        guard let data = try? await client.bytes("/api/speak", post: ["text": .string(line)]),
              data.count > 44, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            return FileManager.default.fileExists(atPath: file.path)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct HaruAlarmMetadata: AlarmMetadata {}
#endif
