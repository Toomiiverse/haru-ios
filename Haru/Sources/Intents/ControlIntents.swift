import AppIntents
import Foundation

// The intents behind the controls (HaruWidget/Sources/Controls.swift). They
// are compiled into the app and the widget extension both, which is what iOS
// asks of a control's intent, so they touch nothing but the App Group: the
// wish is left in Shared, the app opens (openAppWhenRun), and HaruApp takes it
// from there. The microphone can only be started by the app in front (Apple
// DTS, forums thread 815725), so both of these open it.

/// Straight into a call, from Control Center, the lock screen or the Action button.
@available(iOS 18.0, *)
struct CallHaruControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Haru"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        Shared.ask(.call)
        return .result()
    }
}

/// The red button on the Live Activity (LiveActivity.swift). A LiveActivityIntent
/// runs in the app's process without bringing it to the front, which is all a
/// hang-up needs.
struct HangUpHaruIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hang Up"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        Shared.ask(.hangUp)
        return .result()
    }
}

/// Standby on or off: "Hey Haru" with the phone locked.
@available(iOS 18.0, *)
struct StandbyControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Haru Standby"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Listening")
    var value: Bool

    func perform() async throws -> some IntentResult {
        Shared.ask(value ? .standbyOn : .standbyOff)
        return .result()
    }
}
