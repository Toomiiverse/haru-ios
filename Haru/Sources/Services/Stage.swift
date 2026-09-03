import Observation
import SwiftUI
import WebKit

/// Her on stage: a web view running Resources/stage.html against her server,
/// which is the same pixi + Cubism runtime and model the desktop shows. The
/// app's login cookie is copied into the web view so the model, the runtime
/// and /api/model all load behind the login as they should.
@MainActor @Observable
final class Stage: NSObject, WKNavigationDelegate {
    enum State: Equatable {
        case loading
        case alive(expressions: Int)
        case failed(String)
    }

    private(set) var state: State = .loading
    private weak var web: WKWebView?
    private var base: URL?
    private var ready = false
    private var queue: [String] = []

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // The default store keeps the HTTP cache, so 28MB of model is fetched
        // once and then served from the phone until the server says otherwise.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isInspectable = true
        return web
    }

    func attach(_ web: WKWebView, base: URL) {
        self.web = web
        self.base = base
        web.navigationDelegate = self
        web.configuration.userContentController.add(Relay(self), name: "stage")
        Task { await load() }
    }

    func reload() {
        Task { await load() }
    }

    private func load() async {
        guard let web, let base else { return }
        guard let url = Bundle.main.url(forResource: "stage", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            state = .failed("the stage page is missing from the app")
            return
        }
        state = .loading
        ready = false
        let jar = web.configuration.websiteDataStore.httpCookieStore
        for cookie in HTTPCookieStorage.shared.cookies(for: base) ?? [] {
            await jar.setCookie(cookie)
        }
        web.loadHTMLString(html, baseURL: base)
    }

    // MARK: What the app asks of her

    /// A Live2D expression by name — the one /api/expression chose — or nil to
    /// let her face go back to rest.
    func express(_ name: String?) {
        run("window.haruStage.express(\(literal(name)))")
    }

    /// Something has her attention for a while: "typing", "talking", "thinking".
    func attend(_ why: String, ms: Int = 1500) {
        run("window.haruStage.attend(\(literal(why)), \(ms))")
    }

    /// How open her mouth is, 0–1, from the app's audio meter while she speaks.
    func mouth(_ open: Double) {
        run("window.haruStage.mouth(\(String(format: "%.3f", open)))")
    }

    private func run(_ js: String) {
        if ready, let web {
            web.evaluateJavaScript(js)
        } else {
            queue.append(js)
            if queue.count > 60 { queue.removeFirst(queue.count - 60) }
        }
    }

    private func literal(_ value: String?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    // MARK: What she says back

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["event"] as? String else { return }
        switch event {
        case "alive":
            state = .alive(expressions: message["expressions"] as? Int ?? 0)
        case "failed":
            state = .failed(message["why"] as? String ?? "she did not say why")
        default:
            break
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            ready = true
            let waiting = queue
            queue = []
            for js in waiting { webView.evaluateJavaScript(js) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { state = .failed(error.localizedDescription) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { state = .failed(error.localizedDescription) }
    }

    /// The web view holds its message handlers strongly; this stands in so the
    /// stage itself is not kept alive by its own web view.
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var stage: Stage?
        init(_ stage: Stage) { self.stage = stage }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { stage?.receive(body) }
        }
    }
}

struct StageWebView: UIViewRepresentable {
    let stage: Stage
    let base: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = Stage.makeWebView()
        stage.attach(web, base: base)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
