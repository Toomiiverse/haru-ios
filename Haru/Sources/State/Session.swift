import Foundation
import Observation
import UIKit

/// Where she is and whether this phone is signed in. The cookie does the real
/// work; this only knows whether the last request was let through.
@MainActor @Observable
final class Session {
    nonisolated static let defaultBase = "https://haruserver.tail6da04d.ts.net"
    nonisolated private static let baseKey = "haru.base"

    private(set) var baseURLString: String
    private(set) var client: HaruClient
    /// nil until the first check; false shows the sign-in screen.
    var signedIn: Bool?
    var problem: String?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.baseKey) ?? Self.defaultBase
        baseURLString = saved
        client = Self.makeClient(saved)
    }

    private static func makeClient(_ raw: String) -> HaruClient {
        HaruClient(base: normalized(raw))
    }

    nonisolated private static func normalized(_ raw: String) -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        return URL(string: trimmed) ?? URL(string: defaultBase)!
    }

    /// A client for code that runs without a Session — the notification
    /// delegate answering from the lock screen. Same saved address, same
    /// cookie jar (HaruClient keeps it in HTTPCookieStorage.shared).
    nonisolated static func savedClient(quick: Bool = false) -> HaruClient {
        HaruClient(base: normalized(UserDefaults.standard.string(forKey: baseKey) ?? defaultBase), quick: quick)
    }

    func useBase(_ raw: String) {
        baseURLString = raw
        UserDefaults.standard.set(raw, forKey: Self.baseKey)
        client = Self.makeClient(raw)
    }

    /// Asks for the day, which is the cheapest thing behind the login.
    func check(quick: Bool = false) async {
        do {
            let checking = quick ? HaruClient(base: client.base, quick: true) : client
            let _: ChatPage = try await checking.get("/api/chat")
            signedIn = true
            problem = nil
            Shared.publish(base: client.base)
        } catch HaruError.signedOut {
            signedIn = false
            problem = nil
        } catch {
            // Unreachable is not the same as signed out: keep whatever we knew.
            if signedIn == nil { signedIn = false }
            problem = error.localizedDescription
        }
    }

    func signIn(username: String, password: String) async throws {
        let _: Okay = try await client.post("/api/login", [
            "username": .string(username),
            "password": .string(password),
            "remember": true,
            "device": .string(UIDevice.current.name),
        ])
        signedIn = true
        problem = nil
        Shared.publish(base: client.base)
    }

    func signOut() async {
        PhoneTools.shared.stop()
        let _: Okay? = try? await client.post("/api/logout")
        client.forgetCookies()
        Shared.forget()
        signedIn = false
    }
}
