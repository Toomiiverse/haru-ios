#include "DolphinBridge.h"
#include <llama/llama.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>
#include <algorithm>
#include <TargetConditionals.h>

struct HaruLlama { llama_model * model; llama_context * context; };
static std::once_flag initialized;
static bool cancelled(void * p) { return p && static_cast<std::atomic<bool> *>(p)->load(); }
static bool loading(float, void * p) { return !cancelled(p); }
static void silent_log(enum ggml_log_level, const char *, void *) {} // no prompt/token logs

void * haru_cancel_create() { return new std::atomic<bool>(false); }
void haru_cancel_set(void * p) { static_cast<std::atomic<bool> *>(p)->store(true); }
bool haru_cancelled(void * p) { return cancelled(p); }
void haru_cancel_free(void * p) { delete static_cast<std::atomic<bool> *>(p); }

void * haru_llama_open(const char * path, int32_t size, bool gpu, void * signal) {
    if (cancelled(signal) || (size != 1024 && size != 2048)) return nullptr;
    std::call_once(initialized, [] { llama_log_set(silent_log, nullptr); llama_backend_init(); });
    auto mp = llama_model_default_params();
#if TARGET_OS_SIMULATOR
    gpu = false;
#endif
    mp.n_gpu_layers = gpu && llama_supports_gpu_offload() ? 99 : 0;
    mp.use_mmap = true;
    mp.use_mlock = false;
    mp.progress_callback = loading;
    mp.progress_callback_user_data = signal;
    auto model = llama_model_load_from_file(path, mp);
    if (!model) return nullptr;
    if (cancelled(signal)) { llama_model_free(model); return nullptr; }
    auto cp = llama_context_default_params();
    cp.n_ctx = size;
    cp.n_batch = 128;
    cp.n_ubatch = 64;
    cp.n_threads = 4;
    cp.n_threads_batch = 4;
    cp.flash_attn = false;
    cp.offload_kqv = mp.n_gpu_layers > 0;
    auto context = llama_init_from_model(model, cp);
    if (!context) { llama_model_free(model); return nullptr; }
    return new HaruLlama{model, context};
}

void haru_llama_close(void * ptr) {
    if (!ptr) return;
    auto h = static_cast<HaruLlama *>(ptr);
    llama_free(h->context);
    llama_model_free(h->model);
    delete h;
}

static std::vector<llama_token> tokens(HaruLlama * h, const char * text) {
    auto vocab = llama_model_get_vocab(h->model);
    int32_t needed = llama_tokenize(vocab, text, (int32_t)strlen(text), nullptr, 0, true, true);
    if (needed >= 0) return {};
    std::vector<llama_token> result(-needed);
    auto n = llama_tokenize(vocab, text, (int32_t)strlen(text), result.data(), (int32_t)result.size(), true, true);
    if (n < 0) return {};
    result.resize(n);
    return result;
}

int32_t haru_llama_count(void * ptr, const char * text) {
    return (int32_t)tokens(static_cast<HaruLlama *>(ptr), text).size();
}

int32_t haru_llama_generate(void * ptr, const char * prompt, int32_t limit,
                           void * signal, haru_token_callback callback, void * user,
                           int32_t * generated) {
    auto h = static_cast<HaruLlama *>(ptr);
    auto input = tokens(h, prompt);
    *generated = 0;
    if (input.empty() || input.size() + limit > llama_n_ctx(h->context)) return -1;
    llama_kv_self_clear(h->context);
    llama_set_abort_callback(h->context, cancelled, signal);
    struct AbortReset { llama_context * c; ~AbortReset() { llama_set_abort_callback(c, nullptr, nullptr); } } reset{h->context};
    for (size_t i = 0; i < input.size(); i += 128) {
        if (cancelled(signal)) return 2;
        auto batch = llama_batch_get_one(input.data() + i, (int32_t)std::min(size_t(128), input.size() - i));
        if (llama_decode(h->context, batch) != 0) return cancelled(signal) ? 2 : -2;
    }
    auto sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    struct SamplerFree { llama_sampler * s; ~SamplerFree() { llama_sampler_free(s); } } release{sampler};
    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    auto vocab = llama_model_get_vocab(h->model);
    for (int n = 0; n < limit; n++) {
        if (cancelled(signal)) return 2;
        llama_token token = llama_sampler_sample(sampler, h->context, -1);
        if (llama_vocab_is_eog(vocab, token)) return 0;
        std::vector<char> piece(256);
        int size = llama_token_to_piece(vocab, token, piece.data(), (int)piece.size(), 0, true);
        if (size < 0) {
            piece.resize(-size);
            size = llama_token_to_piece(vocab, token, piece.data(), (int)piece.size(), 0, true);
        }
        if (size < 0) return -3;
        ++*generated;
        if (size && !callback(piece.data(), size, user)) return cancelled(signal) ? 2 : 0;
        if (n + 1 < limit) {
            auto batch = llama_batch_get_one(&token, 1);
            if (llama_decode(h->context, batch) != 0) return cancelled(signal) ? 2 : -2;
        }
    }
    return 1;
}
