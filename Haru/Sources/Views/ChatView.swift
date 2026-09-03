import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var draft = ""
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photo: PhotosPickerItem?
    @State private var stageTall = true
    @AppStorage("stage.zoom") private var stageZoom = 2.0
    @AppStorage("stage.lift") private var stageLift = 0.0
    @AppStorage("stage.motion") private var stageMotion = 0.6
    @FocusState private var typing: Bool
    /// Four minutes: she is being carried around, not watched. Anything faster
    /// reads as pestering, and the spacing on her side would refuse it anyway.
    private let poll = Timer.publish(every: 240, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stageView
                Divider()
                transcript
                composer
            }
            .toolbar { ToolbarItem(placement: .principal) { header } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            await chat.load()
            await chat.askIfSheHasSomethingToSay()
        }
        .onReceive(poll) { _ in
            Task { await chat.askIfSheHasSomethingToSay() }
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            Task {
                // Re-read the day unless she is mid-answer, when the stream on
                // screen is newer than anything the server would hand back.
                if !chat.busy { await chat.load() }
                await chat.askIfSheHasSomethingToSay()
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await importPhoto(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importFile(url) }
            }
        }
        .alert("Haru", isPresented: noticeShown) {
            Button("OK") { chat.notice = nil }
        } message: {
            Text(chat.notice ?? "")
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { chat.notice != nil }, set: { if !$0 { chat.notice = nil } })
    }

    // MARK: Her stage

    private var stageView: some View {
        StageWebView(stage: chat.stage, client: session.client)
            .frame(height: stageTall ? 300 : 150)
            .frame(maxWidth: .infinity)
            .background(Color("LaunchBackground"))
            .overlay(alignment: .bottom) {
                switch chat.stage.state {
                case .loading(let what):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(what).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.bottom, 8)
                case .failed(let why):
                    Text("She is not moving — \(why).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                case .alive:
                    EmptyView()
                }
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { stageTall.toggle() } }
            .onLongPressGesture { chat.stage.reload() }
            .onAppear { frameStage() }
            .onChange(of: stageZoom) { _, _ in frameStage() }
            .onChange(of: stageLift) { _, _ in frameStage() }
            .onChange(of: stageMotion) { _, _ in frameStage() }
            .onChange(of: chat.stage.state) { _, now in
                if case .alive = now { frameStage() }
            }
    }

    private func frameStage() {
        chat.stage.frame(zoom: stageZoom, lift: stageLift)
        chat.stage.motion(stageMotion)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            Text("Haru").font(.headline)
            Text(state).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var state: String {
        if chat.busy { return "thinking…" }
        if chat.transcribing { return "working out what you said…" }
        if chat.audio.speaking { return "talking" }
        switch chat.talkState {
        case .asleep: return "asleep — say “Hey Haru”"
        case .awake: return "listening"
        default: return chat.emotion
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.entries) { entry in
                        EntryView(entry: entry, isLast: entry.id == chat.lastReply?.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.entries.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.entries.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onTapGesture { typing = false }
        }
    }

    // MARK: Composer

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.staged.isEmpty
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !chat.staged.isEmpty { chips }
            if chat.talkState != .off { talkPill }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .padding(.bottom, 6)

                TextField("Say something", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .onChange(of: draft) { _, now in
                        if !now.isEmpty { chat.stage.attend("typing", ms: 1_800) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .focused($typing)

                if canSend {
                    Button { Task { await sendDraft() } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(chat.busy)
                } else {
                    Button {
                        if chat.talkState == .off { Task { await chat.startTalking() } } else { chat.stopTalking() }
                    } label: {
                        Image(systemName: chat.talkState == .off ? "mic.circle" : "mic.circle.fill")
                            .font(.title)
                            .foregroundStyle(chat.talkState == .awake ? Color.red : Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Where the conversation by voice stands, and how loud the room is.
    private var talkPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(chat.talkState == .awake ? .red : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: chat.talkState == .awake)
            Text(talkLabel).font(.footnote).foregroundStyle(.secondary)
            ProgressView(value: chat.audio.level).tint(chat.talkState == .awake ? .red : .secondary)
        }
        .padding(.horizontal, 12)
    }

    private var talkLabel: String {
        let echo = chat.audio.echoCancelled ? "" : " · no echo cancelling"
        switch chat.talkState {
        case .asleep: return "Say “Hey Haru”" + echo
        case .awake: return "Listening…" + echo
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking… talk over her to cut in"
        case .off: return ""
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.staged) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        Text(file.name).lineLimit(1)
                        Button { Task { await chat.discard(file) } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Doing things

    private func sendDraft() async {
        let text = draft
        draft = ""
        await chat.send(text)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            chat.notice = "That picture could not be read."
            return
        }
        // JPEG, no side longer than 2048: what her vision model reads, at a
        // size worth sending over cellular. HEIC straight off the camera is neither.
        guard let jpeg = image.scaled(toFit: 2048).jpegData(compressionQuality: 0.85) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        await chat.attach(name: "photo-\(stamp).jpg", data: jpeg, type: "image/jpeg")
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            chat.notice = "That file could not be read."
            return
        }
        guard data.count <= 50 * 1024 * 1024 else {
            chat.notice = "That file is too big to send — 50MB at most."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await chat.attach(name: url.lastPathComponent, data: data, type: type)
    }
}

// MARK: - One entry

struct EntryView: View {
    let entry: Entry
    let isLast: Bool
    @Environment(ChatStore.self) private var chat

    var body: some View {
        switch entry.kind {
        case .me: mine
        case .system:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .her: hers
        }
    }

    private var mine: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                if !entry.attachmentNames.isEmpty {
                    Label(entry.attachmentNames.joined(separator: ", "), systemImage: "paperclip").font(.footnote)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
        }
    }

    private var hers: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.waiting && entry.text.isEmpty {
                bubble { ProgressView().controlSize(.small) }
            } else {
                ForEach(Array(entry.parts.enumerated()), id: \.offset) { _, part in
                    bubble { Text(part).textSelection(.enabled) }
                }
            }
            if entry.serverID != nil && !entry.aside && !entry.waiting { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bubble<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .leading) {
                    if entry.aside {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .padding(.vertical, 6)
                    }
                }
            Spacer(minLength: 48)
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Button { Task { await chat.rate(entry, "up") } } label: {
                Image(systemName: entry.reaction == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button { Task { await chat.rate(entry, "down") } } label: {
                Image(systemName: entry.reaction == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            if isLast {
                Button { Task { await chat.retry() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .disabled(chat.busy)
    }
}

extension UIImage {
    /// The same picture with no side longer than `longest`, in pixels.
    func scaled(toFit longest: CGFloat) -> UIImage {
        let biggest = max(size.width * scale, size.height * scale)
        guard biggest > longest else { return self }
        let ratio = longest / biggest
        let target = CGSize(width: (size.width * scale * ratio).rounded(), height: (size.height * scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
