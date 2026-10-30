import LocalAuthentication
import Observation
import SwiftUI

/// The lock on her door when the phone is in someone else's hand.
///
/// The web sign-in remembered this phone for 90 days, and the app had no lock
/// of its own: whoever held the unlocked phone could open her and type as him
/// (2026-10-30). This asks for Face ID or the phone passcode on a cold launch
/// and after a minute in the background. It covers the interface only — pushes,
/// reminders and a call already in progress still run — and it never blocks the
/// session itself, so failing it leaves her behind the lock rather than signed
/// out.
@MainActor @Observable
final class AppLock {
    static let shared = AppLock()

    private static let wantedKey = "haru.appLock.wanted"
    private static let graceSeconds: TimeInterval = 60

    /// True while the interface must stay covered.
    private(set) var locked: Bool
    /// False when the phone has no Face ID and no passcode to fall back on.
    private(set) var available: Bool
    private(set) var checking = false
    var message: String?

    private var leftAt: Date?

    private init() {
        let wanted = UserDefaults.standard.object(forKey: Self.wantedKey) as? Bool ?? true
        let can = Self.canAuthenticate()
        available = can
        locked = wanted && can
    }

    /// Whether the owner asked for the lock. On unless they turn it off.
    var wanted: Bool { UserDefaults.standard.object(forKey: Self.wantedKey) as? Bool ?? true }

    func setWanted(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.wantedKey)
        available = Self.canAuthenticate()
        message = nil
        locked = on && available
    }

    func lockNow() {
        guard available, wanted else { return }
        message = nil
        locked = true
    }

    func wentBackground() {
        leftAt = Date()
    }

    /// Back in front: a quick look at a notification keeps the app open, a real
    /// absence locks it again.
    ///
    /// The timestamp is consumed exactly once. Re-locking on every `.active`
    /// while Face ID's own sheet made the app inactive put the prompt in a
    /// loop (2026-10-30): the sheet closes, the app becomes active, the old
    /// background stamp still looks like an absence, and the lock asks again.
    /// The lock cover asks once when it appears; a cancelled prompt leaves the
    /// Unlock button, not another automatic prompt.
    func cameBack() {
        guard available, wanted else { leftAt = nil; return }
        guard let leftAt else { return }
        self.leftAt = nil
        guard Date().timeIntervalSince(leftAt) >= Self.graceSeconds else { return }
        message = nil
        locked = true
    }

    /// Used by a notification reply: the app has come to the front anyway, so
    /// ask before her words go out.
    func ensureUnlocked() async -> Bool {
        guard available, wanted else { return true }
        if !locked { return true }
        // The lock screen may already be asking; wait for that answer instead
        // of starting a second prompt and dropping the reply.
        var waited = 0
        while checking && waited < 50 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        if !locked { return true }
        await unlock()
        return !locked
    }

    func unlock() async {
        guard available, !checking else { return }
        checking = true
        defer { checking = false }
        let context = LAContext()
        context.localizedCancelTitle = "Stay locked"
        context.localizedFallbackTitle = "Use Passcode"
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            // A phone with no passcode cannot be locked meaningfully; do not
            // trap her behind a door that can never open.
            available = false
            locked = false
            message = "Set a phone passcode to use the lock."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Haru")
            if ok {
                locked = false
                message = nil
                leftAt = nil
            }
        } catch {
            message = "Haru is locked."
        }
    }

    private static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}

/// What sits over her while the app is locked, and over the frozen snapshot in
/// the app switcher.
struct LockCover: View {
    @Environment(AppLock.self) private var lock
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Haru")
                .font(.largeTitle.weight(.semibold))
            Text(lock.message ?? "Face ID or your passcode to talk to her.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await lock.unlock() }
            } label: {
                Text(lock.checking ? "Checking…" : "Unlock")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .disabled(lock.checking)
            Text("Typing, her diary and her memory stay behind this screen.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 40)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LaunchBackground").ignoresSafeArea())
        // Ask once when this cover appears. A cancelled or failed prompt leaves
        // `message` set, so SwiftUI re-showing the cover does not start the
        // Face ID sheet again by itself; the Unlock button is the retry.
        .task { if lock.message == nil { await lock.unlock() } }
    }
}

/// An opaque cover for the instant the app leaves the screen, so the app
/// switcher does not show her last message to whoever picks the phone up.
struct PrivacyCover: View {
    var body: some View {
        Color("LaunchBackground")
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            }
    }
}
