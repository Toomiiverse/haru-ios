import SwiftUI
import UniformTypeIdentifiers

struct LocalConversationView: View {
    @Environment(LocalConversationStore.self) private var local
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @State private var draft = ""
    @State private var settings = false
    @State private var clear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("Dolphin 7B · On this iPhone · Separate history")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if local.archive.messages.isEmpty {
                                ContentUnavailableView("Haru, on your iPhone", systemImage: "iphone",
                                    description: Text(local.download.ready ? "Start a conversation. Replies and this history stay on your phone." : "Download Dolphin once, then chat offline. About 3.02 GB of storage."))
                                if !local.download.ready {
                                    Button("Set up Dolphin") { settings = true }.buttonStyle(.borderedProminent)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            ForEach(local.archive.messages) { message in bubble(message) }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(.horizontal, 16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: local.archive.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: local.archive.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                if !local.status.isEmpty {
                    HStack(spacing: 8) {
                        if local.busy { ProgressView().controlSize(.small) }
                        Text(local.status).font(.caption)
                    }.foregroundStyle(.secondary)
                }
                if let problem = local.problem { Text(problem).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if let metrics = local.metrics, !local.busy {
                    Text(timing(metrics)).font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Talk to Haru…", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    if local.busy {
                        Button { local.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                            .accessibilityLabel("Stop local reply")
                    } else {
                        Button {
                            _ = chat.tapToHush()
                            if local.send(draft) { draft = "" }
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send to Dolphin on this iPhone")
                        .disabled(local.unavailable || !local.download.ready || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.call != nil || chat.micOn)
                    }
                }.padding(.horizontal, 16)
                Text("Text only. Calls, tools and synced memory use the server AI tab.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
            }
            .navigationTitle("Haru")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.signedIn != true {
                    ToolbarItem(placement: .topBarLeading) { Button("Server sign-in") { local.selected = false }.disabled(local.unavailable) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("On-device settings", systemImage: "slider.horizontal.3") { settings = true }
                        Button("Retry last reply", systemImage: "arrow.clockwise") { local.retry() }
                            .disabled(local.unavailable || !local.download.ready || local.archive.messages.last?.role != .assistant)
                        ShareLink("Export local history", item: LocalFiles.conversation)
                            .disabled(local.unavailable)
                        Button("Clear local history", role: .destructive) { clear = true }.disabled(local.unavailable)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Local conversation options")
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack { LocalModelSettingsView().toolbar { Button("Done") { settings = false } } }
            }
            .confirmationDialog("Clear this phone’s conversation?", isPresented: $clear, titleVisibility: .visible) {
                Button("Clear local history", role: .destructive) { local.clearConversation() }
            } message: { Text("Your downloaded model and saved notes will stay. This cannot be undone.") }
        }
        .onDisappear { Task { await local.releaseMemory() }; _ = chat.tapToHush() }
    }

    private func bubble(_ message: LocalMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "You" : "Haru · Dolphin").font(.caption).foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled)
                if message.state == .interrupted || message.state == .failed {
                    Text(message.state == .interrupted ? "Stopped · partial reply" : "Reply failed").font(.caption2).foregroundStyle(.orange)
                }
                if message.role == .assistant, message.state == .complete, !message.text.isEmpty, session.signedIn == true {
                    Button {
                        _ = chat.tapToHush()
                        chat.say(message.text, emotion: nil)
                    } label: { Label("Read aloud via server", systemImage: "speaker.wave.2") }
                    .font(.caption2).disabled(local.busy || chat.busy || chat.call != nil || chat.micOn)
                    .accessibilityHint("Sends this reply to Haru’s server for speech")
                }
            }.padding(12)
                .background(message.role == .user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            if message.role == .assistant { Spacer(minLength: 32) }
        }.id(message.id)
    }

    private func timing(_ metrics: LocalReplyMetrics) -> String {
        let first = metrics.firstTextSeconds.map { String(format: "%.1f s", $0) } ?? "—"
        let total = String(format: "%.1f s", metrics.totalSeconds)
        let omitted = metrics.omittedMessages > 0 ? " · \(metrics.omittedMessages) older messages outside context" : ""
        return "Local text: first \(first) · total \(total)\(metrics.loadedThisTurn ? " · includes model loading" : "")\(omitted)"
    }
}

struct LocalModelSettingsView: View {
    @Environment(LocalConversationStore.self) private var local
    @Environment(Session.self) private var session
    @State private var importing = false
    @State private var removing = false
    @State private var instructions = ""
    @State private var notes = ""
    @State private var context = 1024
    @State private var memories = false
    @State private var saved = false

    var body: some View {
        @Bindable var download = local.download
        Form {
            Section {
                Text(DolphinModel.name).font(.headline)
                Text("IQ3_XS · 3.02 GB download").font(.subheadline).foregroundStyle(.secondary)
                Text("A compact, uncensored Dolphin model. Answers may be less reliable than server models. The first reply loads it into memory; speed and heat depend on your phone.").font(.footnote)
                modelControls
                if let problem = download.problem { Text(problem).foregroundStyle(.orange).font(.footnote) }
            } header: { Text("Downloaded to this iPhone") }
                footer: { Text("Keep Haru open during download. It pauses when you leave the app. Files are checked before use. Deleting Haru removes the model, local notes and history.") }
            Section {
                Picker("Conversation context", selection: $context) {
                    Text("1,024 tokens · lower memory").tag(1024)
                    Text("2,048 tokens · more history").tag(2048)
                }
                Text("Older exchanges leave the model’s context when it fills, but remain in your saved history. Replies are limited to 256 tokens.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("How Haru should talk") {
                TextEditor(text: $instructions).frame(minHeight: 140).accessibilityLabel("Local personality instructions")
                Button("Restore default personality") { instructions = DolphinModel.defaultInstructions; saved = false }
            }
            Section {
                TextEditor(text: $notes).frame(minHeight: 110).accessibilityLabel("Local background notes")
                if session.signedIn == true { Button("Choose server memories…") { memories = true } }
            } header: { Text("Notes to remember locally") }
                footer: { Text("Only these notes and recent complete exchanges are sent to Dolphin. Local chats do not update Haru’s server memory. Keep notes short so there is room for conversation.") }
            Section {
                Button(saved ? "Settings saved" : "Save conversation settings") {
                    local.problem = nil
                    local.updateSettings(instructions: instructions, notes: notes, contextSize: context)
                    saved = local.problem == nil
                }.disabled(local.unavailable)
                if let problem = local.problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            }
            Section("Model and runtime") {
                Link("Dolphin model · Apache 2.0", destination: URL(string: "https://huggingface.co/cognitivecomputations/dolphin-2.9.3-mistral-7B-32k")!)
                Link("Quantized model files", destination: URL(string: "https://huggingface.co/bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF")!)
                NavigationLink("llama.cpp license") { ScrollView { Text(Self.runtimeLicense).font(.footnote).padding() }.navigationTitle("llama.cpp") }
            }
        }
        .navigationTitle("On-device conversation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { instructions = local.archive.instructions; notes = local.archive.notes; context = local.archive.contextSize }
        .onChange(of: instructions) { _, _ in saved = false }
        .onChange(of: notes) { _, _ in saved = false }
        .onChange(of: context) { _, _ in saved = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url): local.download.importFile(url)
            case .failure(let error): local.download.problem = error.localizedDescription
            }
        }
        .confirmationDialog("Remove the downloaded model?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Dolphin", role: .destructive) { Task { await local.removeModel() } }
        } message: { Text("Frees about 3 GB. Your local conversation and notes stay on the phone.") }
        .sheet(isPresented: $memories) { LocalMemoryPicker(notes: $notes) }
    }

    @ViewBuilder private var modelControls: some View {
        switch local.download.phase {
        case .ready:
            Label("Ready for offline chat", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Remove model", role: .destructive) { removing = true }.disabled(local.unavailable)
        case .downloading:
            ProgressView(value: local.download.progress)
            Text("\(ByteCountFormatter.string(fromByteCount: local.download.receivedBytes, countStyle: .decimal)) of 3.02 GB").font(.caption)
            Button("Pause download") { local.download.pause() }
        case .pausing: ProgressView("Pausing download…")
        case .verifying: ProgressView("Checking model file…")
        case .missing, .paused:
            Toggle("Allow cellular download", isOn: Binding(get: { local.download.allowCellular }, set: { local.download.allowCellular = $0 }))
            Button(local.download.phase == .paused ? "Resume download" : "Download Dolphin · 3.02 GB") { local.download.download() }
            Button("Import the IQ3_XS GGUF file…") { importing = true }
        }
    }

    private static let runtimeLicense = """
    llama.cpp b5046 — MIT License
    Copyright (c) 2023-2024 The ggml authors

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

private struct LocalMemoryPicker: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var notes: String
    @State private var items: [String] = []
    @State private var selected: Set<Int> = []
    @State private var loading = true
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Text("Choose notes to copy onto this phone. Review them and save your local settings afterward.").font(.footnote)
                if loading { ProgressView() }
                if let problem { Text(problem).foregroundStyle(.orange) }
                if !loading && items.isEmpty && problem == nil { Text("No server memories yet.") }
                ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                    Toggle(text, isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } }))
                }
            }.navigationTitle("Choose memories")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy selected") {
                            let copy = selected.sorted().map { items[$0] }.joined(separator: "\n")
                            notes += (notes.isEmpty ? "" : "\n") + copy
                            dismiss()
                        }.disabled(selected.isEmpty)
                    }
                }
                .task {
                    do { let page: MemoryPage = try await session.client.get("/api/memory"); items = page.memories }
                    catch { problem = error.localizedDescription }
                    loading = false
                }
        }
    }
}
