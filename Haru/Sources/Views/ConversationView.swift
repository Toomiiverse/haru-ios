import SwiftUI

struct ConversationView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var roleplay = RoleplayStore()
    @State private var chooseCharacter = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Conversation mode", selection: Binding(
                get: { roleplay.state?.mode ?? "ai" },
                set: { mode in
                    if mode == "character", roleplay.state?.character == nil { chooseCharacter = true }
                    else { Task { _ = await roleplay.mode(mode, session.client) } }
                }
            )) {
                Text("AI").tag("ai")
                Text("Character").tag("character")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(roleplay.state == nil || roleplay.waiting || chat.busy || chat.call != nil || chat.micOn)
            .accessibilityHint("Switch between Haru and Venice character roleplay")
            if roleplay.state?.mode == "character" {
                CharacterChatView(store: roleplay, chooseCharacter: $chooseCharacter)
            } else { ChatView() }
        }
        .background(Color("LaunchBackground"))
        .task(id: session.baseURLString) { await roleplay.load(session.client) }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await roleplay.load(session.client) } }
        }
        .sheet(isPresented: $chooseCharacter) { CharacterPicker(store: roleplay) }
        .alert("Character mode", isPresented: Binding(get: { roleplay.problem != nil }, set: { if !$0 { roleplay.problem = nil } })) {
            Button("OK") { roleplay.problem = nil }
        } message: { Text(roleplay.problem ?? "") }
    }
}

struct CharacterChatView: View {
    @Environment(Session.self) private var session
    var store: RoleplayStore
    @Binding var chooseCharacter: Bool
    @State private var draft = ""
    @State private var newScene = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Roleplay through Venice · Separate scene history")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = store.state?.error {
                    Text(issue).font(.footnote).foregroundStyle(.orange)
                        .padding(.horizontal, 16).accessibilityLabel("Unconfirmed character reply: " + issue)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if store.state?.messages.isEmpty != false {
                                ContentUnavailableView("Set the scene", systemImage: "theatermasks", description: Text("Talk to \(store.state?.character?.name ?? "your character") or describe where the story begins."))
                            }
                            ForEach(store.state?.messages ?? []) { message in
                                HStack {
                                    if message.role == "user" { Spacer(minLength: 36) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.role == "user" ? "You" : store.state?.character?.name ?? "Character")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(message.content).textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .background(message.role == "user" ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                                    if message.role != "user" { Spacer(minLength: 36) }
                                }.id(message.id)
                            }
                            if store.waiting { HStack { ProgressView(); Text("Waiting for the character…").foregroundStyle(.secondary) } }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(.horizontal, 16)
                    }
                    .refreshable { await store.load(session.client) }
                    .onChange(of: store.state?.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Set the scene…", text: $draft, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.roundedBorder)
                    Button {
                        let text = draft
                        Task { if await store.send(text, session.client), draft == text { draft = "" } }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .accessibilityLabel("Send roleplay message")
                    .disabled(store.waiting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 8000)
                }.padding(.horizontal, 16)
                Text("Typed roleplay. Calls and Haru’s voice stay in AI mode.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            .navigationTitle(store.state?.character?.name ?? "Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Characters") { chooseCharacter = true }.disabled(store.waiting) }
                ToolbarItem(placement: .topBarTrailing) { Button("New scene") { newScene = true }.disabled(store.waiting) }
            }
            .confirmationDialog("Start a new scene?", isPresented: $newScene, titleVisibility: .visible) {
                Button("New scene") { Task { await store.newScene(session.client) } }
            } message: { Text("Your current scene will be kept on the server.") }
        }
    }
}

struct CharacterPicker: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a published Venice persona. Roleplay uses Venice Uncensored and its own transcript.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.characters) { character in
                    Button {
                        Task { if await store.select(character, session.client) { dismiss() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(character.name).font(.headline)
                                if character.adult { Text("Adult").font(.caption).foregroundStyle(.secondary) }
                                if store.state?.character?.slug == character.slug { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text(character.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain).disabled(store.waiting)
                }
                if store.loadingCatalog { ProgressView("Loading characters…") }
                else if store.characters.isEmpty { Text("No characters found. Try another name or tag.").foregroundStyle(.secondary) }
                if store.hasMore { Button("Load more") { Task { await store.more(session.client) } }.disabled(store.loadingCatalog) }
            }
            .navigationTitle("Venice characters")
            .searchable(text: $search, prompt: "Name or tag")
            .onSubmit(of: .search) { Task { await store.catalog(session.client, search: search) } }
            .onChange(of: search) { _, now in if now.isEmpty { Task { await store.catalog(session.client, search: "") } } }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await store.catalog(session.client, search: search) }
        }
    }
}
