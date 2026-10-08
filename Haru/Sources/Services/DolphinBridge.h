#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
void * haru_cancel_create(void);
void haru_cancel_set(void * signal);
bool haru_cancelled(void * signal);
void haru_cancel_free(void * signal);
void * haru_llama_open(const char * path, int32_t context_size, bool gpu, void * signal);
void haru_llama_close(void * handle);
int32_t haru_llama_count(void * handle, const char * prompt);
// The callback is synchronous on the inference queue. Its bytes expire on return.
typedef bool (*haru_token_callback)(const char *, int32_t, void *);
// 0 = end of turn; 1 = length limit; 2 = stopped; negative = decode error.
int32_t haru_llama_generate(void * handle, const char * prompt, int32_t limit,
                           void * signal, haru_token_callback callback, void * user,
                           int32_t * generated);
#ifdef __cplusplus
}
#endif
