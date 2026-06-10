# PLAN

- [x] Scaffold project (2026-06-10 EST) (Cargo crate, flake, jj repo, canonical symlinks)
- [x] FFI surface TDD (2026-06-10 EST, 9 tests + mutation-validated): failing Rust tests → implementation (error paths, panic safety)
- [x] C header + C CLI (2026-06-10 EST, 10 CLI tests) (`speakrs-diarize`) + bash CLI tests
- [x] Flake package build (2026-06-10 EST: nix build + flake check green; nix-built CLI verified on real audio)
- [x] GitHub repo + Garnix green, all 5 builds incl. both Linux targets (2026-06-10 EST)
- [x] Local real-model smoke test (2026-06-10 EST: 21.5min video → 5.8s warm, 8 speakers, 207 turns)
- [x] Tagged 20260610.f3d64c8 (2026-06-10 EST)
- [ ] (consumer, tracked in reclip) reclip flake input + ctypes binding + merge/naming pipeline

## Curiosity pokes
- Does `openblas-system` resolve via pkg-config cleanly on darwin? (empirical)
- Does CoreML mode really never dlopen ort? (verify with `--mode coreml` and no ORT_DYLIB_PATH)
- Pipeline construction cost per call — if >1s, add opaque-handle API (new/run/free) later
- Stereo/non-16k input is the caller's bug — consider a sample-rate sanity heuristic? (deferred; documented contract instead)

## Functional fixture test (added 2026-06-10)
- [x] Two-speaker A-B-A fixture via ElevenLabs (Rachel/Adam, 30.4s) — tests/fixtures/
- [x] tests/cli/test_functional.bash: structural assertions (2 speakers, A-B-A, talk time)
- [x] Local pass in both coreml and cpu modes
- [x] Sandboxed checks.functional-test green locally (2026-06-10 EST); Garnix pending
