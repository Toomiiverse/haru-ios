import SwiftUI
import UserNotifications

/// Her speaking first, for real: Apple's push service, now that there is an
/// account to register with. The app hands its device token to the server
/// (`POST /api/push/apns`), and the server posts to Apple whenever she has a
/// line for the phone — the same lines, quiet hours and spacing as the web
/// page's pushes. Refresh.swift's polling stays as the fallback for the days
/// the server has no key yet, or Apple is having one.
///
/// And answering from the lock screen: every line takes a reply under the
/// notification, and a reminder about a thing on the list takes "Done" too.
/// The server names the category and puts what the buttons need under `haru`
/// in the payload (apnsPayload in electron/apns.ts); Refresh.swift builds the
/// same for its local notifications.
enum Push {
    private static let tokenKey = "haru.apns.token"
    private static let uploadedKey = "haru.apns.uploaded"

    enum Category: String { case line = "HARU_LINE", event = "HARU_EVENT" }
    enum Action: String { case reply = "REPLY", done = "DONE" }

    /// A debug build run from Xcode talks to Apple's sandbox; TestFlight and
    /// the store are production. The server needs to know which.
    static var sandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The buttons, declared once at launch. `options: []` keeps a reply in
    /// the background — no unlock, no app coming to the front.
    static func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: Action.reply.rawValue, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Say something back")
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "Done", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Category.line.rawValue, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.event.rawValue, actions: [reply, done], intentIdentifiers: []),
        ])
    }

    /// What a local notification carries so the buttons work the same way.
    static func userInfo(kind: String, eventId: String?) -> [AnyHashable: Any] {
        var haru: [String: Any] = ["kind": kind, "url": "/"]
        if let eventId { haru["eventId"] = eventId }
        return ["haru": haru]
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

    /// A reply typed under the notification, sent as if from the chat. The
    /// quick client has a short timeout and there is no retry: the server
    /// keeps answering after the socket drops, and a retry would be a second
    /// message. The exchange shows in the chat the next time it loads.
    static func reply(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let _: Ignored? = try? await Session.savedClient(quick: true).post("/api/chat", ["text": .string(trimmed)])
    }

    /// "Done" under a reminder: the item on the list is ticked off.
    static func markDone(_ id: String) async {
        let _: Ignored? = try? await Session.savedClient(quick: true).post("/api/agenda/done", ["id": .string(id)])
    }

    /// Keeps iOS from suspending the app while a lock-screen action finishes.
    /// A cold-launched app gets about thirty seconds either way.
    static func holdingOn(_ work: () async -> Void) async {
        let token = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "haru.push.action") }
        await work()
        await MainActor.run { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
    }
}

/// The app delegate exists for the things SwiftUI cannot do on its own:
/// receive the device token, decide how a notification shows while the app
/// is open, and act on the buttons under one.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Push.registerCategories()
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

    /// A button under the notification, or a tap on it. Returning is what
    /// tells iOS the work is done, so the sends are awaited here.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let haru = response.notification.request.content.userInfo["haru"] as? [String: Any]
        let kind = haru?["kind"] as? String
        switch response.actionIdentifier {
        case Push.Action.reply.rawValue:
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            await Push.holdingOn { await Push.reply(text) }
        case Push.Action.done.rawValue:
            guard let id = haru?["eventId"] as? String else { return }
            await Push.holdingOn { await Push.markDone(id) }
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { Navigator.shared.openPush(kind: kind) }
        default:
            break
        }
    }
}
