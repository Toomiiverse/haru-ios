import SwiftUI
import WebKit

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            switch session.signedIn {
            case .none:
                WakingView()
                    .task {
                        // Bounded asks (25 s, no waiting for connectivity), repeated: a stalled
                        // request never leaves her on this screen without a word (10-19).
                        while !Task.isCancelled, session.signedIn == nil {
                            await session.check(quick: true)
                            if session.signedIn == nil { try? await Task.sleep(for: .seconds(5)) }
                        }
                    }
            case .some(false):
                LoginView()
            case .some(true):
                MainTabs()
            }
        }
        .background(Color("LaunchBackground").ignoresSafeArea())
    }
}

struct MainTabs: View {
    @Environment(Navigator.self) private var nav
    /// Kept here so a coding session's cards survive switching tabs.
    @State private var code = CodeStore()

    var body: some View {
        @Bindable var nav = nav
        TabView(selection: $nav.tab) {
            ChatView()
                .background(Color("LaunchBackground"))
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Navigator.Tab.chat)
            CodeView(store: code)
                .background(Color("LaunchBackground"))
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(Navigator.Tab.code)
            StatusView()
                .tabItem { Label("Status", systemImage: "heart.text.square.fill") }
                .tag(Navigator.Tab.status)
            HerView()
                .tabItem { Label("Her", systemImage: "sparkles") }
                .tag(Navigator.Tab.her)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(Navigator.Tab.more)
        }
    }
}

/// While the app finds the server: her own face, half awake, breathing, and a line in her voice.
/// The face is a bundled SVG (emotions/), so it shows with no server at all.
struct WakingView: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var slow = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 20) {
                BundledFace(name: slow ? "sleepy" : "drowsy")
                    .frame(width: 180, height: 180)
                    .scaleEffect(breathing ? 1.03 : 0.97)
                    .opacity(breathing ? 1 : 0.85)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathing)
                Text(slow ? "She’s taking her time…" : "Waking her up…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: slow)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slow ? "Haru is taking her time to wake up" : "Haru is waking up")
            // What the last ask came back with, and a way off this screen that does not need her.
            if let problem = session.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Sign in again") { session.signedIn = false }
                    .font(.footnote)
            }
        }
        .onAppear { breathing = true }
        // A slow server reads as her being slow to wake, not as the app being stuck.
        .task { try? await Task.sleep(for: .seconds(8)); slow = true }
    }
}

/// One of her bundled faces (Haru/Resources/emotions/<name>.svg), drawn by a still, transparent web view.
struct BundledFace: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.underPageBackgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != name,
              let file = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "emotions"),
              let svg = try? Data(contentsOf: file) else { return }
        context.coordinator.shown = name
        // A bare SVG document is laid out on a 980 px viewport and cropped; a page sized to the
        // view shows the whole face, on nothing.
        let page = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
            + "<body style='margin:0;background:transparent'><img style='display:block;width:100vw;height:100vh;object-fit:contain'"
            + " src='data:image/svg+xml;base64,\(svg.base64EncodedString())'></body>"
        view.loadHTMLString(page, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown: String? }
}
