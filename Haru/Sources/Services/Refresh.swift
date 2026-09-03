import BackgroundTasks
import UserNotifications

/// Her speaking first while the app is closed, as far as a phone allows it
/// without a push service: iOS wakes the app now and then, the app asks
/// /api/nudge, and anything she has to say becomes a local notification.
///
/// This is best effort by design. iOS decides when (and whether) a refresh
/// runs — minutes to hours apart, never while Low Power Mode is on. Real
/// pushes need APNs, which needs a paid developer account; see the README.
enum Refresh {
    static let id = "com.toomiiverse.haru.refresh"

    static func register(session: Session) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            schedule()
            var work: Task<Void, Never>?
            refresh.expirationHandler = { work?.cancel() }
            work = Task { @MainActor in
                let ok = await check(session)
                refresh.setTaskCompleted(success: ok)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func askPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func check(_ session: Session) async -> Bool {
        guard session.signedIn == true else { return true }
        do {
            let nudge: Nudge = try await session.client.get("/api/nudge")
            if let line = nudge.line, !line.isEmpty { await notify(line) }
            return true
        } catch {
            return false
        }
    }

    static func notify(_ line: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Haru"
        content.body = line
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
