import Foundation

enum DolphinEvent {
    case loading
    case generating
    case text(String)
    case finished(LocalReplyMetrics, limited: Bool)
}

final class DolphinCancellation: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
    init() { raw = haru_cancel_create()! }
    func cancel() { haru_cancel_set(raw) }
    var isCancelled: Bool { haru_cancelled(raw) }
    deinit { haru_cancel_free(raw) }
}

/// All model, KV cache and sampler access is confined to this serial queue.
/// Cancellation is an independent atomic flag, including during model loading.
final class DolphinEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "haru.dolphin.inference", qos: .userInitiated)
    private var handle: UnsafeMutableRawPointer?
    private var loadedContext = 0
    private let gpu: Bool

    init(gpu: Bool = true) { self.gpu = gpu }

    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async {
                haru_llama_close(self.handle)
                self.handle = nil; self.loadedContext = 0
                continuation.resume()
            }
        }
    }

    func reply(model: URL, archive: LocalConversationArchive, cancellation: DolphinCancellation,
               maxTokens: Int = 256) -> AsyncThrowingStream<DolphinEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in cancellation.cancel() }
            queue.async { [self] in
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    if cancellation.isCancelled { throw CancellationError() }
                    let cold = handle == nil || loadedContext != archive.contextSize
                    if cold {
                        haru_llama_close(handle); handle = nil
                        continuation.yield(.loading)
                        handle = model.path.withCString {
                            haru_llama_open($0, Int32(archive.contextSize), gpu, cancellation.raw)
                        }
                        guard handle != nil else {
                            if cancellation.isCancelled { throw CancellationError() }
                            throw LocalChatError.message("Dolphin could not load. Close other heavy apps and try again with 1,024 context tokens. If it still fails, remove and download the model again.")
                        }
                        loadedContext = archive.contextSize
                    }
                    guard let handle else { throw LocalChatError.message("The local model is unavailable.") }
                    let prompt = try LocalPrompt.build(instructions: archive.instructions, notes: archive.notes,
                        messages: archive.messages, contextSize: archive.contextSize, outputTokens: maxTokens) { text in
                            let count = text.withCString { haru_llama_count(handle, $0) }
                            guard count > 0 else { throw LocalChatError.message("Dolphin could not read the prompt.") }
                            return Int(count)
                        }
                    if cancellation.isCancelled { throw CancellationError() }
                    continuation.yield(.generating)
                    let sink = DolphinSink(continuation: continuation, cancellation: cancellation)
                    let opaque = Unmanaged.passUnretained(sink).toOpaque()
                    var generated: Int32 = 0
                    let status = prompt.text.withCString {
                        haru_llama_generate(handle, $0, Int32(maxTokens), cancellation.raw, { bytes, count, context in
                            guard let bytes, let context else { return false }
                            return Unmanaged<DolphinSink>.fromOpaque(context).takeUnretainedValue()
                                .receive(Data(bytes: bytes, count: Int(count)))
                        }, opaque, &generated)
                    }
                    if cancellation.isCancelled || status == 2 { throw CancellationError() }
                    guard status >= 0 else { throw LocalChatError.message("Dolphin stopped because inference failed (\(status)). Try a shorter context or reload the model.") }
                    let final = sink.buffer.finish()
                    continuation.yield(.text(final))
                    let end = ProcessInfo.processInfo.systemUptime
                    continuation.yield(.finished(LocalReplyMetrics(
                        firstTextSeconds: sink.firstTextAt.map { $0 - start }, totalSeconds: end - start,
                        generatedTokens: Int(generated), generationSeconds: sink.firstTextAt.map { end - $0 } ?? 0,
                        promptTokens: prompt.tokens, omittedMessages: prompt.omittedMessages, loadedThisTurn: cold
                    ), limited: status == 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private final class DolphinSink {
    let continuation: AsyncThrowingStream<DolphinEvent, Error>.Continuation
    let cancellation: DolphinCancellation
    var buffer = LocalTextBuffer()
    var firstTextAt: Double?
    private var lastEmission = 0.0

    init(continuation: AsyncThrowingStream<DolphinEvent, Error>.Continuation, cancellation: DolphinCancellation) {
        self.continuation = continuation; self.cancellation = cancellation
    }

    func receive(_ data: Data) -> Bool {
        guard !cancellation.isCancelled else { return false }
        if let text = buffer.append(data), !text.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            if firstTextAt == nil { firstTextAt = now }
            if now - lastEmission >= 0.04 || buffer.stopped {
                continuation.yield(.text(text)); lastEmission = now
            }
        }
        return !buffer.stopped && !cancellation.isCancelled
    }
}
