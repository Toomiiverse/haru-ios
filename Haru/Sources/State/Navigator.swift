import Foundation
import Observation

/// Where the app should be looking, for the things that arrive from outside a
/// screen: a tapped notification, a haru:// link from Safari or a Shortcut.
/// One shared instance, because the notification delegate needs it on a cold
/// launch before any view exists.
@MainActor @Observable
final class Navigator {
    static let shared = Navigator()

    enum Tab: Hashable { case chat, status, diary, her, more }

    var tab: Tab = .chat
    /// Set by haru://talk; the chat screen opens the ear and clears it.
    var wantsTalk = false

    /// A tapped notification: a reminder lands on the list, anything else on the chat.
    func openPush(kind: String?) {
        tab = kind == "events" ? .status : .chat
    }

    /// haru://chat, haru://talk, haru://status, haru://diary, haru://her, haru://more.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "haru" else { return }
        let where_ = (url.host(percentEncoded: false) ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch where_ {
        case "talk":
            tab = .chat
            wantsTalk = true
        case "status": tab = .status
        case "diary": tab = .diary
        case "her": tab = .her
        case "more": tab = .more
        default: tab = .chat
        }
    }
}
