import SwiftUI

@MainActor final class HaruRuntime {
    static let shared = HaruRuntime()
    let session: Session
    let chat: ChatStore
    let locator: Locator
    private init() {
        session = Session()
        chat = ChatStore(session: session)
        locator = Locator(session: session)
    }

@main
struct HaruApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var chat: ChatStore
    @State private var locator: Locator

    init() {
        let runtime = HaruRuntime.shared
        let session = runtime.session
        _session = State(initialValue: session)
        _chat = State(initialValue: runtime.chat)
        _locator = State(initialValue: runtime.locator)
        // Must happen before launch finishes, which is here.
        Refresh.register(session: session)
    }

    var body: some Scene {
        WindowGroup {
            appContent
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background:
                PhoneTools.shared.activity(foreground: false)
                Refresh.schedule()
                locator.rest()
            case .active:
                PhoneTools.shared.activity(foreground: true)
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

    private var appContent: some View {
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
