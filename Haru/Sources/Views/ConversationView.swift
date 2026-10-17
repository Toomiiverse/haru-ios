import SwiftUI

struct ConversationView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(Navigator.self) private var nav
    @State private var code = CodeStore()
    /// Coding mode is the phone's alone: no server mode to keep, and Haru is not part of it.
    @State private var coding = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Conversation mode", selection: Binding(
                get: { coding ? "code" : "ai" },
                set: { mode in
                    if mode == "code" { coding = true } else if coding { leaveCode() }
                }
            )) {
                Text("AI").tag("ai")
                Text("Code").tag("code")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(chat.busy || chat.call != nil || chat.micOn)
            .accessibilityHint("Switch between Haru and coding with the coder")
            if coding {
                CodeView(store: code)
            } else { ChatView() }
        }
        .onChange(of: nav.wantsCode) { _, folder in
            guard let folder else { return }
            nav.wantsCode = nil
            code.pendingFolder = folder
            if coding { Task { await code.open(session.client) } } else { coding = true }
        }
        .onChange(of: code.exitRequested) { _, now in if now { leaveCode() } }
        .background(Color("LaunchBackground"))
        .onAppear { if let folder = nav.wantsCode { nav.wantsCode = nil; code.pendingFolder = folder; coding = true } }
    }

    private func leaveCode() {
        coding = false
        code.exitRequested = false
        let client = session.client
        Task { await code.leave(client) }
    }
}
