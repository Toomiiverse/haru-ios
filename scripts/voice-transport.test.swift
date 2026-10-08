import Foundation

// Runs the real HaruClient against a local HTTP server. The server withholds
// the rest of the PCM until this consumer receives the first chunk.
@main
struct VoiceTransportTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HaruError.server(500, message) }
    }

    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let client = HaruClient(base: base)
        let download = client.speech("partial & exact?", emotion: "affectionate")
        var iterator = download.parts.makeAsyncIterator()
        guard case .some(.format(let rate)) = try await iterator.next() else { fatalError("Missing format") }
        try require(rate == 24_000, "Wrong sample rate")
        guard case .some(.pcm(let first)) = try await iterator.next() else { fatalError("Missing first PCM") }
        try require(first == Data(repeating: 17, count: 4096), "First audio was changed or buffered until EOF")
        // Reaching here proves playback can begin before synthesis finishes.
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("finish"))
        var tail = Data()
        while let part = try await iterator.next() {
            guard case .pcm(let data) = part else { fatalError("Unexpected second format/file") }
            tail.append(data)
        }
        try require(tail == Data([17, 23, 31, 47]), "Odd chunk boundary lost or duplicated bytes")

        var files = [Data]()
        for try await part in client.speech("fallback", emotion: nil).parts {
            guard case .file(let data) = part else { fatalError("Fallback was treated as PCM") }
            files.append(data)
        }
        try require(files == [Data([82, 73, 70, 70])], "Buffered voice fallback changed")

        do {
            for try await _ in client.speech("signed-out", emotion: nil).parts {}
            fatalError("401 did not fail")
        } catch HaruError.signedOut { }

        do {
            for try await _ in client.speech("bad-rate", emotion: nil).parts {}
            fatalError("Invalid PCM rate was accepted")
        } catch HaruError.server(let status, _) { try require(status == 502, "Wrong PCM error") }

        // A prefetched request must also cancel without ever being consumed.
        let abandoned = client.speech("cancel", emotion: nil)
        try await waitFor("started", base: base)
        abandoned.cancel()
        try await waitFor("cancelled", base: base)
        print("Voice transport: progressive PCM, exact bytes, file fallback, errors and queued cancellation passed.")
    }

    static func waitFor(_ key: String, base: URL) async throws {
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("status"))
            let state = try JSONDecoder().decode([String: Bool].self, from: data)
            if state[key] == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HaruError.server(500, "Timed out waiting for \(key)")
    }
}
