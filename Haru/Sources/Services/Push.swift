import SwiftUI
import UserNotifications

/// Her speaking first, for real: Apple's push service, now that there is an
/// account to register with. The app hands its device token to the server
/// (`POST /api/push/apns`), and the server posts to Apple whenever she has a
/// line for the phone — the same lines, quiet hours and spacing as the web
/// page's pushes. Refresh.swift's polling stays as the fallback for the days
/// the server has no key yet, or Apple is having one.
enum Push {
    private static let tokenKey = "haru.apns.token"
    private static let uploadedKey = "haru.apns.uploaded"

    /// A debug build run from Xcode talks to Apple's sandbox; TestFlight and
    /// the store are production. The server needs to know which.
    static var sandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Ask iOS for a token. Cheap to call again; iOS answers with the same one.
    @MainActor
    static func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The token as Apple gave it, kept until the server has it.
    static func received(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: tokenKey) != hex { defaults.set(false, forKey: uploadedKey) }
        defaults.set(hex, forKey: tokenKey)
    }

    /// Hand the token over once we are signed in; again if it ever changes.
    @MainActor
    static func sync(_ session: Session) async {
        let defaults = UserDefaults.standard
        guard session.signedIn == true, let token = defaults.string(forKey: tokenKey), !defaults.bool(forKey: uploadedKey) else { return }
        struct Ack: Decodable { let ok: Bool?; let ready: Bool? }
        do {
            let ack: Ack = try await session.client.post("/api/push/apns", ["token": .string(token), "sandbox": .bool(sandbox)])
            defaults.set(ack.ok == true, forKey: uploadedKey)
        } catch {
            // Next time the app comes to the front.
        }
    }
}

/// The app delegate exists for the two things SwiftUI cannot do on its own:
/// receive the device token, and decide how a notification shows while the
/// app is open.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.received(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token: the polling in Refresh.swift carries on as before.
    }

    /// Open on her page, a push is still shown — the line lands in the chat
    /// on the next poll, and the banner is the one that plays the sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
