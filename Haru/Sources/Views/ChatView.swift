import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A snapshot owned by the screen, not by a row in the lazy transcript. The
/// keyboard or a history refresh may recycle that row while an editor is open.
private enum ChatFeedback: Identifiable {
    case hearing(Entry)
    case tuning(Entry)

    var id: String {
        switch self {
        case .hearing(let entry): return "hearing:" + entry.id
        case .tuning(let entry): return "tuning:" + entry.id
        }
    }
}

struct ChatView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(Navigator.self) private var nav
    @Environment(\.scenePhase) private var phase
    @State private var draft = ""
    @GestureState private var holdingTalk = false
    /// What was just sent and when, so a dictation transcript that lands in
    /// the box after the send is known for what it is.
    @State private var lastSent: (text: String, at: Date)?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var feedback: ChatFeedback?
    @State private var photo: PhotosPickerItem?
    @State private var stageTall = true
    /// Typing: she peeks over the transcript while the plate makes room.
    @State private var compact = false
    /// The status bar and title, which the stage now runs up behind.
    @State private var topInset: CGFloat = 0
    /// Where things stand with her, for the plate across the seam.
    @State private var standing: Standing?
    @AppStorage("stage.zoom") private var stageZoom = 1.0
    @AppStorage("stage.lift") private var stageLift = 0.0
    @FocusState private var typing: Bool
    /// Four minutes: she is being carried around, not watched. Anything faster
    /// reads as pestering, and the spacing on her side would refuse it anyway.
    private let poll = Timer.publish(every: 240, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    stageView
                    transcript
                    composer
                }
                // Her stage runs up behind the status bar and the title, so
                // the top of the screen is her ground, not a bar over it.
                .ignoresSafeArea(edges: .top)
                .onAppear { topInset = geo.safeAreaInsets.top }
                .onChange(of: geo.safeAreaInsets.top) { _, now in topInset = now }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshChat() }
                    } label: { Label("Refresh chat", systemImage: "arrow.clockwise") }
                    .disabled(chat.busy || chat.loading || chat.call != nil)
                    .accessibilityHint("Reload messages from the server")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task {
            await chat.load()
            await chat.askIfSheHasSomethingToSay()
            await refreshStanding()
        }
        .onChange(of: chat.lastReply?.id) { _, _ in
            Task { await refreshStanding() }
        }
        .onReceive(poll) { _ in
            Task { await chat.askIfSheHasSomethingToSay() }
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { chat.holdCallInput(false); return }
            Task {
                // Re-read the day unless she is mid-answer, when the stream on
                // screen is newer than anything the server would hand back.
                if !chat.busy { await chat.load() }
                await chat.askIfSheHasSomethingToSay()
                await refreshStanding()
            }
        }
        // haru://talk — from a Shortcut, the Action button, Safari: open the ear.
        .onChange(of: nav.wantsTalk, initial: true) { _, wanted in
            guard wanted else { return }
            nav.wantsTalk = false
            if !chat.micOn { Task { await chat.toggleMic() } }
        }
        // haru://call — the Call Haru shortcut, a Vocal Shortcut: straight into a call.
        .onChange(of: nav.wantsCall, initial: true) { _, wanted in
            guard wanted else { return }
            nav.wantsCall = false
            if chat.call == nil { Task { await chat.holdMic() } }
        }
        // Typing: she leans over the transcript; leaving the keyboard restores roaming.
        // Picking a line to answer is the start of typing the answer.
        .onChange(of: chat.replyingTo?.id) { _, id in
            if id != nil { typing = true }
        }
        .onChange(of: typing) { _, now in
            withAnimation(.easeInOut(duration: 0.3)) { compact = now }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await importCaptured(image) } }
                .ignoresSafeArea()
        }
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
        .sheet(item: $feedback) { target in
            switch target {
            case .hearing(let entry): TeachSheet(heard: entry.text)
            case .tuning(let entry): TuneSheet(entry: entry)
            }
        }
        .alert("Haru", isPresented: noticeShown) {
            Button("OK") { chat.notice = nil }
        } message: {
            Text(chat.notice ?? "")
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { chat.notice != nil && feedback == nil }, set: { if !$0 && feedback == nil { chat.notice = nil } })
    }

    // MARK: Her stage

    private var stageView: some View {
        StageWebView(stage: chat.stage, client: session.client)
            .frame(height: visibleStageHeight + topInset)
            .frame(maxWidth: .infinity)
            .background(Color("LaunchBackground"))
            // Her ground dissolves into the talk rather than stopping at a line.
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color("LaunchBackground").opacity(0.6), location: 0.65),
                    .init(color: Color("LaunchBackground"), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if !compact {
                    Nameplate(standing: standing, emotion: standing?.emotion ?? chat.emotion) { nav.tab = .status }
                        .padding(.horizontal, 16)
                        .offset(y: 28)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .zIndex(1)
            .overlay(alignment: .bottom) {
                switch chat.stage.state {
                case .loading(let what):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(what).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.bottom, 64)
                case .failed(let why):
                    Text("She is not moving — \(why).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 64)
                case .alive:
                    EmptyView()
                }
            }
            // Tapped mid-line, she stops talking; quiet, the tap sizes her stage as before.
            .onTapGesture {
                if chat.tapToHush() { return }
                chat.stage.tap()
                withAnimation(.easeInOut(duration: 0.25)) { stageTall.toggle() }
            }
            .onLongPressGesture { chat.stage.reload() }
            .onAppear { frameStage() }
            .onChange(of: stageZoom) { _, _ in frameStage() }
            .onChange(of: stageLift) { _, _ in frameStage() }
            .onChange(of: topInset) { _, _ in frameStage() }
            .onChange(of: stageTall) { _, _ in frameStage() }
            .onChange(of: compact) { _, _ in frameStage() }
            .onChange(of: chat.stage.state) { _, now in
                if case .alive = now { frameStage() }
            }
    }

    /// The part of the stage below the title.
    private var visibleStageHeight: CGFloat { compact ? 112 : stageTall ? 260 : 130 }

    /// The page centres her in the whole stage, part of which is under the
    /// title; the lift moves her down by a little over half the covered inset
    /// so she sits in the middle of what can be seen with air above her
    /// heart. Lift is a share of the stage, up positive, as the page reads it.
    private func refreshStanding() async {
        if let now: Standing = try? await session.client.get("/api/status") {
            standing = now
            Shared.publish(standing: now)
            // Asleep: her sleeping face, held. Awake again: the face she rests on.
            let wasAsleep = chat.herAsleep
            chat.herAsleep = now.asleep == true
            if now.asleep == true { chat.stage.express("sleepy") }
            else if wasAsleep { chat.emotion = now.emotion; chat.stage.express(now.face) }
        }
    }

    private func frameStage() {
        let total = visibleStageHeight + topInset
        let under = total > 0 ? (topInset * 0.55) / total : 0
        // Compact: her head peeks over the transcript at a readable size.
        chat.stage.frame(zoom: stageZoom, lift: stageLift - under, scale: 1, peek: compact)
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
        switch chat.callState {
        case .connecting: return "calling…"
        case .listening: return "on a call"
        case .thinking: return "thinking…"
        case .speaking: return "talking"
        case .off: break
        }
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
                        EntryView(entry: entry, isLast: entry.id == chat.lastReply?.id,
                                  onTeach: { feedback = .hearing($0) }, onTune: { feedback = .tuning($0) })
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.top, compact ? 8 : 44)
                .padding(.bottom, 8)
            }
            .background(
                LinearGradient(stops: [
                    .init(color: Color("LaunchBackground"), location: 0),
                    .init(color: Color(uiColor: .systemBackground), location: 0.4),
                ], startPoint: .top, endPoint: .bottom)
            )
            .refreshable { await refreshChat() }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.entries.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.entries.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onTapGesture { typing = false }
        }
    }

    private func refreshChat() async {
        guard !chat.busy, !chat.loading, chat.call == nil else { return }
        await chat.load()
        await refreshStanding()
    }

    // MARK: Composer

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.staged.isEmpty
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if chat.callHoldSupported {
                Toggle("Hold to talk", isOn: Binding(get: { chat.callManualInput }, set: { chat.setCallManualInput($0) }))
                    .font(.footnote).padding(.horizontal, 12).disabled(chat.callModePending)
                if chat.callManualInput {
                    Text(chat.callInputHeld ? "Listening — release to send" : "Hold here to talk")
                        .frame(maxWidth: .infinity).padding(12)
                        .background(chat.callInputHeld ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).updating($holdingTalk) { _, held, _ in held = true })
                        .onChange(of: holdingTalk) { _, held in chat.holdCallInput(held) }
                        .onDisappear { chat.holdCallInput(false) }
                        .accessibilityLabel("Hold to speak; release to send")
                        .accessibilityAction(named: "Start speaking") { chat.holdCallInput(true) }
                        .accessibilityAction(named: "Send speech") { chat.holdCallInput(false) }
                        .padding(.horizontal, 12)
                }
            }
            if let target = chat.replyingTo { replyBar(target) }
            if !chat.staged.isEmpty { chips }
            if chat.talkState != .off || chat.callState != .off || chat.standby { talkPill }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    if CameraPicker.available {
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    }
                    Button { showPhotos = true } label: { Label("Photo", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .padding(.bottom, 6)

                TextField("Say something", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .onChange(of: draft) { _, now in
                        // The words just sent, back in the box within a minute:
                        // dictation writing its transcript late. Cleared, and only
                        // ever those words — a short exact repeat is left alone.
                        if let last = lastSent, now == last.text, last.text.count >= 12, Date().timeIntervalSince(last.at) < 90 {
                            draft = ""
                            return
                        }
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
                    // A tap: one question through her ears, mic off after.
                    // A hold: a call.
                    Image(systemName: chat.micOn ? "mic.circle.fill" : "mic.circle")
                        .font(.title)
                        .foregroundStyle(micLit ? Color.red : Color.accentColor)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await chat.toggleMic() } }
                        .onLongPressGesture(minimumDuration: 0.45) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task { await chat.holdMic() }
                        }
                        .accessibilityLabel(chat.micOn ? "Stop listening" : "Ask her something; hold for a call")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Where the conversation by voice stands, and how loud the room is.
    /// Her ear is open for them: the ordinary mode awake, or a call listening.
    private var micLit: Bool { chat.talkState == .awake || chat.callState == .listening }

    private var talkPill: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.callState == .off ? "waveform" : "phone.fill")
                .foregroundStyle(micLit ? .red : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: micLit)
            Text(talkLabel).font(.footnote).foregroundStyle(.secondary)
            ProgressView(value: chat.audio.level).tint(micLit ? .red : .secondary)
        }
        .padding(.horizontal, 12)
    }

    private var talkLabel: String {
        let echo = chat.audio.echoCancelled ? "" : " · no echo cancelling"
        switch chat.callState {
        case .connecting: return "Calling her…"
        case .listening: return (chat.callManualInput ? "Microphone sent only while held" : "Start each request with Haru") + echo
        case .thinking: return "Thinking…"
        case .speaking: return chat.callFiller.map { "“\($0)”" } ?? (chat.callManualInput ? "Speaking… hold to interrupt" : "Speaking… say Haru to cut in")
        case .off: break
        }
        switch chat.talkState {
        case .asleep: return "Say “Hey Haru”" + echo
        case .awake: return (chat.askingOnce ? "Listening — ask her one thing" : "Listening…") + echo
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking… talk over her to cut in"
        case .off: break
        }
        if chat.standby {
            if chat.standbyPaused { return "Standby paused — reopen the app to listen" }
            if chat.standbyAsleep { return "Standby — \(chat.standbyLine)" }
            return "Standby — say “Hey Haru”, even locked"
        }
        return ""
    }

    /// The line she is being answered on, above the box, with a way out of it.
    private func replyBar(_ target: Entry) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to Haru")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(ChatStore.excerpt(of: target.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { chat.replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Stop replying to that line")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.staged) { file in
                    if let preview = file.preview, let image = UIImage(data: preview) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button { Task { await chat.discard(file) } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.65))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("Remove picture")
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                    } else {
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
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Doing things

    private func sendDraft() async {
        // Dictation still running when send is tapped writes its final
        // transcript back into the box after the box has been cleared, so the
        // words just sent sit there as if unsent (2026-09-06). Ending the input
        // session first commits them; the box is then read whole and emptied.
        if Responding.first?.textInputMode?.primaryLanguage == "dictation" {
            typing = false
            try? await Task.sleep(for: .milliseconds(150))
            typing = true
        }
        let text = draft
        draft = ""
        lastSent = (text, Date())
        let sent = await chat.send(text)
        if !sent { lastSent = nil; draft = text }
    }

    /// Straight off the camera: the same JPEG, sized the same way, as a picture
    /// from the library.
    private func importCaptured(_ image: UIImage) async {
        guard let jpeg = image.scaled(toFit: 2048).jpegData(compressionQuality: 0.85) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        await chat.attach(name: "camera-\(stamp).jpg", data: jpeg, type: "image/jpeg")
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

/// A picture in one of his bubbles: what the phone sent, or her kept copy.
struct SentPicture: View {
    let picture: Picture
    @Environment(ChatStore.self) private var chat
    @State private var image: UIImage?
    @State private var shown = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .blur(radius: picture.isPrivate && !shown ? 22 : 0)
                    .overlay {
                        if picture.isPrivate && !shown {
                            Text("tap to look")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture { if picture.isPrivate { shown = true } }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.15))
                    .frame(width: 160, height: 120)
                    .overlay { Image(systemName: "photo") }
            }
        }
        .task(id: picture.id) {
            if let data = picture.data { image = UIImage(data: data); return }
            guard let saved = picture.saved, let data = await chat.picture(saved: saved) else { return }
            image = UIImage(data: data)
        }
    }
}

struct EntryView: View {
    let entry: Entry
    let isLast: Bool
    let onTeach: (Entry) -> Void
    let onTune: (Entry) -> Void
    @Environment(ChatStore.self) private var chat
    /// How far her bubble has been pulled towards a reply.
    @State private var drag: CGFloat = 0

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
                ForEach(entry.pictures) { picture in
                    SentPicture(picture: picture)
                }
                if let quote = entry.quote {
                    // The line of hers this answers, so the bubble reads the way it was meant.
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.7))
                            .frame(width: 3)
                        Text(quote)
                            .font(.caption)
                            .lineLimit(2)
                            .opacity(0.9)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                if !entry.attachmentNames.isEmpty {
                    Label(entry.attachmentNames.joined(separator: ", "), systemImage: "paperclip").font(.footnote)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
            // What she heard is what is in the bubble; when it is wrong, this
            // is where she is told. Offered on every bubble of theirs, since
            // only they know which ones were spoken.
            .contextMenu {
                if !entry.text.isEmpty {
                    Button { onTeach(entry) } label: { Label("She misheard me", systemImage: "ear") }
                }
            }
        }
    }

    /// The colour of the face she is pulling, for the words she leans on.
    private var tint: Color {
        let mood = MoodLook.tint(for: chat.emotion)
        return mood == .secondary ? Color.accentColor : mood
    }

    private var hers: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Her own pictures. They were only ever drawn in `mine`, so a
            // picture she drew arrived, decoded, and was thrown away.
            ForEach(entry.pictures) { picture in
                SentPicture(picture: picture)
            }
            if entry.waiting && entry.text.isEmpty {
                bubble { ProgressView().controlSize(.small) }
            } else {
                ForEach(Array(entry.parts.enumerated()), id: \.offset) { _, part in
                    bubble { Text(Lively.text(part, tint: tint)).textSelection(.enabled) }
                        .contextMenu {
                            if repliable {
                                Button { chat.replyingTo = entry } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                                }
                            }
                            Button { UIPasteboard.general.string = part } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            if entry.serverID != nil && !entry.aside && !entry.waiting { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: drag)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeToReply)
    }

    /// Any line of hers that has finished arriving — a reply, or one she pushed.
    private var repliable: Bool { entry.kind == .her && !entry.waiting && !entry.text.isEmpty }

    /// A swipe to the right on her bubble answers that line. Simultaneous, and only
    /// when mostly sideways, so scrolling the day still scrolls.
    private var swipeToReply: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard repliable, value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                drag = min(value.translation.width, 64)
            }
            .onEnded { value in
                let sideways = abs(value.translation.width) > abs(value.translation.height) * 1.5
                if repliable, sideways, value.translation.width > 56 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    chat.replyingTo = entry
                }
                withAnimation(.spring(duration: 0.25)) { drag = 0 }
            }
    }

    private func bubble<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.28), lineWidth: 1))
                .modifier(Shimmer(tint: tint, on: isLast))
                .clipShape(RoundedRectangle(cornerRadius: 18))
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
            // A thumb is for her; this is for him. It goes to the tuning log on
            // the desk and nowhere near her prompt, so it is offered on every
            // reply and leaves no mark on the bubble.
            Button { onTune(entry) } label: { Image(systemName: "square.and.pencil") }
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

/// The first responder, found the one way UIKit allows from here: an action
/// sent to nobody lands on it, and it reports itself.
@MainActor
private enum Responding {
    private static weak var found: UIResponder?
    static var first: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.haruReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    static func note(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func haruReportFirstResponder() { Responding.note(self) }
}
