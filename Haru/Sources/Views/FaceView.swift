import SwiftUI
import WebKit

/// Her face for a mood: the SVG the server keeps under /emotions/, shown in a
/// small web view because SwiftUI has no SVG of its own. Falls back to her
/// portrait when the server has no such face.
struct FaceView: View {
    let emotion: String
    @Environment(Session.self) private var session
    @State private var svg: Data?
    @State private var cache: [String: Data] = [:]
    @State private var portrait: UIImage?

    var body: some View {
        ZStack {
            if let svg {
                SVGView(svg: svg)
            } else if let portrait {
                Image(uiImage: portrait).resizable().scaledToFill().clipShape(Circle())
            } else {
                Circle().fill(.quaternary)
            }
        }
        .task(id: emotion) { await load() }
    }

    private func load() async {
        let file = Face.file(for: emotion)
        if let hit = cache[file] { svg = hit; return }
        if let data = try? await session.client.bytes("/emotions/\(file).svg") {
            cache[file] = data
            svg = data
            return
        }
        if portrait == nil, let data = try? await session.client.bytes("/portrait") {
            portrait = UIImage(data: data)
        }
    }
}

struct SVGView: UIViewRepresentable {
    let svg: Data

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != svg else { return }
        context.coordinator.shown = svg
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}img{width:100%;height:100%;object-fit:contain;display:block}</style>
        <img src="data:image/svg+xml;base64,\(svg.base64EncodedString())">
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: Data?
    }
}
