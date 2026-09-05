import Foundation
import WidgetKit

/// What the app leaves in the App Group for the parts of it that run on
/// their own — the widgets, the share sheet: her address, the cookie that
/// gets in (they have no jar), and the last standing the app saw so a
/// widget has something to show before its own fetch lands.
enum Shared {
    static let group = "group.com.toomiiverse.haru"
    static let cookieName = "haru_device"
    private static let baseKey = "base"
    private static let cookieKey = "cookie"
    private static let standingKey = "standing"
    private static let standingAtKey = "standingAt"
    private static let portraitKey = "portrait"
    private static let reloadedAtKey = "reloadedAt"

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    /// The address and, from the app's own jar, the cookie. Called when the
    /// app signs in and whenever it comes to the front, since the server can
    /// renew the cookie.
    static func publish(base: URL) {
        guard let defaults else { return }
        defaults.set(base.absoluteString, forKey: baseKey)
        let cookie = HTTPCookieStorage.shared.cookies(for: base)?.first { $0.name == cookieName }?.value
        if let cookie { defaults.set(cookie, forKey: cookieKey) } else { defaults.removeObject(forKey: cookieKey) }
    }

    /// The last standing, as JSON, and a nudge to the widgets — from the app.
    static func publish(standing: Standing) {
        store(standing: standing)
        reloadWidgets()
    }

    /// The same without the nudge, for a widget writing what it fetched.
    static func store(standing: Standing) {
        guard let defaults, let data = try? JSONEncoder().encode(standing) else { return }
        defaults.set(data, forKey: standingKey)
        defaults.set(Date(), forKey: standingAtKey)
    }

    /// Signed out: nothing of hers stays where another process could read it.
    static func forget() {
        guard let defaults else { return }
        for key in [cookieKey, standingKey, standingAtKey, portraitKey] { defaults.removeObject(forKey: key) }
        reloadWidgets()
    }

    static var base: URL? { defaults?.string(forKey: baseKey).flatMap { URL(string: $0) } }
    static var cookie: String? { defaults?.string(forKey: cookieKey) }

    static var standing: (standing: Standing, at: Date)? {
        guard let defaults, let data = defaults.data(forKey: standingKey),
              let standing = try? JSONDecoder().decode(Standing.self, from: data) else { return nil }
        return (standing, defaults.object(forKey: standingAtKey) as? Date ?? .distantPast)
    }

    static var portrait: Data? {
        get { defaults?.data(forKey: portraitKey) }
        set { if let newValue { defaults?.set(newValue, forKey: portraitKey) } else { defaults?.removeObject(forKey: portraitKey) } }
    }

    /// WidgetKit rations reloads; at most one a few minutes is plenty for
    /// meters that move by the hour.
    static func reloadWidgets(force: Bool = false) {
        guard let defaults else { return }
        let last = defaults.object(forKey: reloadedAtKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 5 * 60 else { return }
        defaults.set(Date(), forKey: reloadedAtKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
