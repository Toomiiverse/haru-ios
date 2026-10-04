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
    @State private var source = "mine"
    @State private var editor: CharacterDraft?
    @State private var deleting: VeniceCharacter?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Character library", selection: $source) {
                        Text("My characters").tag("mine")
                        Text("Venice").tag("venice")
                    }.pickerStyle(.segmented)
                    Text(source == "mine" ? "Create private characters with your own personality and background. Replies run through Venice." : "Choose a published Venice persona. Roleplay uses Venice Uncensored.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if source == "mine" {
                    Button { editor = CharacterDraft() } label: { Label("Create character", systemImage: "plus.circle.fill") }
                        .disabled(store.savingProfile)
                    if store.myCharacters.isEmpty { Text("Your characters will appear here.").foregroundStyle(.secondary) }
                }
                ForEach((source == "mine" ? store.myCharacters.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) } : store.characters)) { character in
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
                    }.buttonStyle(.plain).disabled(store.waiting || store.savingProfile)
                    .swipeActions(edge: .trailing) {
                        if character.custom == true {
                            Button("Delete", role: .destructive) { deleting = character }
                            Button("Edit") { editor = CharacterDraft(character) }.tint(.blue)
                        }
                    }
                    .contextMenu {
                        if character.custom == true {
                            Button("Edit character") { editor = CharacterDraft(character) }
                            Button("Delete character", role: .destructive) { deleting = character }
                        }
                    }
                }
                if source == "venice" {
                    if store.loadingCatalog { ProgressView("Loading characters…") }
                    else if store.characters.isEmpty { Text("No characters found. Try another name or tag.").foregroundStyle(.secondary) }
                    if store.hasMore { Button("Load more") { Task { await store.more(session.client) } }.disabled(store.loadingCatalog) }
                }
            }
            .navigationTitle("Characters")
            .searchable(text: $search, prompt: "Find a character")
            .onSubmit(of: .search) { if source == "venice" { Task { await store.catalog(session.client, search: search) } } }
            .onChange(of: source) { _, now in Task { if now == "venice" { await store.catalog(session.client, search: search) } else { await store.library(session.client) } } }
            .onChange(of: search) { _, now in if now.isEmpty && source == "venice" { Task { await store.catalog(session.client, search: "") } } }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await store.library(session.client) }
            .sheet(item: $editor) { draft in CharacterEditor(store: store, initial: draft) }
            .confirmationDialog("Delete this character?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete character", role: .destructive) {
                    if let character = deleting { Task { _ = await store.deleteProfile(character, session.client) } }
                    deleting = nil
                }
            } message: { Text("The character will leave your library. Existing scenes stay on the server; active sessions return to AI mode.") }
        }
    }
}

struct CharacterDraft: Identifiable {
    let id: String
    let revision: Int
    var name: String
    var description: String
    var instructions: String
    var background: String
    init(_ character: VeniceCharacter? = nil) {
        id = character?.profileId ?? UUID().uuidString
        revision = character?.profileRevision ?? 0
        name = character?.name ?? ""
        description = character?.description ?? ""
        instructions = character?.instructions ?? ""
        background = character?.background ?? ""
    }
}

struct CharacterEditor: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var draft: CharacterDraft
    @State private var issue: String?
    init(store: RoleplayStore, initial: CharacterDraft) {
        self.store = store
        _draft = State(initialValue: initial)
    }
    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.name.count <= 120 &&
        !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.instructions.count <= 6000 &&
        draft.description.count <= 1000 && draft.background.count <= 6000
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Character name", text: $draft.name) }
                Section("Description") { TextField("A short introduction (optional)", text: $draft.description, axis: .vertical).lineLimit(2...5) }
                Section {
                    TextEditor(text: $draft.instructions).frame(minHeight: 160).accessibilityLabel("Personality and instructions")
                } header: { Text("Personality and instructions") } footer: { Text("Describe how they speak, behave, and roleplay. Required · up to 6,000 characters.") }
                Section {
                    TextEditor(text: $draft.background).frame(minHeight: 120).accessibilityLabel("Background and setting")
                } header: { Text("Background and setting") } footer: { Text("Optional lore, relationships, and the world they live in · up to 6,000 characters.") }
                Section { Text("Saved privately in your Haru library. Replies run on Venice Uncensored. Selecting an edited character starts a scene for its new version; previous scenes are kept.").font(.footnote).foregroundStyle(.secondary) }
                if !valid { Text("Enter a name and personality instructions within the field limits.").font(.footnote).foregroundStyle(.secondary) }
                if let issue { Text(issue).foregroundStyle(.orange) }
            }
            .navigationTitle(draft.revision == 0 ? "Create character" : "Edit character")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.savingProfile) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.saveProfile(id: draft.id, revision: draft.revision, name: draft.name, description: draft.description, instructions: draft.instructions, background: draft.background, client: session.client) != nil { dismiss() }
                            else { issue = store.problem ?? "Save could not be confirmed. Your draft is still here."; store.problem = nil }
                        }
                    }.disabled(!valid || store.savingProfile)
                }
            }
            .interactiveDismissDisabled(store.savingProfile)
        }
    }
}
