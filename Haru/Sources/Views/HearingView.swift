import SwiftUI

/// Teaching her ears from a bubble: what came back, against what was said.
/// Whisper gets the same names wrong for ever until told once, and until now
/// the only place to tell her was the desk window nobody sees. The server
/// keeps the word that differs and rewrites it on every take after this one
/// (its hearing.ts says why that is a rewrite of the transcript, not a prompt).
struct TeachSheet: View {
    let heard: String
    @Environment(ChatStore.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var meant = ""
    @State private var sending = false

    private var ready: Bool {
        let said = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        return !sending && !said.isEmpty && said != heard
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("She heard") {
                    Text(heard).foregroundStyle(.secondary)
                }
                Section {
                    TextField("What you actually said", text: $meant, axis: .vertical).lineLimit(1...5)
                } header: {
                    Text("You said")
                } footer: {
                    Text("Change only the word she got wrong. She keeps the difference and hears it right from the next thing you say.")
                }
            }
            .navigationTitle("She misheard me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Teach her") {
                        sending = true
                        Task {
                            await chat.teach(heard: heard, meant: meant.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
                    }
                    .disabled(!ready)
                }
            }
            .onAppear { if meant.isEmpty { meant = heard } }
        }
    }
}

/// What she has been taught she mishears, with how often each rule has fired.
/// Swipe one away to unteach it.
struct HearingView: View {
    @Environment(Session.self) private var session
    @State private var rules: [HearingRule] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rules.isEmpty {
                Text("Nothing yet. Long-press one of your own bubbles when she gets a word wrong.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    Text(rule.heard).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Text(rule.meant)
                    Spacer()
                    if let used = rule.used, used > 0 {
                        Text("×\(used)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let gone = offsets.map { rules[$0].heard }
                rules.remove(atOffsets: offsets)
                Task {
                    for heard in gone {
                        let _: HearingPage? = try? await session.client.post("/api/hearing/forget", ["heard": .string(heard)])
                    }
                }
            }
        }
        .navigationTitle("What she mishears")
        .task {
            if let page: HearingPage = try? await session.client.get("/api/hearing") { rules = page.corrections }
            loaded = true
        }
    }
}
