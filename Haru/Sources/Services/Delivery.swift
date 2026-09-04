import UserNotifications

/// How iOS is showing her notifications on this phone — the answer to "why
/// was that one silent", read from the system settings: permission, banners,
/// the lock screen, sound, the scheduled summary, time-sensitivity. A Focus
/// mode silences her as well, and that iOS keeps to itself.
struct Delivery: Equatable {
    enum Status { case allowed, quiet, held, denied, notAsked }

    let status: Status
    /// One line: what happens when she has something to say.
    let headline: String
    /// The settings behind it, for the footnote.
    let details: String

    static func current() async -> Delivery {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let on = { (setting: UNNotificationSetting) in setting == .enabled }
        let banners: String
        switch s.alertStyle {
        case .none: banners = "off"
        case .alert: banners = "persistent"
        default: banners = "on"
        }
        let timeSensitive: String
        switch s.timeSensitiveSetting {
        case .enabled: timeSensitive = "on"
        case .disabled: timeSensitive = "off"
        default: timeSensitive = "not set up"
        }
        let details = [
            "Banners \(banners)",
            "lock screen \(on(s.lockScreenSetting) ? "on" : "off")",
            "Notification Center \(on(s.notificationCenterSetting) ? "on" : "off")",
            "sound \(on(s.soundSetting) ? "on" : "off")",
            "time-sensitive \(timeSensitive)",
            s.scheduledDeliverySetting == .enabled ? "held for the summary" : "delivered immediately",
        ].joined(separator: " · ")

        switch s.authorizationStatus {
        case .notDetermined:
            return Delivery(status: .notAsked, headline: "Not asked yet", details: details)
        case .denied:
            return Delivery(status: .denied, headline: "Not allowed — she cannot reach this phone", details: details)
        case .provisional:
            return Delivery(status: .quiet, headline: "Quietly, in Notification Center only, until you pick “Deliver Prominently” on one of hers", details: details)
        default:
            if s.scheduledDeliverySetting == .enabled {
                return Delivery(status: .held, headline: "Held back for the Notification Summary", details: details)
            }
            if !on(s.alertSetting) || (s.alertStyle == .none && !on(s.lockScreenSetting)) {
                return Delivery(status: .quiet, headline: "Quietly — Notification Center only, no banner, no sound", details: details)
            }
            if s.alertStyle == .none {
                return Delivery(status: .quiet, headline: "On the lock screen only — no banner while you are using the phone", details: details)
            }
            let sound = on(s.soundSetting) ? "with sound" : "silently"
            let lock = on(s.lockScreenSetting) ? "and on the lock screen" : "but not on the lock screen"
            return Delivery(status: .allowed, headline: "As a banner \(sound), \(lock)", details: details)
        }
    }
}
