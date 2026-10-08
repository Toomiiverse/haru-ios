import SwiftUI
import UniformTypeIdentifiers

struct LocalModelSettingsView: View {
    @Environment(LocalConversationStore.self) private var local
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @State private var importing = false
    @State private var removing = false
    @State private var clearing = false
    @State private var instructions = ""
    @State private var notes = ""
    @State private var context = 1024
    @State private var memories = false
    @State private var saved = false
    @State private var loadedSettings = false

    var body: some View {
        @Bindable var download = local.download
        Form {
            Section {
                LabeledContent("Conversation", value: local.selected ? local.model.shortName + " · Automatic tasks" : "Haru server")
                if local.selected {
                    Button(session.signedIn == true ? "Use Haru server" : "Server sign-in") { local.selected = false }
                        .disabled(switchingDisabled)
                } else {
                    Button("Use local-first conversation") {
                        local.copyConversation(chat.entries.filter { !$0.waiting && $0.kind != .system }.map {
                            LocalMessage(id: "server-" + $0.id, role: $0.kind == .me ? .user : .assistant, text: $0.text)
                        })
                        if local.problem == nil {
                            local.selected = true
                            if session.signedIn == true, local.archive.instructions == DolphinModel.defaultInstructions {
                                Task { await local.syncPersonality(); instructions = local.archive.instructions }
                            }
                        }
                    }.disabled(switchingDisabled || !download.ready)
                }
            } header: { Text("Haru’s conversation") }
                footer: { Text("Use the same Chat screen and avatar. Quick conversation stays on the phone. For harder tasks, Haru can speak while the server checks your original request, then puts the result into her own words locally. Local personality prompts, history and notes aren’t added to task requests. The task service supports weather, public research and analysis. iPhone actions and attachments are not connected to this route yet. Her custom spoken voice and full calls still use the server.") }
            Section {
                Picker("Local model", selection: Binding(get: { local.model }, set: { model in
                    Task { await local.chooseModel(model) }
                })) {
                    ForEach(LocalModel.allCases) { model in Text(model.name).tag(model) }
                }.disabled(switchingDisabled || download.working)
                Text("IQ3_XS · " + local.model.sizeLabel + " download").font(.subheadline).foregroundStyle(.secondary)
                Text("Umbral focuses on expressive conversation and roleplay. It can invent details or memories. The first reply loads the model into memory; speed and heat depend on your phone.").font(.footnote)
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
                if session.signedIn == true {
                    Button("Copy Haru’s current personality") {
                        Task { await local.syncPersonality(); instructions = local.archive.instructions }
                    }.disabled(local.unavailable)
                }
                Button("Restore default personality") { instructions = DolphinModel.defaultInstructions; saved = false }
            }
            Section {
                TextEditor(text: $notes).frame(minHeight: 110).accessibilityLabel("Local background notes")
                if session.signedIn == true { Button("Choose server memories…") { memories = true } }
            } header: { Text("Notes to remember locally") }
                footer: { Text("The local model reads these notes and recent complete exchanges. Local replies do not update server memory. Task requests contain only your current question. Keep notes short so there is room for conversation.") }
            Section {
                Button(saved ? "Settings saved" : "Save conversation settings") {
                    local.problem = nil
                    local.updateSettings(instructions: instructions, notes: notes, contextSize: context)
                    saved = local.problem == nil
                }.disabled(local.unavailable)
                if let problem = local.problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            }
            Section("On this phone") {
                ShareLink("Export saved conversation", item: LocalFiles.conversation).disabled(local.unavailable)
                Button("Clear local history", role: .destructive) { clearing = true }.disabled(local.unavailable)
                if let metrics = local.metrics {
                    Text(String(format: "Last local text reply: first text %.1f s · total %.1f s", metrics.firstTextSeconds ?? 0, metrics.totalSeconds))
                        .font(.footnote)
                    Text("Most recent native generation only; a task turn may include a separate opening and server wait. Excludes speech and microphone time. Older messages outside context: \(metrics.omittedMessages).").font(.caption)
                }
            }
            Section("Model and runtime") {
                Link("Model source and license", destination: local.model.source)
                Link("Quantized model files", destination: local.model.quantization)
                if local.model == .umbral {
                    Text("Built with Meta Llama 3").font(.footnote)
                    Text("Meta Llama 3 is licensed under the Meta Llama 3 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved.").font(.caption)
                    NavigationLink("Meta Llama 3 license") {
                        ScrollView { Text(Self.llamaLicense).font(.footnote).padding() }.navigationTitle("Meta Llama 3")
                    }
                }
                NavigationLink("llama.cpp license") { ScrollView { Text(Self.runtimeLicense).font(.footnote).padding() }.navigationTitle("llama.cpp") }
            }
        }
        .navigationTitle("Conversation settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loadedSettings {
                instructions = local.archive.instructions; notes = local.archive.notes; context = local.archive.contextSize
                loadedSettings = true
            }
        }
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
            Button("Remove " + local.model.shortName, role: .destructive) { Task { await local.removeModel() } }
        } message: { Text("Frees the downloaded model’s storage. Your local conversation and notes stay on the phone.") }
        .confirmationDialog("Clear this phone’s conversation?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear local history", role: .destructive) { local.clearConversation() }
        } message: { Text("Your downloaded models and saved notes stay. This cannot be undone.") }
        .sheet(isPresented: $memories) { LocalMemoryPicker(notes: $notes) }
    }

    private var switchingDisabled: Bool { local.unavailable || chat.busy || chat.call != nil || chat.micOn || !chat.staged.isEmpty }
    @ViewBuilder private var modelControls: some View {
        switch local.download.phase {
        case .ready:
            Label("Ready for offline chat", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Remove model", role: .destructive) { removing = true }.disabled(local.unavailable)
        case .downloading:
            ProgressView(value: local.download.progress)
            Text("\(ByteCountFormatter.string(fromByteCount: local.download.receivedBytes, countStyle: .decimal)) of \(local.model.sizeLabel)").font(.caption)
            Button("Pause download") { local.download.pause() }
        case .pausing: ProgressView("Pausing download…")
        case .verifying: ProgressView("Checking model file…")
        case .missing, .paused:
            Toggle("Allow cellular download", isOn: Binding(get: { local.download.allowCellular }, set: { local.download.allowCellular = $0 }))
            Button(local.download.phase == .paused ? "Resume download" : "Download " + local.model.shortName + " · " + local.model.sizeLabel) { local.download.download() }
            Button("Import the IQ3_XS GGUF file…") { importing = true }
        }
    }

    private static var llamaLicense: String {
        guard let url = Bundle.main.url(forResource: "llama3-license", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "See the model source for its license." }
        return text
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


struct LocalMessageRow: View {
    let message: LocalMessage
    @Environment(LocalConversationStore.self) private var local
    @Environment(ChatStore.self) private var chat
    @Environment(Session.self) private var session

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant, let source = message.source {
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
                if message.state == .generating && message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else { Text(message.text).textSelection(.enabled) }
                if message.state == .interrupted || message.state == .failed {
                    Text(message.state == .interrupted ? "Stopped · partial reply" : "Reply failed")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let result = message.taskResult {
                    DisclosureGroup("Task result") {
                        Text(result.answer).font(.callout).textSelection(.enabled)
                        ForEach(Array(result.sources.enumerated()), id: \.offset) { _, source in
                            if let url = URL(string: source.url), url.scheme == "https" {
                                Link(source.title ?? url.host ?? "Source", destination: url).font(.caption)
                            }
                        }
                    }.font(.caption)
                }
                if message.text.contains("Apple Weather for"), let legal = PhoneTools.shared.weatherLegal {
                    Link("Apple Weather attribution", destination: legal).font(.caption)
                }
                if message.role == .assistant && message.state != .generating {
                    HStack {
                        if message.id == local.archive.messages.last?.id {
                            Button("Retry", systemImage: "arrow.clockwise") { local.retry() }
                                .disabled(local.unavailable || !local.download.ready || chat.call != nil || chat.micOn)
                        }
                        if !message.text.isEmpty && session.signedIn == true {
                            Button("Read aloud", systemImage: "speaker.wave.2") {
                                _ = chat.tapToHush(); chat.say(message.text, emotion: nil)
                            }.accessibilityHint("Sends only this reply to the server for speech")
                                .disabled(local.unavailable || chat.busy || chat.call != nil || chat.micOn)
                        }
                    }.font(.caption2)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            if message.role == .assistant { Spacer(minLength: 48) }
        }.id(message.id)
    }
}
