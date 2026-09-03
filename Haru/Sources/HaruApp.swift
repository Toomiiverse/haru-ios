import SwiftUI

@main
struct HaruApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var chat: ChatStore
    @State private var locator: Locator

    init() {
        let session = Session()
        _session = State(initialValue: session)
        _chat = State(initialValue: ChatStore(session: session))
        _locator = State(initialValue: Locator(session: session))
        // Must happen before launch finishes, which is here.
        Refresh.register(session: session)
        Voice.configureSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(chat)
                .environment(locator)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background: Refresh.schedule()
            case .active: locator.wake()
            default: break
            }
        }
    }
}
