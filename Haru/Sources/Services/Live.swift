import ActivityKit
import UIKit

/// The Live Activity's keeper. One activity at most; ChatStore says what phase
/// it is in (`livePhase`) and this makes the lock screen agree. iOS only lets
/// an activity START with the app in front — standby and a held-mic call both
/// begin there — but an existing one can be updated from the background, which
/// is how a call that "Hey Haru" started shows up on a locked phone.
@MainActor
enum Live {
    typealias Phase = HaruLiveAttributes.ContentState.Phase

    /// More › "On the lock screen while she listens". On unless switched off.
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "live.on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "live.on") }
    }

    private static var callBegan: Date?
    private static var shown: Phase?

    static func show(_ phase: Phase?) {
        guard let phase, wanted else { end(); return }
        // A call counts from its first phase, not from each change of state.
        if phase.inCall { callBegan = callBegan ?? Date() } else { callBegan = nil }
        let state = HaruLiveAttributes.ContentState(phase: phase, since: phase.inCall ? (callBegan ?? Date()) : Date())
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = Activity<HaruLiveAttributes>.activities.first {
            guard shown != phase else { return }
            shown = phase
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active else { return }
        do {
            _ = try Activity.request(attributes: HaruLiveAttributes(), content: content, pushType: nil)
            shown = phase
        } catch {
            // Refused (too many activities, switched off in Settings): she works the same without it.
        }
    }

    static func end() {
        shown = nil
        callBegan = nil
        for activity in Activity<HaruLiveAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
