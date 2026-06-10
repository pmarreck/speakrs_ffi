# speakrs_ffi

[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fspeakrs_ffi%3Fbranch%3Dyolo)](https://garnix.io/repo/pmarreck/speakrs_ffi)

C FFI for [speakrs](https://github.com/avencera/speakrs) — speaker diarization
(who spoke when) with pyannote-level accuracy at hundreds-of-× realtime, callable
from anything that speaks C: Python (`ctypes`), C, Zig, LuaJIT, Swift, …

```
consumer (Python / C CLI / …) ──► C FFI ──► speakrs (Rust: CoreML / ONNX Runtime)
```

Measured on an Apple Silicon Mac (CoreML mode): a 21.5-minute video diarized in
**5.8 seconds** (~220× realtime), 8 speakers, 207 turns.

## Design

**Pure in-memory transform: PCM samples in, JSON out.** The library does no
file I/O and no audio decoding — callers decode to mono 16 kHz f32 PCM first:

```sh
ffmpeg -i input.mp3 -f f32le -ac 1 -ar 16000 output.pcm
```

Every failure — including a Rust panic — returns as `{"ok":false,"error":"…"}`.
Panics never unwind across the FFI boundary.

## C API

```c
#include <speakrs_ffi.h>

const char *speakrs_ffi_version(void);                     /* static; do not free */
char *speakrs_ffi_diarize(const float *samples, size_t n,  /* mono 16 kHz f32 PCM */
                          const char *opts_json);          /* NULL = defaults     */
void speakrs_ffi_free(char *s);
```

Options JSON (all fields optional):

```json
{
  "mode": "coreml",            // cpu | coreml | coreml-fast | cuda | cuda-fast | migraphx
  "models_dir": "/path"        // omit → auto-download from HF on first use
}
```

Default mode is `coreml` on macOS, `cpu` elsewhere. Result:

```json
{"ok": true,
 "segments": [{"start": 0.14, "end": 0.99, "speaker": "SPEAKER_05"}, …],
 "speakers": ["SPEAKER_00", …]}
```

## CLI

`speakrs-diarize` is a C program that consumes the FFI exactly like any
external consumer (dogfooding the header and linkage):

```sh
ffmpeg -i talk.mp3 -f f32le -ac 1 -ar 16000 - | speakrs-diarize -
speakrs-diarize --mode coreml-fast --models-dir ~/models talk.pcm
```

JSON to stdout, progress to stderr, exit 0/1.

## Python (ctypes)

```python
import ctypes, json, subprocess

lib = ctypes.CDLL("libspeakrs_ffi.dylib")
lib.speakrs_ffi_diarize.restype = ctypes.c_void_p   # keep pointer for free()
lib.speakrs_ffi_diarize.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_size_t, ctypes.c_char_p]

pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", "in.mp3",
                      "-f", "f32le", "-ac", "1", "-ar", "16000", "-"],
                     capture_output=True, check=True).stdout
buf = (ctypes.c_float * (len(pcm) // 4)).from_buffer_copy(pcm)

ptr = lib.speakrs_ffi_diarize(buf, len(buf), None)
result = json.loads(ctypes.cast(ptr, ctypes.c_char_p).value)
lib.speakrs_ffi_free(ctypes.c_void_p(ptr))
```

## Building (Nix)

```sh
./build      # nix build → result/{lib,include,bin}
./test       # cargo tests + CLI tests (offline) + functional test (real models)
```

**Nothing downloads during the build** — that's the point of this packaging:

| upstream default | what it does | what we use instead |
|---|---|---|
| `default-linalg` | fetches Intel MKL / static OpenBLAS at build time | `openblas-system` → nixpkgs openblas via pkg-config |
| ort prebuilt binaries | downloads ONNX Runtime during the build | `load-dynamic` → dlopen at runtime via `ORT_DYLIB_PATH` |

Models (`avencera/speakrs-models`, no HF token needed) download at **runtime**
on first use, or load offline from `models_dir`. In CoreML mode, ONNX Runtime
is never loaded at all; for `cpu`/`cuda` modes set `ORT_DYLIB_PATH` to a
`libonnxruntime` (the Nix-built CLI has a default wired in; the flake exposes
it as `packages.<system>.default.passthru.ortLib`).

CI runs real diarization hermetically: `checks.functional-test` pins the
cpu-mode model files as fixed-output derivations and diarizes a committed
two-speaker fixture (A-B-A pattern -- see `tests/fixtures/README.md`) inside
the pure sandbox, asserting exactly two speakers and correct re-identification.

## As a flake input

```nix
inputs.speakrs-ffi.url = "github:pmarreck/speakrs_ffi";
# then: speakrs-ffi.packages.${system}.default → lib/, include/, bin/
```

## License

Apache-2.0, same as speakrs.
