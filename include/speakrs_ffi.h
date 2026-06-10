/* speakrs_ffi.h — C FFI for the speakrs speaker-diarization library.
 *
 * Contract: pure in-memory transform. The caller decodes audio to mono
 * 16 kHz f32 PCM (range [-1.0, 1.0]) — e.g. via:
 *   ffmpeg -i in.mp3 -f f32le -ac 1 -ar 16000 out.pcm
 * and passes the raw sample buffer. All results, including every error,
 * come back as a JSON string. Panics never cross this boundary.
 */
#ifndef SPEAKRS_FFI_H
#define SPEAKRS_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version as a static NUL-terminated string. Do NOT free. */
const char *speakrs_ffi_version(void);

/* Diarize `num_samples` mono 16 kHz f32 PCM samples.
 *
 * opts_json: NULL for defaults, or a JSON object:
 *   {
 *     "mode": "cpu" | "coreml" | "coreml-fast" | "cuda" | "cuda-fast" | "migraphx",
 *     "models_dir": "/path/to/models"   // optional; omit = auto-download (HF)
 *   }
 * Default mode: "coreml" on macOS, "cpu" elsewhere.
 *
 * Returns a heap-allocated NUL-terminated JSON string; release it with
 * speakrs_ffi_free(). Never returns NULL.
 *   success: {"ok":true,"segments":[{"start":s,"end":e,"speaker":"SPEAKER_00"},...],
 *             "speakers":["SPEAKER_00",...]}
 *   failure: {"error":"message","ok":false}
 */
char *speakrs_ffi_diarize(const float *samples, size_t num_samples,
                          const char *opts_json);

/* Free a string returned by speakrs_ffi_diarize. NULL is a no-op. */
void speakrs_ffi_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* SPEAKRS_FFI_H */
