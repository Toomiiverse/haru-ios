import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            switch session.signedIn {
            case .none:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding her…").foregroundStyle(.secondary)
                }
                .task { await session.check() }
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
