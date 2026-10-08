# Local-first conversation on iPhone

In **More → Conversation settings**, download **Umbral Mind RP v3.0 · 8B** (IQ3_XS, 3.52 GB), then select **Use local-first conversation**. The ordinary Chat screen, avatar and composer handle all replies. There is no separate local chat tab or “Ask server” option. Dolphin 2.9.3 Mistral 7B remains an optional download; existing verified files and saved conversations are preserved.

Every turn routes automatically. Explicit research, coding, planning, supported phone-tool requests, attachments and long requests go to the existing authenticated /api/chat/stream server route. Otherwise the local model answers, or requests a handoff with a leading control marker intercepted before display. Local inference/context errors also hand off once. Routing uses capability shortcuts plus model judgment, not a guarantee that an 8B model recognizes every hard question. Each assistant bubble identifies its route.

A handoff sends the current request and up to six recent complete messages, capped at 1,500 characters each, as quoted context. Editable local notes/personality are not separately uploaded; facts already spoken in recent messages can travel with that context. Server tasks use existing server history, memory, model escalation and tool authority. Ordinary local turns do not update server memory. Server failure preserves a failed/partial reply and never automatically resends an uncertain task.

Phone tools continue using existing Core-authorized grants and native iOS permission checks. The local LLM does not independently execute tools offline. Calls, speech recognition and read-aloud retain existing server routes. Local replies are text by default; explicit “Read via server” sends that reply for speech. This is local-first text conversation, not an offline voice-call engine.

## Model and storage

Umbral: Casual-Autopsy/L3-Umbral-Mind-RP-v3.0-8B; quantization repository bartowski/L3-Umbral-Mind-RP-v3.0-8B-GGUF; pinned revision ae7a34c6f728a955ec1bf52604d24c27000d6dd8. File L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf, 3,518,753,024 bytes, SHA-256 dc6c244374a1ab49167e139b93147449a65a25cc18ff1758566e44911f3d818a.

Dolphin: pinned revision 740ce4567b3392bd065637d2ac29127ca417cc45; file dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf, 3,022,780,608 bytes, SHA-256 3c4a71f5c97d1bc3ce81feb3afac63205059c8e8bf24ddbd45f8fb415270a99f.

Downloads, receipts and resume state are isolated per model. Downloads pause on background; cellular is opt-in. Import/download check exact size, GGUF magic and SHA-256. Files/history live in Application Support, excluded from iCloud backup. Removing a model keeps history/notes; deleting the app removes all local data. Switching from server replies copies complete text pairs currently loaded in Chat, without duplicates. Switching back shows server history; local turns are not uploaded wholesale.

Runtime: llama.cpp b5046, checksum-pinned Apple XCFramework. Physical devices request Metal; Simulator/native runner tests use CPU. Llama 3 formatting for Umbral and ChatML for Dolphin, tokenizer-supplied BOS, escaped role markers and split UTF-8/control-marker buffering. Default context 1,024 tokens, optional 2,048; local output cap 256 tokens. Only complete older exchanges enter model context; interrupted replies remain visible on disk but are excluded.

Weights stay warm between text turns. Switching models, backgrounding, memory warnings and server calls release them. The increased-memory-limit entitlement does not guarantee iOS will retain an 8B model under pressure.

## Validation and limits

Tests cover both prompt formats, prompt budgets, whole-pair eviction, role/stop boundaries, Unicode, checksums, per-model paths, archive recovery, copied-context deduplication, server completion/cancellation, private-note exclusion and uncertain outcomes without replay. Native smoke uses the exact Umbral GGUF for cold/warm generation and cancellation. A Simulator UI test exercises offline setup in the normal Chat screen.

An isolated Linux RTX 3060 probe exercised eight routing prompts. The initial model-only router missed coding and detailed trip planning; direct routes were added for these categories and tested as fixtures. GPU timings are not iPhone measurements. Earlier macOS CPU tests were slow; they do not establish Metal performance. iPhone 15 Pro Max generation speed, sustained memory pressure, heat, battery, permission prompts and end-to-end voice latency remain device-validation work. IQ3_XS trades quality for size; Umbral can invent personal details. Automatic routing can miss unfamiliar task wording.

Build-only qualification uses the exact Haru-Build-Only: true commit trailer. Optional Haru-Umbral-Smoke: true exercises real inference; Haru-UI-Smoke: true runs the Simulator UI test. A release commit without build-only uploads through the existing signing workflow and checks the exact build's TestFlight status.

Umbral source: https://huggingface.co/Casual-Autopsy/L3-Umbral-Mind-RP-v3.0-8B. Built with Meta Llama 3; base license bundled and shown in settings. Dolphin source/license: https://huggingface.co/cognitivecomputations/dolphin-2.9.3-mistral-7B-32k. llama.cpp MIT notice appears in settings.
