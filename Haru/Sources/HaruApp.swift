import SwiftUI

@main
struct HaruApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var chat: ChatStore
    @State private var locator: Locator
    @State private var local = LocalConversationStore()

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
            appContent
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background:
                local.download.pause()
                Task { await local.releaseMemory() }
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
                if !local.selected { Task { await chat.standbyOnActive() } }
            default: break
            }
        }
    }

    private var appContent: some View {
        RootView()
                .environment(session)
                .environment(chat)
                .environment(locator)
                .environment(local)
                .environment(Navigator.shared)
                .onAppear {
                    local.serverTask = { text, id in try await chat.taskForLocalConversation(text, requestID: id) }
                    local.speak = { text in if session.signedIn == true { chat.say(text, emotion: nil) } }
                    local.loadPersonality = {
                        struct Profile: Decodable { let version: Int; let instructions: String }
                        let profile: Profile = try await session.client.post("/api/local/profile")
                        guard profile.version == 1 else { throw LocalChatError.message("Unsupported local profile version.") }
                        return profile.instructions
                    }
                }
                .onOpenURL { Navigator.shared.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await local.releaseMemory() }
                }
                .onChange(of: local.selected) { _, selected in
                    if selected {
                        _ = chat.tapToHush()
                        Task { await chat.setStandby(false) }
                    } else { Task { await local.releaseMemory() } }
                }
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
        case .standbyOn?: Task { await local.releaseMemory(); await chat.setStandby(true) }
        case .standbyOff?: Task { await chat.setStandby(false) }
        case .hangUp?: chat.endCall()
        case nil: break
        }
    }
}
