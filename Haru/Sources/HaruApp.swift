import SwiftUI

@main
struct HaruApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
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
        Audio.configureSession(listening: false)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(chat)
                .environment(locator)
                .environment(Navigator.shared)
                .onOpenURL { Navigator.shared.open($0) }
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background: Refresh.schedule()
            case .active:
                locator.wake()
                Shared.publish(base: session.client.base)
                Health.shared.wake()
                Reminders.shared.wake()
                Push.register()
                Task { await Push.sync(session) }
                Task { await chat.standbyOnActive() }
            default: break
            }
        }
    }
}
