import Foundation
import Observation

/// Where the app should be looking, for the things that arrive from outside a
/// screen: a tapped notification, a haru:// link from Safari or a Shortcut.
/// One shared instance, because the notification delegate needs it on a cold
/// launch before any view exists.
@MainActor @Observable
final class Navigator {
    static let shared = Navigator()

    enum Tab: Hashable { case chat, code, status, her, more }

    var tab: Tab = .chat
    /// Set by haru://talk; the chat screen opens the ear and clears it.
    var wantsTalk = false
    /// Set by haru://call and the Call Haru shortcut; the chat screen places the call.
    var wantsCall = false
    /// Set by /code, haru://code and a coder's push: the Code tab opens this folder ("" for a quick session).
    var wantsCode: String?
    /// Set by haru://diary: the Her tab opens her diary.
    var wantsDiary = false

    /// /code typed to her, haru://code, a coder's push: over to the Code tab.
    func openCode(_ folder: String?) {
        tab = .code
        wantsCode = folder
    }

    /// A tapped notification: a reminder lands on the list, anything else on the chat.
    func openPush(kind: String?, url: String? = nil) {
        if let url, url.hasPrefix("haru://code"), let link = URL(string: url) { open(link); return }
        tab = kind == "events" ? .status : .chat
    }

    /// haru://chat, haru://talk, haru://call, haru://code, haru://status, haru://diary, haru://her, haru://more.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "haru" else { return }
        let where_ = (url.host(percentEncoded: false) ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch where_ {
        case "talk":
            tab = .chat
            wantsTalk = true
        case "call":
            tab = .chat
            wantsCall = true
        case "code":
            openCode(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value)
        case "status": tab = .status
        case "diary":
            tab = .her
            wantsDiary = true
        case "her": tab = .her
        case "more": tab = .more
        default: tab = .chat
        }
    }
}
