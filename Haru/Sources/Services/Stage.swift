import Observation
import SwiftUI
import WebKit

/// Her on stage: a web view running Resources/stage.html, which is the phone
/// page's own SVG avatar (generated from the desktop code by
/// scripts/sync-avatar.mjs). The page lives at a scheme of its own
/// (haru-stage://) that the app answers itself, fetching each face from her
/// server with the app's own login. Nothing about cookies or origins is left
/// to the web view, and every file is seen going by, so a stall has a name.
@MainActor @Observable
final class Stage: NSObject, WKNavigationDelegate {
    enum State: Equatable {
        case loading(String)
        case alive(expressions: Int)
        case failed(String)
    }

    static let scheme = "haru-stage"
    private(set) var state: State = .loading("opening the stage")
    private weak var web: WKWebView?
    private var ready = false
    private var queue: [String] = []
    private var relay: Relay?

    func makeWebView(client: HaruClient) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let courier = Courier(client: client)
        courier.onProgress = { [weak self] line in self?.progress(line) }
        config.setURLSchemeHandler(courier, forURLScheme: Self.scheme)
        let relay = Relay(self)
        self.relay = relay
        config.userContentController.add(relay, name: "stage")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isInspectable = true
        web.navigationDelegate = self
        self.web = web
        load()
        return web
    }

    func reload() { load() }

    private func load() {
        guard let web else { return }
        guard let url = Bundle.main.url(forResource: "stage", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            state = .failed("the stage page is missing from the app")
            return
        }
        state = .loading("opening the stage")
        ready = false
        web.loadHTMLString(html, baseURL: URL(string: "\(Self.scheme)://her/")!)
    }

    private func progress(_ line: String) {
        if case .loading = state { state = .loading(line) }
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

    /// Zoom 1 fits her whole height; 2 shows her top half. Lift moves her up
    /// by that share of the stage.
    func frame(zoom: Double, lift: Double) {
        run("window.haruStage.frame(\(String(format: "%.3f", zoom)), \(String(format: "%.3f", lift)))")
    }

    /// How far and how often she looks about: 0 still, 1 lively.
    func motion(_ amount: Double) {
        run("window.haruStage.motion(\(String(format: "%.3f", amount)))")
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
        case "step":
            progress(message["what"] as? String ?? "loading")
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

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { state = .failed("the stage crashed; hold to reload") }
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

/// Answers haru-stage:// requests from her server, through the app's own
/// session — same cookie, same cache — and says what went by.
private final class Courier: NSObject, WKURLSchemeHandler {
    let client: HaruClient
    var onProgress: ((String) -> Void)?
    private var flights: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(client: HaruClient) { self.client = client }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let asked = task.request.url,
              var parts = URLComponents(url: client.base, resolvingAgainstBaseURL: false) else {
            task.didFailWithError(HaruError.badAddress)
            return
        }
        parts.path = asked.path.isEmpty ? "/" : asked.path
        parts.query = asked.query
        guard let real = parts.url else {
            task.didFailWithError(HaruError.badAddress)
            return
        }
        var request = URLRequest(url: real)
        request.httpMethod = task.request.httpMethod
        request.httpBody = task.request.httpBody
        for (name, value) in task.request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            if key == "host" || key == "origin" || key == "referer" || key == "cookie" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let name = asked.lastPathComponent.isEmpty ? asked.path : asked.lastPathComponent
        let id = ObjectIdentifier(task)
        onProgress?("fetching \(name)…")
        let session = client.session
        flights[id] = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await session.data(for: request)
                guard let self, self.flights[id] != nil else { return }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                var headers: [String: String] = [
                    "Content-Type": http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": "*",
                ]
                if let cache = http?.value(forHTTPHeaderField: "Cache-Control") { headers["Cache-Control"] = cache }
                guard let answer = HTTPURLResponse(url: asked, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    task.didFailWithError(HaruError.badAddress)
                    return
                }
                task.didReceive(answer)
                task.didReceive(data)
                task.didFinish()
                self.onProgress?(status < 300 ? "got \(name) (\(data.count / 1024) KB)" : "\(name) answered \(status)")
                self.flights[id] = nil
            } catch {
                guard let self, self.flights[id] != nil else { return }
                task.didFailWithError(error)
                self.onProgress?("\(name): \(error.localizedDescription)")
                self.flights[id] = nil
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        flights[id]?.cancel()
        flights[id] = nil
    }
}

struct StageWebView: UIViewRepresentable {
    let stage: Stage
    let client: HaruClient

    func makeUIView(context: Context) -> WKWebView {
        stage.makeWebView(client: client)
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
