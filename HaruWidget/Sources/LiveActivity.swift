import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Her ear, on the lock screen and in the Dynamic Island: standby (listening
/// for her name, asleep, or paused) and a call with its clock and a way to
/// hang up. The app keeps it (Haru/Sources/Services/Live.swift).
struct HaruLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HaruLiveAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: LiveLook.symbol(context.state.phase))
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LiveLook.title(context.state.phase)).font(.headline)
                    Text(LiveLook.detail(context.state.phase)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if context.state.phase.inCall {
                    Text(context.state.since, style: .timer)
                        .font(.callout.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                    Button(intent: HangUpHaruIntent()) {
                        Image(systemName: "phone.down.fill")
                    }
                    .tint(.red)
                }
            }
            .padding(14)
            .activityBackgroundTint(Theme.bg)
            .activitySystemActionForegroundColor(Theme.accent)
            .widgetURL(URL(string: "haru://chat"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: LiveLook.symbol(context.state.phase))
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(LiveLook.title(context.state.phase)).font(.headline)
                        Text(LiveLook.detail(context.state.phase)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase.inCall {
                        Button(intent: HangUpHaruIntent()) {
                            Image(systemName: "phone.down.fill")
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: LiveLook.symbol(context.state.phase)).foregroundStyle(Theme.accent)
            } compactTrailing: {
                if context.state.phase.inCall {
                    Text(context.state.since, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Text("Haru").font(.caption2)
                }
            } minimal: {
                Image(systemName: LiveLook.symbol(context.state.phase)).foregroundStyle(Theme.accent)
            }
            .widgetURL(URL(string: "haru://chat"))
        }
    }
}

enum LiveLook {
    typealias Phase = HaruLiveAttributes.ContentState.Phase

    static func symbol(_ phase: Phase) -> String {
        switch phase {
        case .standby: return "ear.fill"
        case .asleep: return "moon.zzz.fill"
        case .paused: return "ear.trianglebadge.exclamationmark"
        case .connecting: return "phone.connection.fill"
        case .listening: return "waveform"
        case .thinking: return "ellipsis.bubble.fill"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    static func title(_ phase: Phase) -> String {
        switch phase {
        case .standby: return "Haru is listening"
        case .asleep: return "Haru is asleep"
        case .paused: return "Standby is paused"
        case .connecting: return "Calling Haru"
        case .listening: return "She's listening"
        case .thinking: return "She's thinking"
        case .speaking: return "She's talking"
        }
    }

    static func detail(_ phase: Phase) -> String {
        switch phase {
        case .standby: return "Say “Hey Haru”"
        case .asleep: return "Her name goes unheard until she wakes"
        case .paused: return "Open Haru to start it again"
        default: return "On a call"
        }
    }
}
