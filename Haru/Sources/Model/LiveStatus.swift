import ActivityKit
import Foundation

/// What the Live Activity shows — on the lock screen and in the Dynamic
/// Island — while her ear is open with the phone locked or a call is on.
/// Shared by the app, which starts and updates it (Services/Live.swift), and
/// the widget extension, which draws it (HaruWidget/Sources/LiveActivity.swift).
struct HaruLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            // Standby: listening for her name, not listening because she is
            // asleep, or not listening because something took the microphone.
            case standby, asleep, paused
            // A call, as CallState has it.
            case connecting, listening, thinking, speaking

            var inCall: Bool { self == .connecting || self == .listening || self == .thinking || self == .speaking }
        }
        var phase: Phase
        /// When this phase began; a call shows how long it has run from its first.
        var since: Date
    }
}
