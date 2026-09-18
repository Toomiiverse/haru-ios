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
                // A control's intent can land after the app is already in front.
                .onReceive(NotificationCenter.default.publisher(for: Shared.asked)) { _ in
                    if phase == .active || Shared.waitingAsk == .hangUp { takeAsk() }
                }
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background:
                Refresh.schedule()
                locator.rest()
            case .active:
                locator.wake()
                Shared.publish(base: session.client.base)
                Health.shared.wake()
                Reminders.shared.wake()
                Push.register()
                Task { await Push.sync(session) }
                takeAsk()
                chat.refreshLive()
                Task { await chat.standbyOnActive() }
            default: break
            }
        }
    }

    /// What a control asked for (Shared.ask), now that the app is in front and
    /// may use the microphone.
    private func takeAsk() {
        switch Shared.takeAsk() {
        case .call?:
            Navigator.shared.tab = .chat
            Navigator.shared.wantsCall = true
        case .standbyOn?: Task { await chat.setStandby(true) }
        case .standbyOff?: Task { await chat.setStandby(false) }
        case .hangUp?: chat.endCall()
        case nil: break
        }
    }
}
