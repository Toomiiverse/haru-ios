import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var roleplay = RoleplayStore()
    @State private var chooseCharacter = false
    @State private var showReferences = false

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
            .accessibilityHint("Switch between Haru and your custom characters")
            Button("Saved context for Haru") { showReferences = true }.font(.caption).padding(.bottom, 4)
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
        .sheet(isPresented: $showReferences) { HaruReferenceLibrary(store: roleplay) }
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
    @State private var saveContext = false
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Venice · \(store.state?.model ?? "") · Separate scene history")
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
                    .refreshable { await refreshChat() }
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
                ToolbarItem(placement: .bottomBar) { Button("Save chat for Haru") { saveContext = true }.disabled(store.waiting || store.state?.messages.isEmpty != false) }
                ToolbarItem(placement: .topBarLeading) { Button("My Characters") { chooseCharacter = true }.disabled(store.waiting) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refreshChat() } } label: { Label("Refresh chat", systemImage: "arrow.clockwise") }
                        .disabled(refreshing)
                        .accessibilityHint("Reload messages and check the existing reply")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("New scene") { newScene = true }.disabled(store.waiting) }
            }
            .sheet(isPresented: $saveContext) { SaveSceneReference(store: store) }
            .confirmationDialog("Start a new scene?", isPresented: $newScene, titleVisibility: .visible) {
                Button("New scene") { Task { await store.newScene(session.client) } }
            } message: { Text("Your current scene will be kept on the server.") }
        }
    }

    private func refreshChat() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.load(session.client)
    }
}

struct CharacterPicker: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var search = ""
    @State private var editor: CharacterDraft?
    @State private var deleting: VeniceCharacter?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your private characters, with their own creator settings and Venice AI models.").font(.footnote).foregroundStyle(.secondary)
                    Button { editor = CharacterDraft() } label: { Label("Create character", systemImage: "plus.circle.fill") }.disabled(store.savingProfile)
                }
                ForEach(store.myCharacters.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }) { character in
                    HStack {
                        Button {
                            Task { if await store.select(character, session.client) { dismiss() } }
                        } label: {
                            HStack(alignment: .top) {
                                CharacterAvatar(data: character.creator?.avatarData ?? "").frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(character.name).font(.headline)
                                    Text(character.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                    Text(character.model).font(.caption2).foregroundStyle(.secondary)
                                    if !character.tags.isEmpty { Text(character.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.buttonStyle(.plain).disabled(store.waiting || store.savingProfile)
                        Spacer()
                        Menu {
                            Button("Edit in My Creator") { editor = CharacterDraft(character) }
                            Button("Delete character", role: .destructive) { deleting = character }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Manage " + character.name)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = character }
                        Button("Edit") { editor = CharacterDraft(character) }.tint(.blue)
                    }
                }
                if store.myCharacters.isEmpty { Text("Create your first character to begin.").foregroundStyle(.secondary) }
            }
            .navigationTitle("My Characters")
            .searchable(text: $search, prompt: "Find your character")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await store.library(session.client) }
            .sheet(item: $editor) { draft in CharacterEditor(store: store, initial: draft) }
            .confirmationDialog("Delete this character?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete character", role: .destructive) {
                    if let character = deleting { Task { _ = await store.deleteProfile(character, session.client) } }
                    deleting = nil
                }
            } message: { Text("The character leaves your library. Existing scenes and any context explicitly saved for Haru are kept.") }
        }
    }
}

struct CharacterAvatar: View {
    var data: String
    var body: some View {
        Group {
            if let base64 = data.split(separator: ",", maxSplits: 1).last, let bytes = Data(base64Encoded: String(base64)), let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.square").resizable().scaledToFit().padding(8).foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
struct CharacterDraft: Identifiable {
    let id: String
    let revision: Int
    var name: String
    var description: String
    var instructions: String
    var background: String
    var creator: CreatorFields
    init(_ character: VeniceCharacter? = nil) {
        id = character?.profileId ?? UUID().uuidString
        revision = character?.profileRevision ?? 0
        name = character?.name ?? ""
        description = character?.description ?? ""
        instructions = character?.instructions ?? ""
        background = character?.background ?? ""
        creator = character?.creator ?? CreatorFields()
    }
}
struct CharacterEditor: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var draft: CharacterDraft
    @State private var section = "General"
    @State private var memoryTab = "Documents"
    @State private var insightGroup = "character"
    @State private var issue: String?
    @State private var importing = false
    @State private var importMemory = false
    @State private var documentWorking = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingModel = false
    @State private var auxiliaryId: String?
    init(store: RoleplayStore, initial: CharacterDraft) { self.store = store; _draft = State(initialValue: initial) }
    private var busy: Bool { store.savingProfile || store.creatorWorking || documentWorking }
    private var valid: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.name.count <= 120 && !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.instructions.count <= 6000 && draft.description.count <= 1000 && draft.background.count <= 6000 }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Creator section", selection: $section) { ForEach(["General", "Instructions", "Context", "Memories", "Insights", "Settings"], id: \.self) { Text($0) } }
                if section == "General" { general }
                if section == "Instructions" { instructions }
                if section == "Context" { context }
                if section == "Memories" { memories }
                if section == "Insights" { insights }
                if section == "Settings" { settings }
                if busy { HStack { ProgressView(); Text("Working…") } }
                if let issue { Text(issue).foregroundStyle(.orange) }
                if auxiliaryId != nil && !busy { Button("Start a new creator attempt") { auxiliaryId = nil; issue = nil } }
            }
            .navigationTitle("My Creator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || busy) }
            }
            .interactiveDismissDisabled(busy)
            .task { await store.loadModels(session.client) }
            .sheet(isPresented: $choosingModel) { VeniceModelPicker(store: store, model: $draft.creator.model) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .text]) { result in importFile(result) }
            .onChange(of: photo) { _, value in
                guard let value else { return }
                Task {
                    do {
                        guard let data = try await value.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                        let factor = min(1, 512 / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { throw URLError(.cannotDecodeContentData) }
                        draft.creator.avatarData = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                    } catch { issue = error.localizedDescription }
                }
            }
        }
    }
    private var general: some View {
        Group {
            Section("Avatar") {
                CharacterAvatar(data: draft.creator.avatarData).frame(width: 100, height: 100)
                PhotosPicker("Choose image", selection: $photo, matching: .images)
                if !draft.creator.avatarData.isEmpty { Button("Remove image") { draft.creator.avatarData = "" } }
            }
            Section("Name") { TextField("Character name", text: $draft.name) }
            Section("Description") { TextField("Who would you like to create?", text: $draft.description, axis: .vertical).lineLimit(3...6) }
            Button("Auto-generate character") { generate() }.disabled(busy || draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Section("Tags") { TextField("Separate tags with commas", text: Binding(get: { draft.creator.tags.joined(separator: ", ") }, set: { draft.creator.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } })) }
        }
    }
    private var instructions: some View {
        Group {
            Section("Intro statement (optional)") { TextField("Their opening line", text: $draft.creator.intro, axis: .vertical).lineLimit(2...5) }
            Section { TextEditor(text: $draft.instructions).frame(minHeight: 180).accessibilityLabel("Character instructions") } header: { Text("Instructions") } footer: { Text("Personality, speaking style, and roleplay behavior · up to 6,000 characters.") }
            Section("Custom system prompts") {
                ForEach(draft.creator.systemPrompts.indices, id: \.self) { index in
                    TextField("Additional prompt", text: $draft.creator.systemPrompts[index], axis: .vertical).lineLimit(3...8)
                    Button("Remove prompt", role: .destructive) { draft.creator.systemPrompts.remove(at: index) }
                }
                Button("Add custom system prompt") { draft.creator.systemPrompts.append("") }.disabled(draft.creator.systemPrompts.count >= 8)
            }
        }
    }
    private var context: some View {
        Group {
            Section("Background and setting") { TextEditor(text: $draft.background).frame(minHeight: 130).accessibilityLabel("Character background") }
            Section("Context documents") {
                documentList(draft.creator.documents, memory: false)
                Button("Upload PDF, TXT, or MD") { importMemory = false; importing = true }.disabled(busy || draft.creator.documents.count >= 8)
                Text("Up to 5 MB per file and 60,000 extracted characters. Context must fit the selected model; scanned PDFs need OCR first.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var memories: some View {
        Group {
            Picker("Character memory", selection: $memoryTab) { ForEach(["Documents", "Notes", "Extraction"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if memoryTab == "Documents" {
                Section("Character memory documents") {
                    documentList(draft.creator.memoryDocuments, memory: true)
                    Button("Upload to character memory") { importMemory = true; importing = true }.disabled(busy || draft.creator.memoryDocuments.count >= 8)
                }
            } else if memoryTab == "Notes" {
                Section("Editable memory notes") { TextEditor(text: $draft.creator.notes).frame(minHeight: 220).accessibilityLabel("Character memory notes") }
            } else {
                Section("Extraction focus") { TextEditor(text: $draft.creator.extraction).frame(minHeight: 150).accessibilityLabel("Memory extraction focus") }
                Button("Extract notes from current character scene") { extract() }.disabled(busy || store.state?.messages.isEmpty != false)
                Text("Drafts editable notes from confirmed dialogue. Nothing is committed until you save this character.").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Character memory stays separate from Haru. Use Save chat for Haru to share selected dialogue with her.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var insights: some View {
        Group {
            Toggle("Use character insights", isOn: $draft.creator.insightsEnabled)
            Text("Editable profiles for this roleplay. Haru learns only from references you explicitly save for her.").font(.footnote).foregroundStyle(.secondary)
            if draft.creator.insightsEnabled {
                Button("Draft insights from current scene") { draftInsights() }.disabled(busy || store.state?.messages.isEmpty != false)
                Picker("Profile", selection: $insightGroup) { Text("User").tag("user"); Text("Character").tag("character"); Text("Relationship").tag("relationship") }.pickerStyle(.segmented)
                ForEach(insightFields, id: \.0) { key, label in
                    Section(label) { TextField(label, text: Binding(get: { draft.creator.insights[insightGroup]?[key] ?? "" }, set: { draft.creator.insights[insightGroup, default: [:]][key] = $0 }), axis: .vertical).lineLimit(2...5) }
                }
            }
        }
    }
    private var insightFields: [(String, String)] {
        switch insightGroup {
        case "user": return [("basicInfo","Basic info"),("demographics","Demographics"),("physicalAppearance","Physical appearance"),("profession","Profession"),("personality","Personality"),("preferences","Preferences")]
        case "relationship": return [("formality","Formality"),("preferredFormats","Preferred formats"),("tone","Tone"),("verbosity","Verbosity"),("trustLevel","Trust level"),("perceivedRole","Perceived role"),("sharedHistorySummary","Shared history summary"),("commonTasks","Common tasks"),("sharedTopics","Shared topics"),("insideReferences","Inside references")]
        default: return [("name","Name"),("nickname","Nickname"),("tagline","Tagline"),("originStory","Origin story"),("capabilities","Capabilities"),("boundaries","Boundaries"),("natureOfBeing","Nature of being"),("relationshipToTruth","Relationship to truth"),("emotionalStance","Emotional stance"),("coreValues","Core values"),("personalityTraits","Personality traits")]
        }
    }
    private var settings: some View {
        Group {
            Section("Venice AI") {
                Button { choosingModel = true } label: { LabeledContent("Model", value: store.models.first { $0.id == draft.creator.model }?.name ?? draft.creator.model) }
                Button("Refresh model list") { Task { await store.loadModels(session.client) } }
            }
            Section("Reply style") {
                Slider(value: $draft.creator.temperature, in: 0...1.5) { Text("Creativity") }
                Text("Creativity: \(draft.creator.temperature, specifier: "%.2f")")
                Stepper("Maximum reply tokens: \(draft.creator.maxTokens)", value: $draft.creator.maxTokens, in: 128...4096, step: 128)
            }
            Text("Saved privately in Haru. All character replies use your selected Venice model. Editing creates a new character version; selecting it starts a separate scene.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func documentList(_ documents: [CreatorDocument], memory: Bool) -> some View {
        ForEach(documents) { document in
            DisclosureGroup(document.name) {
                Text("\(document.text.count) characters").font(.caption).foregroundStyle(.secondary)
                Text(document.text).lineLimit(8).font(.footnote).textSelection(.enabled)
                Button("Remove document", role: .destructive) {
                    if memory { draft.creator.memoryDocuments.removeAll { $0.name == document.name } }
                    else { draft.creator.documents.removeAll { $0.name == document.name } }
                }
            }
        }
    }
    private func importFile(_ result: Result<URL, Error>) {
        Task {
            documentWorking = true
            defer { documentWorking = false }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5_000_000 else { throw NSError(domain: "My Creator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a document smaller than 5 MB."]) }
                let doc = try await store.importDocument(Data(contentsOf: url), name: url.lastPathComponent, client: session.client)
                if importMemory { draft.creator.memoryDocuments.removeAll { $0.name == doc.name }; draft.creator.memoryDocuments.append(doc) }
                else { draft.creator.documents.removeAll { $0.name == doc.name }; draft.creator.documents.append(doc) }
            } catch { issue = error.localizedDescription }
        }
    }
    private func save() {
        Task {
            if await store.saveProfile(id: draft.id, revision: draft.revision, name: draft.name, description: draft.description, instructions: draft.instructions, background: draft.background, creator: draft.creator, client: session.client) != nil { dismiss() }
            else { issue = store.problem ?? "Save could not be confirmed. Your draft is still here."; store.problem = nil }
        }
    }
    private func generate() {
        Task {
            do {
                let creator = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(draft.creator))
                let id = auxiliaryId ?? UUID().uuidString
                auxiliaryId = id
                if let text = await store.auxiliary("generate", id: id, fields: ["text": .string(draft.description), "name": .string(draft.name), "description": .string(draft.description), "instructions": .string(draft.instructions), "background": .string(draft.background), "creator": creator], client: session.client) {
                    let result = try JSONDecoder().decode(GeneratedCharacter.self, from: Data(text.utf8))
                    draft.name = result.name; draft.description = result.description ?? draft.description; draft.instructions = result.instructions
                    draft.creator.intro = result.intro ?? ""; draft.creator.tags = result.tags ?? draft.creator.tags
                    auxiliaryId = nil; section = "Instructions"
                } else { issue = store.problem; store.problem = nil }
            } catch { issue = error.localizedDescription }
        }
    }
    private func draftInsights() {
        Task {
            do {
                let creator = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(draft.creator))
                let id = auxiliaryId ?? UUID().uuidString
                auxiliaryId = id
                if let text = await store.auxiliary("insight-extract", id: id, fields: ["text": .string("Draft editable insights from confirmed fictional dialogue."), "creator": creator], client: session.client) {
                    draft.creator.insights = try JSONDecoder().decode([String: [String: String]].self, from: Data(text.utf8))
                    draft.creator.insightsEnabled = true
                    auxiliaryId = nil
                } else { issue = store.problem; store.problem = nil }
            } catch { issue = error.localizedDescription }
        }
    }
    private func extract() {
        Task {
            do {
                let creator = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(draft.creator))
                let id = auxiliaryId ?? UUID().uuidString
                auxiliaryId = id
                if let notes = await store.auxiliary("extract", id: id, fields: ["text": .string("Draft character memory notes from the current confirmed scene."), "creator": creator], client: session.client) {
                    draft.creator.notes = notes; auxiliaryId = nil; memoryTab = "Notes"
                } else { issue = store.problem; store.problem = nil }
            } catch { issue = error.localizedDescription }
        }
    }
}
struct VeniceModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @Binding var model: String
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Text("Models vary in style, privacy, price, and reply time. Your Haru AI model stays unchanged.").font(.footnote).foregroundStyle(.secondary)
                ForEach(store.models.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { item in
                    Button { model = item.id; dismiss() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(item.name).font(.headline); if model == item.id { Image(systemName: "checkmark") } }
                            Text("Venice privacy: \(item.privacy) · \(item.contextTokens.formatted()) context tokens").font(.caption).foregroundStyle(.secondary)
                            Text("$\(item.inputUsdPerMillion, specifier: "%.2f") input / $\(item.outputUsdPerMillion, specifier: "%.2f") output per million tokens").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.searchable(text: $search, prompt: "Find a Venice model").navigationTitle("Venice AI")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
struct SaveSceneReference: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var id = UUID().uuidString
    @State private var label = ""
    @State private var guidance = ""
    @State private var selected: Set<String> = []
    @State private var issue: String?
    private var dialogue: [RoleplayMessage] {
        let messages = store.state?.messages ?? []
        let confirmed = Set(messages.filter { $0.role == "assistant" && !$0.id.hasPrefix("intro:") }.map { $0.id.components(separatedBy: ":")[0] })
        return messages.filter { confirmed.contains($0.id.components(separatedBy: ":")[0]) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Share selected dialogue with Haru AI as conversational and personality references. Fiction stays labeled as roleplay. You can remove these references later.").font(.footnote) }
                Section("Reference name") { TextField("For example: Warm, playful replies", text: $label) }
                Section("What should Haru learn?") { TextField("Describe the tone, personality, or references you want her to carry forward", text: $guidance, axis: .vertical).lineLimit(4...8) }
                Section("Dialogue to share") {
                    ForEach(dialogue) { message in
                        Toggle(isOn: Binding(get: { selected.contains(message.id) }, set: { if $0 { selected.insert(message.id) } else { selected.remove(message.id) } })) {
                            VStack(alignment: .leading) {
                                Text(message.role == "user" ? "You" : store.state?.character?.name ?? "Character").font(.caption).foregroundStyle(.secondary)
                                Text(message.content).font(.footnote).lineLimit(8)
                            }
                        }
                    }
                }
                Text("\(selected.count) messages selected · up to 18,000 characters per reference").font(.caption).foregroundStyle(.secondary)
                if let issue { Text(issue).foregroundStyle(.orange) }
            }.navigationTitle("Save chat for Haru")
            .onAppear { if label.isEmpty { label = store.state?.character?.name ?? "Roleplay reference" }; selected = Set(dialogue.map(\.id)) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.creatorWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.saveReference(id: id, label: label, guidance: guidance, messageIds: Array(selected), client: session.client) { dismiss() }
                            else { issue = store.problem; store.problem = nil }
                        }
                    }.disabled(store.creatorWorking || selected.isEmpty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 200 || guidance.count > 2000)
                }
            }.interactiveDismissDisabled(store.creatorWorking)
        }
    }
}
struct HaruReferenceLibrary: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    @State private var deleting: HaruReference?
    @State private var editing: HaruReference?
    var body: some View {
        NavigationStack {
            List {
                Text("Haru uses these approved notes and quoted examples in her AI conversation context. Removing a reference stops future inclusion; it does not undo previous replies.").font(.footnote).foregroundStyle(.secondary)
                ForEach(store.references) { reference in
                    DisclosureGroup(reference.label) {
                        Text(reference.guidance).font(.subheadline)
                        Text("Fictional source: " + reference.characterName).font(.caption).foregroundStyle(.secondary)
                        Text(reference.transcript).font(.footnote).textSelection(.enabled)
                        Button("Edit reference notes") { editing = reference }
                        Button("Remove from Haru context", role: .destructive) { deleting = reference }
                    }
                }
                if store.references.isEmpty { Text("No saved references yet. Open a character chat and choose Save chat for Haru.").foregroundStyle(.secondary) }
            }.navigationTitle("Haru context")
            .sheet(item: $editing) { reference in HaruReferenceEditor(store: store, reference: reference) }
            .task { await store.loadReferences(session.client) }
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Remove this reference?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Remove reference", role: .destructive) { if let reference = deleting { Task { await store.removeReference(reference, session.client) } }; deleting = nil }
            }
        }
    }
}

struct HaruReferenceEditor: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: RoleplayStore
    let reference: HaruReference
    @State private var label: String
    @State private var guidance: String
    @State private var issue: String?
    init(store: RoleplayStore, reference: HaruReference) {
        self.store = store; self.reference = reference
        _label = State(initialValue: reference.label); _guidance = State(initialValue: reference.guidance)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Reference name") { TextField("Name", text: $label) }
                Section("What should Haru learn?") { TextField("Approved personality and conversational notes", text: $guidance, axis: .vertical).lineLimit(4...8) }
                Section("Quoted dialogue") { Text(reference.transcript).font(.footnote).textSelection(.enabled) }
                if let issue { Text(issue).foregroundStyle(.orange) }
            }.navigationTitle("Edit reference")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.creatorWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await store.updateReference(reference, label: label, guidance: guidance, client: session.client) { dismiss() } else { issue = store.problem; store.problem = nil } } }
                        .disabled(store.creatorWorking || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 200 || guidance.count > 2000)
                }
            }.interactiveDismissDisabled(store.creatorWorking)
        }
    }
}
