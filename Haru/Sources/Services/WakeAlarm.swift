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
            let days: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            let config = configuration(.relative(.init(time: .init(hour: parts[0], minute: parts[1]), repeats: .weekly(days))), voiced: voiced)
            let id = UUID()
            _ = try await manager.schedule(id: id, configuration: config)
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

    /// The "Up by" hour moved: the daily alarm moves with it.
    static func followDaily(upBy: String, client: HaruClient) async -> String? {
        guard on, UserDefaults.standard.string(forKey: timeKey) != upBy else { return nil }
        return await set(!upBy.isEmpty, upBy: upBy, client: client)
    }

    /// What the server holds, brought level with the phone's alarms: the daily
    /// hour, and his one-off "wake me up at …" said to her (prefs.wakeAt). Called
    /// when the app comes to the front, on every push of hers and on a refresh,
    /// so a time said at night is set before the phone is put down.
    static func follow(client: HaruClient) async {
        guard supported, let info: PushInfo = try? await client.get("/api/push") else { return }
        _ = await followDaily(upBy: info.prefs.upBy, client: client)
        await once(info.prefs.wakeAt ?? "", client: client)
    }

    private static let onceIdKey = "alarm.once.id"
    private static let onceAtKey = "alarm.once.at"
    /// The one-off: set when the server's time is new and still ahead, dropped
    /// once it has passed or the server no longer holds one. Rings whether or
    /// not the daily alarm is on — he asked for this one by name.
    private static func once(_ at: String, client: HaruClient) async {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *) else { return }
        let defaults = UserDefaults.standard
        guard let when = date(at), when > Date() else {
            if defaults.string(forKey: onceIdKey) != nil { cancelOnce() }
            return
        }
        guard defaults.string(forKey: onceAtKey) != at || defaults.string(forKey: onceIdKey) == nil else { return }
        let manager = AlarmManager.shared
        var state = manager.authorizationState
        if state == .notDetermined { state = (try? await manager.requestAuthorization()) ?? state }
        guard state == .authorized else { return }
        cancelOnce()
        let voiced = await fetchVoice(client)
        let id = UUID()
        guard (try? await manager.schedule(id: id, configuration: configuration(.fixed(when), voiced: voiced))) != nil else { return }
        defaults.set(id.uuidString, forKey: onceIdKey)
        defaults.set(at, forKey: onceAtKey)
        #endif
    }

    private static func cancelOnce() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let raw = UserDefaults.standard.string(forKey: onceIdKey), let id = UUID(uuidString: raw) {
            try? AlarmManager.shared.cancel(id: id)
        }
        #endif
        UserDefaults.standard.removeObject(forKey: onceIdKey)
        UserDefaults.standard.removeObject(forKey: onceAtKey)
    }

    /// "yyyy-MM-dd'T'HH:mm" in the phone's zone, which is his.
    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: text)
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func configuration(_ schedule: Alarm.Schedule, voiced: Bool) -> AlarmManager.AlarmConfiguration<HaruAlarmMetadata> {
        let stop = AlarmButton(text: "I'm up", textColor: .white, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: "Haru says get up", stopButton: stop, secondaryButton: nil, secondaryButtonBehavior: nil)
        let attributes = AlarmAttributes<HaruAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: Color("AccentColor"))
        let sound: AlertConfiguration.AlertSound = voiced ? .named(soundName) : .default
        return AlarmManager.AlarmConfiguration<HaruAlarmMetadata>(countdownDuration: nil, schedule: schedule, attributes: attributes, stopIntent: nil, secondaryIntent: nil, sound: sound)
    }
    #endif

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
