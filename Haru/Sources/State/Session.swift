import Foundation
import Observation
import UIKit

/// Where she is and whether this phone is signed in. The cookie does the real
/// work; this only knows whether the last request was let through.
@MainActor @Observable
final class Session {
    static let defaultBase = "https://haruserver.tail6da04d.ts.net"
    private static let baseKey = "haru.base"

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
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        return HaruClient(base: URL(string: trimmed) ?? URL(string: defaultBase)!)
    }

    func useBase(_ raw: String) {
        baseURLString = raw
        UserDefaults.standard.set(raw, forKey: Self.baseKey)
        client = Self.makeClient(raw)
    }

    /// Asks for the day, which is the cheapest thing behind the login.
    func check() async {
        do {
            let _: ChatPage = try await client.get("/api/chat")
            signedIn = true
            problem = nil
        } catch HaruError.signedOut {
            signedIn = false
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
    }

    func signOut() async {
        let _: Okay? = try? await client.post("/api/logout")
        client.forgetCookies()
        signedIn = false
    }
}
