# Local-first conversation on iPhone

In **More → Conversation settings**, download **Umbral Mind RP v3.0 · 8B** (IQ3_XS, 3.52 GB), then select **Use local-first conversation**. The ordinary Chat screen, avatar and composer handle all replies. There is no separate local chat tab or “Ask server” option. Dolphin 2.9.3 Mistral 7B remains an optional download; existing verified files and saved conversations are preserved.

Every turn routes automatically. Capability shortcuts cover explicit research, coding, planning and current information; otherwise Umbral answers locally or emits a hidden handoff marker. A local inference/context error also routes once. The 8B model can still miss unfamiliar hard requests. No manual “Ask server” control exists.

For a task, the phone starts authenticated `/api/local/task` with exactly the original question and a stable request ID, concurrently generating a short local acknowledgement. A result that arrives first cancels the unnecessary opening. The neutral Core route uses verified Open-Meteo weather without a personality pass, or an accounted GPT-6.1 Sol session with bounded public search. It does not receive local personality, notes or assistant history, and does not write conversation memory. Follow-ups that depend on prior context may need a clarification.

Umbral then expresses the returned answer locally. The original answer and sources are retained under “Task result.” Numerical changes, changed weather conditions/day/location, truncation and local rendering failures fall back to the original answer. Even faithful unit rewordings or abbreviated places may trigger this conservative fallback. The numeric guard is not a semantic proof: nonnumeric meaning can still drift. Unknown/unconfirmed results are shown directly. Server failures do not replay automatically; explicit retry retains the original request ID so Core returns its stored outcome.

“Copy Haru’s current personality” downloads bounded excerpts of the installed Core identity and speaking style. First activation with untouched defaults copies this automatically when signed in. Editable notes remain phone-local; selected server memories can be copied manually. Ordinary local conversation does not update server memory. The small context holds only recent complete exchanges.

The local microphone uses iOS on-device speech recognition for the current supported language. It submits after a pause or a second tap, with a 30-second cap, and refuses unsupported on-device recognition instead of silently uploading audio. Umbral wording plays through Haru’s existing custom server TTS voice when signed in. This sends the final spoken text to the speech service. Offline conversation remains text-only. Full calls and standby retain the existing server call route.

This neutral task route currently supports weather, public research and analysis. iPhone actions, server file mutations, attachments and automatic server memory lookup are not connected to it. Existing full server conversation retains those capabilities. The local LLM cannot independently execute phone tools offline.

## Model and storage

Umbral: Casual-Autopsy/L3-Umbral-Mind-RP-v3.0-8B; quantization repository bartowski/L3-Umbral-Mind-RP-v3.0-8B-GGUF; pinned revision ae7a34c6f728a955ec1bf52604d24c27000d6dd8. File L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf, 3,518,753,024 bytes, SHA-256 dc6c244374a1ab49167e139b93147449a65a25cc18ff1758566e44911f3d818a.

Dolphin: pinned revision 740ce4567b3392bd065637d2ac29127ca417cc45; file dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf, 3,022,780,608 bytes, SHA-256 3c4a71f5c97d1bc3ce81feb3afac63205059c8e8bf24ddbd45f8fb415270a99f.

Downloads, receipts and resume state are isolated per model. Downloads pause on background; cellular is opt-in. Import/download check exact size, GGUF magic and SHA-256. Files/history live in Application Support, excluded from iCloud backup. Removing a model keeps history/notes; deleting the app removes all local data. Switching from server replies copies complete text pairs currently loaded in Chat, without duplicates. Switching back shows server history; local turns are not uploaded wholesale.

Runtime: llama.cpp b5046, checksum-pinned Apple XCFramework. Physical devices request Metal; Simulator/native runner tests use CPU. Llama 3 formatting for Umbral and ChatML for Dolphin, tokenizer-supplied BOS, escaped role markers and split UTF-8/control-marker buffering. Default context 1,024 tokens, optional 2,048; local output cap 256 tokens. Only complete older exchanges enter model context; interrupted replies remain visible on disk but are excluded.

Weights stay warm between text turns. Switching models, backgrounding, memory warnings and server calls release them. The increased-memory-limit entitlement does not guarantee iOS will retain an 8B model under pressure.

## Validation and limits

Tests cover both prompt formats, prompt budgets, whole-pair eviction, role/stop boundaries, Unicode, checksums, per-model paths, archive recovery, copied-context deduplication, server completion/cancellation, private-note exclusion and uncertain outcomes without replay. Native smoke uses the exact Umbral GGUF for cold/warm generation and cancellation. A Simulator UI test exercises offline setup in the normal Chat screen.

An isolated Linux RTX 3060 probe exercised eight routing prompts. The initial model-only router missed coding and detailed trip planning; direct routes were added for these categories and tested as fixtures. GPU timings are not iPhone measurements. Earlier macOS CPU tests were slow; they do not establish Metal performance. iPhone 15 Pro Max generation speed, sustained memory pressure, heat, battery, permission prompts and end-to-end voice latency remain device-validation work. IQ3_XS trades quality for size; Umbral can invent personal details. Automatic routing can miss unfamiliar task wording.

An isolated real-Umbral presentation probe found fabricated weather in an opening and a changed forecast day; the guards reject those outputs. After tightening the local turn instructions, the opening was “Checking.” and the forecast meaning improved, but written-out numbers/abbreviated locations still require the original-answer fallback. This small sample does not establish general factual reliability. Its Linux CUDA timings are not iPhone measurements.

Build-only qualification uses the exact Haru-Build-Only: true commit trailer. Optional Haru-Umbral-Smoke: true exercises real inference; Haru-UI-Smoke: true runs the Simulator UI test. A release commit without build-only uploads through the existing signing workflow and checks the exact build's TestFlight status.

Umbral source: https://huggingface.co/Casual-Autopsy/L3-Umbral-Mind-RP-v3.0-8B. Built with Meta Llama 3; base license bundled and shown in settings. Dolphin source/license: https://huggingface.co/cognitivecomputations/dolphin-2.9.3-mistral-7B-32k. llama.cpp MIT notice appears in settings.
