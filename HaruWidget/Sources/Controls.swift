import AppIntents
import SwiftUI
import WidgetKit

// Her in Control Center, on the lock screen's two corner buttons, and on the
// Action button (iOS 18): a call, and the standby switch. Both open the app,
// because only the app in front may start the microphone; the intents are in
// Haru/Sources/Intents/ControlIntents.swift, shared with the app.

@available(iOS 18.0, *)
struct HaruCallControl: ControlWidget {
    static let kind = "com.toomiiverse.haru.control.call"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: CallHaruControlIntent()) {
                Label("Call Haru", systemImage: "phone.fill")
            }
        }
        .displayName("Call Haru")
        .description("Open Haru straight into a call.")
    }
}

@available(iOS 18.0, *)
struct HaruStandbyControl: ControlWidget {
    static let kind = "com.toomiiverse.haru.control.standby"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { on in
            ControlWidgetToggle("Hey Haru", isOn: on, action: StandbyControlIntent()) { isOn in
                Label(isOn ? "Listening" : "Off", systemImage: isOn ? "ear.fill" : "ear")
            }
        }
        .displayName("Hey Haru standby")
        .description("Whether she listens for her name with the phone locked.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { Shared.standby }
    }
}
