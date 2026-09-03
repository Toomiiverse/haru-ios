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
    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            StatusView()
                .tabItem { Label("Status", systemImage: "heart.text.square.fill") }
            DiaryView()
                .tabItem { Label("Diary", systemImage: "book.closed.fill") }
            HerView()
                .tabItem { Label("Her", systemImage: "sparkles") }
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
    }
}
