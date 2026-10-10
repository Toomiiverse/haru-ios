import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var problem: String?
    @State private var portrait: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Group {
                            if let portrait {
                                Image(uiImage: portrait).resizable().scaledToFill()
                            } else {
                                Circle().fill(.quaternary)
                            }
                        }
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Where she is") {
                    TextField("https://haruserver…ts.net", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Sign in") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn() } }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || username.isEmpty || password.isEmpty)
                } footer: {
                    Text("Reached over Tailscale only. The phone must be on the tailnet, and her web door must be switched on in her desktop settings.")
                }
            }
            .navigationTitle("Haru")
        }
        .onAppear {
            if server.isEmpty { server = session.baseURLString }
            problem = session.problem
        }
        .task(id: server) { await loadPortrait() }
    }

    private func signIn() async {
        working = true
        defer { working = false }
        problem = nil
        session.useBase(server)
        do {
            try await session.signIn(username: username, password: password)
            _ = await Refresh.askPermission()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadPortrait() async {
        guard !server.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        // Her face is served before the login, so the address can be checked by
        // eye. A client of its own: the address is only kept once Sign in is tapped.
        let client = Session.client(for: server, quick: true)
        if let data = try? await client.bytes("/portrait") {
            portrait = UIImage(data: data)
        }
    }
}
