# Dolphin on iPhone

In Chat, select **On iPhone**, open **On-device settings**, and download Dolphin (3.02 GB). A login-screen entry also allows setup and conversation without the Haru server. Keep Haru open for the download; leaving the app pauses it. Resume uses URLSession resume data when available. Import accepts only the same pinned GGUF, verified by size, magic and SHA-256.

The app embeds llama.cpp b5046; the model is downloaded into Application Support, excluded from iCloud backup. The app uses Metal on a physical iPhone and CPU in Simulator. IQ3_XS reduces memory/storage at a quality cost. Defaults: 1,024 context tokens, 256 output tokens, four CPU threads; a 2,048-token context option increases memory demand. The increased-memory-limit entitlement is requested, but iOS may still terminate the app under pressure. No claim of iPhone performance or memory stability is made without testing on the target device.

## Routes and continuity

| Mode/action | Route | History, memory and capabilities |
| --- | --- | --- |
| AI tab | Existing server `/api/chat/stream` | Existing server model configuration, memory, tools and escalation |
| Character tab | Existing server roleplay/Venice route | Existing separate character histories |
| On iPhone | Dolphin 2.9.3 Mistral 7B, IQ3_XS, native llama.cpp | Separate local text history; editable personality and selected notes; no tools, vision or automatic escalation |
| Read aloud via server | Existing `/api/speak` voice path | Sends only the selected answer for speech; not offline voice |
| Choose server memories | Explicit GET `/api/memory` | User selects copies for local notes, then saves settings; no write-back |

There is no automatic fallback from local inference to a server model. Existing server model IDs are not changed by this feature. Selecting local chat disables wake-word standby; explicitly invoking a call/standby shortcut switches back to server mode. Other app services such as push, location or health retain their existing user settings; selecting a local conversation is not an app-wide network-off switch.

Local history uses atomic JSON writes and checkpoints streamed replies each second. Interrupted replies remain visible and are excluded from subsequent context. The prompt uses the model's actual tokenizer, drops complete oldest exchanges, and refuses a current question/system prompt that cannot fit. Text resembling ChatML delimiters is escaped. Notes are literal prompt context, not a guaranteed reliable memory system. Clearing an unreadable archive first keeps a recovery copy on disk.

The model stays loaded between foreground turns, and is released on leaving local chat, backgrounding, or memory warning. Cancellation is checked during load, prompt batches and decoding; Metal work already submitted must finish. Downloading uses a foreground URLSession and explicitly pauses on backgrounding, not a background-download service.

## Qualification

`scripts/test-dolphin.sh` compiles the C++ bridge and Swift model/engine/download/store on macOS. Tests cover prompt budget and role boundaries, complete-exchange eviction, split UTF-8/stop markers, interrupted archive recovery, bad-file rejection and pre-load cancellation.

Set `HARU_DOLPHIN_SMOKE=1` to additionally fetch and verify the exact production model and exercise cold/warm inference, two conversation turns, active cancellation and unload on the Mac CPU. These timings are **not iPhone measurements**. The app's per-reply timing is local engine start to first visible text fragment / completion; it includes loading on cold turns and excludes keyboard, rendering and speech playback.

`HARU_BUILD_ONLY=1 bash scripts/build-ipa.sh` creates an unsigned IPA and skips signing/upload even if App Store Connect secrets exist. The current workflow has no inputs, so the exact commit trailers `Haru-Build-Only: true` and `Haru-Dolphin-Smoke: true` provide equivalent controls for workflow_dispatch on a qualification branch. Build-only commits must keep the trailer when amended. A normal release requires an intentional subsequent commit without the build-only trailer.

Before release qualification on iPhone 15 Pro Max: test first download, interrupted/resumed download, airplane-mode cold launch, several long turns, stop/retry, app background/foreground, memory pressure, 1,024 vs 2,048 context, removing/reimporting the model, and selected server read-aloud. Record physical-device time to first visible text, warm/cold completion, heat and memory termination. This change does not measure or alter end-to-end call latency.

Model source: https://huggingface.co/cognitivecomputations/dolphin-2.9.3-mistral-7B-32k (Apache 2.0). Quantization: https://huggingface.co/bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF, revision `740ce4567b3392bd065637d2ac29127ca417cc45`. llama.cpp: https://github.com/ggml-org/llama.cpp/tree/b5046 (MIT; notice in app settings).
