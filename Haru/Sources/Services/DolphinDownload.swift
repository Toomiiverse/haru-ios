import Foundation
import CryptoKit
import Observation

enum LocalFiles {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalConversation", isDirectory: true)
    static let model = directory.appendingPathComponent(DolphinModel.filename)
    static let receipt = directory.appendingPathComponent("model-verified.json")
    static let resume = directory.appendingPathComponent("download.resume")
    static let resumeProgress = directory.appendingPathComponent("download-progress.json")
    static let conversation = directory.appendingPathComponent("conversation.json")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }

    struct Receipt: Codable {
        let sha256: String
        let bytes: Int64
        let modified: Date
    }

    static func isReady() -> Bool {
        guard let data = try? Data(contentsOf: receipt), let stamp = try? JSONDecoder().decode(Receipt.self, from: data),
              let attributes = try? FileManager.default.attributesOfItem(atPath: model.path),
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return false }
        return stamp.sha256 == DolphinModel.sha256 && stamp.bytes == DolphinModel.bytes
            && size.int64Value == stamp.bytes && abs(modified.timeIntervalSince(stamp.modified)) < 0.01
    }

    static func verify(_ url: URL, expectedBytes: Int64 = DolphinModel.bytes, expectedHash: String = DolphinModel.sha256) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else {
            throw LocalChatError.message("The file has the wrong size. Choose the Dolphin 2.9.3 Mistral 7B IQ3_XS file or download it again.")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw LocalChatError.message("This is not a GGUF model file.")
        }
        try input.seek(toOffset: 0)
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw LocalChatError.message("The model checksum did not match. The incomplete or incorrect file was not installed. Download it again.")
        }
    }

    static func installVerified(_ incoming: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: model.path) { try fm.removeItem(at: model) }
        try fm.moveItem(at: incoming, to: model)
        let attributes = try fm.attributesOfItem(atPath: model.path)
        guard let modified = attributes[.modificationDate] as? Date else {
            throw LocalChatError.message("Could not record the verified model.")
        }
        let stamp = Receipt(sha256: DolphinModel.sha256, bytes: DolphinModel.bytes, modified: modified)
        try JSONEncoder().encode(stamp).write(to: receipt, options: .atomic)
        try? fm.removeItem(at: resume)
        try? fm.removeItem(at: resumeProgress)
    }
}

@MainActor @Observable
final class DolphinDownload {
    enum Phase: Equatable { case missing, downloading, pausing, paused, verifying, ready }
    private(set) var phase: Phase = .missing
    private(set) var progress = 0.0
    private(set) var receivedBytes: Int64 = 0
    var problem: String?
    var allowCellular = false
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegate: DolphinDownloadDelegate?
    private var operation = UUID()
    private var verification: Task<Void, Error>?

    var ready: Bool { phase == .ready }
    var working: Bool { phase == .downloading || phase == .pausing || phase == .verifying }

    init() {
        do {
            try LocalFiles.prepare()
            phase = LocalFiles.isReady() ? .ready : FileManager.default.fileExists(atPath: LocalFiles.resume.path) ? .paused : .missing
            if phase == .paused, let data = try? Data(contentsOf: LocalFiles.resumeProgress),
               let bytes = try? JSONDecoder().decode(Int64.self, from: data) {
                receivedBytes = min(DolphinModel.bytes, max(0, bytes))
                progress = Double(receivedBytes) / Double(DolphinModel.bytes)
            }
            // Only abandoned incoming copies; the verified model and transcript stay.
            for url in try FileManager.default.contentsOfDirectory(at: LocalFiles.directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("incoming-") { try? FileManager.default.removeItem(at: url) }
        } catch { problem = error.localizedDescription }
    }

    func download() {
        guard !working, !ready else { return }
        do {
            try LocalFiles.prepare()
            let capacity = try LocalFiles.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            let resuming = FileManager.default.fileExists(atPath: LocalFiles.resume.path)
            let needed = DolphinModel.bytes - (resuming ? receivedBytes : 0) + 256_000_000
            if let capacity, capacity < needed {
                throw LocalChatError.message("Free at least \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .decimal)) on this iPhone to continue downloading Dolphin.")
            }
            if !resuming { receivedBytes = 0; progress = 0 }
            problem = nil; phase = .downloading
            let id = UUID(); operation = id
            let incoming = LocalFiles.directory.appendingPathComponent("incoming-" + id.uuidString)
            let delegate = DolphinDownloadDelegate(destination: incoming, progress: { [weak self] bytes, total in
                Task { @MainActor in
                    guard let self, self.operation == id, self.phase == .downloading else { return }
                    self.receivedBytes = bytes
                    self.progress = min(1, Double(bytes) / Double(max(1, total)))
                }
            }, completed: { [weak self] result, resume in
                Task { @MainActor in
                    guard let self, self.operation == id else {
                        if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                        return
                    }
                    self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil; self.delegate = nil
                    switch result {
                    case .success(let url): self.validate(url, id: id)
                    case .failure(let error):
                        if let resume { self.saveResume(resume) }
                        self.phase = .paused; self.problem = error.localizedDescription
                    }
                }
            })
            let config = URLSessionConfiguration.default
            config.allowsCellularAccess = allowCellular
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.delegate = delegate; self.session = session
            if let resume = try? Data(contentsOf: LocalFiles.resume) {
                task = session.downloadTask(withResumeData: resume)
                try? FileManager.default.removeItem(at: LocalFiles.resume)
            } else { task = session.downloadTask(with: DolphinModel.url) }
            task?.resume()
        } catch { phase = .missing; problem = error.localizedDescription }
    }

    func pause() {
        guard phase == .downloading, let task else { return }
        let id = UUID(); operation = id
        phase = .pausing; self.task = nil
        let session = self.session
        self.session = nil; delegate = nil
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                if let self, self.operation == id {
                    if let data { self.saveResume(data) }
                    self.phase = .paused
                }
                session?.finishTasksAndInvalidate()
            }
        })
    }

    func importFile(_ source: URL) {
        guard !working, !ready else { return }
        let access = source.startAccessingSecurityScopedResource()
        let id = UUID(); operation = id
        phase = .verifying; problem = nil
        let incoming = LocalFiles.directory.appendingPathComponent("incoming-" + id.uuidString)
        let check = Task.detached(priority: .utility) {
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == DolphinModel.bytes else {
                throw LocalChatError.message("Choose dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf (3.02 GB).")
            }
            try LocalFiles.prepare()
            try FileManager.default.copyItem(at: source, to: incoming)
            try Task.checkCancellation()
            try LocalFiles.verify(incoming)
        }
        verification = check
        finishVerification(check, incoming: incoming, id: id)
    }

    private func validate(_ incoming: URL, id: UUID) {
        phase = .verifying; progress = 1
        let check = Task.detached(priority: .utility) { try LocalFiles.verify(incoming) }
        verification = check
        finishVerification(check, incoming: incoming, id: id)
    }

    private func finishVerification(_ check: Task<Void, Error>, incoming: URL, id: UUID) {
        Task {
            do {
                try await check.value
                guard operation == id else { try? FileManager.default.removeItem(at: incoming); return }
                try LocalFiles.installVerified(incoming)
                phase = .ready; problem = nil
            } catch {
                try? FileManager.default.removeItem(at: incoming)
                guard operation == id else { return }
                phase = .missing; problem = error.localizedDescription
            }
            verification = nil
        }
    }

    func remove() throws {
        guard !working else { return }
        operation = UUID()
        for url in [LocalFiles.receipt, LocalFiles.model, LocalFiles.resume, LocalFiles.resumeProgress] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        phase = .missing; progress = 0; receivedBytes = 0; problem = nil
    }

    private func saveResume(_ data: Data) {
        do {
            try data.write(to: LocalFiles.resume, options: .atomic)
            try JSONEncoder().encode(receivedBytes).write(to: LocalFiles.resumeProgress, options: .atomic)
        } catch { problem = "Download progress could not be saved: " + error.localizedDescription }
    }
}

private final class DolphinDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    let completed: @Sendable (Result<URL, Error>, Data?) -> Void

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void,
         completed: @escaping @Sendable (Result<URL, Error>, Data?) -> Void) {
        self.destination = destination; self.progress = progress; self.completed = completed
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : DolphinModel.bytes)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw LocalChatError.message("The model download server returned an error. Try downloading again.")
            }
            // URLSession deletes location when this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            completed(.success(destination), nil)
        } catch { completed(.failure(error), nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completed(.failure(error), (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data)
        }
    }
}
