import SwiftUI

/// Train a LoRA of her from the saved look, one manual step at a time, on the
/// image server beside her (ComfyUI's haru_lora.py, port 8188): draw the
/// pictures, say yes or no to each one, then train on the yeses. The server
/// refuses a look that does not describe an adult, and refuses to train when
/// her machine is short of memory; its words are shown as they are.
struct LoraStatus: Decodable {
    let state: String
    let phase: String?
    let done: Int?
    let total: Int?
    let message: String?
    let job: String?
    let pictures: [String: Bool?]?
    let lora: String?
    let loras: [String]
}

private struct Rendered: Decodable { let seed: Int; let images: [String] }
private struct Cancelled: Decodable { let cancelling: Bool }

struct LoraView: View {
    @Environment(Session.self) private var session
    @State private var status: LoraStatus?
    @State private var images = 24
    @State private var steps = 1200
    @State private var busy = false
    @State private var problem: String?
    @State private var previewing: String?
    @State private var scene = ""
    @State private var preview: UIImage?

    /// The image server is on her host, one port over.
    private var artist: HaruClient {
        var parts = URLComponents(url: session.client.base, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.port = 8188
        parts.path = ""
        return HaruClient(base: parts.url ?? session.client.base)
    }

    private var running: Bool { status?.state == "running" }
    private var reviewing: Bool { status?.state == "review" }
    private var names: [String] { (status?.pictures ?? [:]).keys.sorted() }
    private var undecided: Int { (status?.pictures ?? [:]).values.filter { $0 == nil }.count }
    private var kept: Int { (status?.pictures ?? [:]).values.filter { $0 == true }.count }

    var body: some View {
        Form {
            Section {
                if let status {
                    LabeledContent("Now", value: status.message ?? status.state.capitalized)
                    if running, let done = status.done, let total = status.total, total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                    }
                    if let lora = status.lora, status.state == "done" { LabeledContent("Made", value: lora) }
                    if running {
                        Button("Stop", role: .destructive) { Task { await cancel() } }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Her LoRA")
            } footer: {
                Text("Three steps, each started by you: draw the pictures, say yes or no to every one, then train on the yeses.")
            }

            if !running && !reviewing {
                Section {
                    Stepper("Pictures: \(images)", value: $images, in: 8...72, step: 4)
                    Button(busy ? "Starting…" : "1. Draw the pictures") { Task { await drawDataset() } }
                        .disabled(busy || status == nil)
                } footer: {
                    Text("About \(images * 20 / 60 + 1) minutes. Nothing is trained yet.")
                }
            }

            if reviewing, let job = status?.job {
                Section {
                    ForEach(names, id: \.self) { name in
                        LoraPictureRow(name: name, job: job, keep: status?.pictures?[name] ?? nil, artist: artist) { keep in
                            Task { await decide(name, keep) }
                        }
                    }
                } header: {
                    Text("2. Yes or no")
                } footer: {
                    Text(undecided > 0 ? "\(undecided) still to look at." : "\(kept) kept.")
                }
                Section {
                    Stepper("Steps: \(steps)", value: $steps, in: 200...4000, step: 100)
                    Button(busy ? "Starting…" : "3. Train on the \(kept) kept") { Task { await train() } }
                        .disabled(busy || undecided > 0 || kept < 2)
                } footer: {
                    Text("About \(steps * 2 / 60 + 1) minutes on her server. Her pictures and previews wait while it trains.")
                }
            }

            if let loras = status?.loras, !loras.isEmpty {
                Section("Trained") {
                    TextField("Scene for a preview (optional)", text: $scene)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    ForEach(loras, id: \.self) { lora in
                        Button { Task { await draw(lora) } } label: {
                            HStack {
                                Text(lora).font(.callout.monospaced())
                                Spacer()
                                if previewing == lora { ProgressView() } else { Image(systemName: "eye") }
                            }
                        }
                        .disabled(previewing != nil || running)
                    }
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Preview drawn with the LoRA")
                    }
                }
            }
            if let problem { Section("Needs attention") { Text(problem) } }
        }
        .navigationTitle("Her LoRA")
        .refreshable { await refresh() }
        .task(id: session.baseURLString) {
            // Follow a running step; otherwise check in now and then.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(running ? 5 : 30))
            }
        }
    }

    private func refresh() async {
        do {
            status = try await artist.get("/haru/lora/status")
        } catch {
            problem = "Her image server did not answer: \(error.localizedDescription)"
        }
    }

    private func drawDataset() async {
        busy = true
        defer { busy = false }
        do {
            status = try await artist.post("/haru/lora/draw", ["images": .number(Double(images))])
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func decide(_ name: String, _ keep: Bool) async {
        do {
            status = try await artist.post("/haru/lora/decide", ["name": .string(name), "keep": .bool(keep)])
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func train() async {
        busy = true
        defer { busy = false }
        do {
            status = try await artist.post("/haru/lora/train", ["steps": .number(Double(steps))])
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func cancel() async {
        do {
            let _: Cancelled = try await artist.post("/haru/lora/cancel")
            await refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func draw(_ lora: String) async {
        previewing = lora
        defer { previewing = nil }
        do {
            let out: Rendered = try await artist.post("/haru/lora/preview", ["lora": .string(lora), "scene": .string(scene)])
            guard let first = out.images.first, let data = Data(base64Encoded: first), let image = UIImage(data: data) else {
                problem = "The picture came back empty."
                return
            }
            preview = image
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One dataset picture with its yes and no.
private struct LoraPictureRow: View {
    let name: String
    let job: String
    let keep: Bool?
    let artist: HaruClient
    let decide: (Bool) -> Void
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color(uiColor: .secondarySystemBackground).aspectRatio(832.0 / 1216.0, contentMode: .fit)
                        .overlay { ProgressView() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(keep == false ? 0.35 : 1)
            HStack {
                Button { decide(false) } label: {
                    Label("No", systemImage: keep == false ? "xmark.circle.fill" : "xmark.circle")
                }
                .tint(.red)
                Spacer()
                Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button { decide(true) } label: {
                    Label("Yes", systemImage: keep == true ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(.green)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .task(id: job + name) {
            guard let data = try? await artist.bytes("/haru/lora/picture", query: ["job": job, "name": name]) else { return }
            image = UIImage(data: data)
        }
    }
}
