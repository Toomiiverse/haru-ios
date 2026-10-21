import SwiftUI
import SwiftTerm

/// His shell on the server (/api/code/terminal), as over SSH. The server keeps it in one tmux session that
/// outlives the socket, so leaving the tab or the app and coming back finds the same shell where he left it.
@MainActor
final class TerminalLink: NSObject, TerminalViewDelegate {
    weak var view: TerminalView?
    var visible = false
    private var task: URLSessionWebSocketTask?
    private var client: HaruClient?
    /// Drops in a row with nothing received: a refused door is said once, not retried forever.
    private var failures = 0

    func connect(_ client: HaruClient) {
        self.client = client
        guard visible, task == nil, let view else { return }
        let size = view.getTerminal()
        var parts = URLComponents(url: client.base.appendingPathComponent("/api/code/terminal"), resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "cols", value: String(size.cols)), URLQueryItem(name: "rows", value: String(size.rows))]
        var request = URLRequest(url: parts.url ?? client.base)
        // The cookie by hand, as for a call: a WebSocket handshake does not reliably read the session's jar.
        if let cookies = HTTPCookieStorage.shared.cookies(for: client.base) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        }
        let ws = client.session.webSocketTask(with: request)
        task = ws
        ws.resume()
        receive(ws)
    }

    /// Back from the background or another tab: a fresh try, whatever happened before.
    func resume(_ client: HaruClient) { failures = 0; connect(client) }

    func disconnect() {
        visible = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === ws else { return }
                switch result {
                case .success(.data(let bytes)): self.failures = 0; self.view?.feed(byteArray: [UInt8](bytes)[...]); self.receive(ws)
                case .success(.string(let text)): self.failures = 0; self.view?.feed(text: text); self.receive(ws)
                case .success: self.receive(ws)
                case .failure(let error): self.dropped(error)
                }
            }
        }
    }

    private func dropped(_ error: Error) {
        task = nil
        guard visible, let client else { return }
        failures += 1
        if failures > 3 {
            view?.feed(text: "\r\n\u{1b}[31m[no shell: \(error.localizedDescription) — open the tab again to retry]\u{1b}[0m\r\n")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(failures)))
            self.connect(client)
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        task?.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        task?.send(.string("{\"resize\":[\(newCols),\(newRows)]}")) { _ in }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" { UIApplication.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The terminal itself: SwiftTerm draws it and brings the keys a phone keyboard lacks (esc, ctrl, tab, arrows).
struct TerminalPane: UIViewRepresentable {
    let link: TerminalLink

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        // SwiftTerm 1.11 leaves the view opaque, so iOS never clears a redrawn strip and old glyphs show under new
        // ones (tmux's scroll region, Claude Code's redraws). Upstream's fix (d44954c, 1.14) is this one line.
        view.isOpaque = false
        view.terminalDelegate = link
        link.view = view
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
}
