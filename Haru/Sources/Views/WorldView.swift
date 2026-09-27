import Observation
import SwiftUI
import WebKit

/// The same live world as the desktop, with the phone's existing sign-in.
struct WorldView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var browser = WorldBrowser()
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            WorldWebView(browser: browser)
                .opacity(browser.problem == nil ? 1 : 0)
            if let problem = browser.problem {
                ContentUnavailableView {
                    Label("Her world is out of reach", systemImage: "leaf")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try again") { reloadID = UUID() }
                        .buttonStyle(.borderedProminent)
                }
            } else if browser.loading {
                ProgressView("Opening her world…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Little World")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") { reloadID = UUID() }
            }
        }
        .task(id: reloadID) {
            await browser.load(base: session.client.base,
                               signedOut: { [session] in session.signedIn = false },
                               close: { [dismiss] in dismiss() })
        }
        .onDisappear { browser.stop() }
    }
}

private struct WorldWebView: UIViewRepresentable {
    let browser: WorldBrowser

    func makeUIView(context: Context) -> WKWebView { browser.web }
    func updateUIView(_ web: WKWebView, context: Context) {}
}

@MainActor @Observable
private final class WorldBrowser: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private(set) var loading = true
    private(set) var problem: String?
    private var base: URL?
    private var generation = 0
    private var signedOut: (() -> Void)?
    private var close: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        // Keep this login only for the lifetime of this screen. Cookies stay
        // HttpOnly: never put credentials into JavaScript or the page's URL.
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.overrideUserInterfaceStyle = .light
        web.backgroundColor = UIColor(red: 245 / 255, green: 241 / 255, blue: 233 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.isOpaque = false
    }

    func load(base: URL, signedOut: @escaping () -> Void, close: @escaping () -> Void) async {
        stop()
        let attempt = generation
        self.base = base
        self.signedOut = signedOut
        self.close = close
        loading = true
        problem = nil
        let url = base.appendingPathComponent("world")
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            fail("Check Haru’s server address, then try again.")
            return
        }
        let store = web.configuration.websiteDataStore.httpCookieStore
        let oldCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in oldCookies {
            guard !Task.isCancelled, generation == attempt else { return }
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
        let cookies = (HTTPCookieStorage.shared.cookies(for: url) ?? []).filter {
            $0.name == "haru_device" || $0.name == "haru_session"
        }
        for cookie in cookies {
            guard !Task.isCancelled, generation == attempt else { return }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
        guard !Task.isCancelled, generation == attempt else { return }
        // A fresh page avoids a cached success masking an expired login. The
        // simulation itself is saved on the server and survives every reload.
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                            timeoutInterval: 30))
    }

    func stop() {
        generation += 1
        web.stopLoading()
        loading = false
        signedOut = nil
        close = nil
    }

    private func fail(_ message: String) {
        loading = false
        problem = message
    }

    private func sameOrigin(_ url: URL, as base: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : 80) }
        return url.scheme?.lowercased() == base.scheme?.lowercased()
            && url.host?.lowercased() == base.host?.lowercased()
            && port(url) == port(base)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url, let base, sameOrigin(url, as: base) else {
                decisionHandler(.cancel)
                return
            }
            if url.path == base.appendingPathComponent("world").path,
               navigationAction.targetFrame?.isMainFrame != false {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                // The web page's "Back to Haru" belongs to the native app.
                if navigationAction.navigationType == .linkActivated,
                   url.path == "/" || url.path == base.path {
                    close?()
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            if let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                decisionHandler(.cancel)
                if response.statusCode == 401 {
                    signedOut?()
                } else if response.statusCode == 404 {
                    fail("Her server does not have Little World yet. Update the server, then try again.")
                } else {
                    fail("Her server could not open the world (\(response.statusCode)). Try again in a moment.")
                }
            } else {
                decisionHandler(.allow)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loading = false }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        navigationFailed(error)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    nonisolated private func navigationFailed(_ error: Error) {
        MainActor.assumeIsolated {
            let error = error as NSError
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            fail("Make sure Tailscale is connected and Haru’s server is awake, then try again.")
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { fail("The world view stopped. Reload to rejoin her.") }
    }
}
