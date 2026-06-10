# Test fixtures

## two_speakers_16k.wav

A ~30s synthetic two-speaker conversation in an **A-B-A** pattern, used by
`tests/cli/test_functional.bash` to verify real diarization end-to-end:

| turn | speaker | voice | ~timing |
|------|---------|-------|---------|
| 1 | "Alice" | ElevenLabs *Rachel* (female) | 0–11.4s |
| — | 1s silence | | |
| 2 | "Bob" | ElevenLabs *Adam* (male) | 12.4–23.4s |
| — | 1s silence | | |
| 3 | "Alice" again | ElevenLabs *Rachel* | 24.4–30.4s |

The A-B-A shape matters: it tests that clustering *re-identifies* the first
speaker after an intervening voice, not merely that it can split on a pause.

Format: WAV, mono, 16 kHz, s16le — the rate/channel layout speakrs expects
(tests still decode through ffmpeg to f32, same as production callers).

Provenance: generated 2026-06-10 with the ElevenLabs TTS API
(`eleven_multilingual_v2`, voices Rachel `21m00Tcm4TlvDq8ikWAM` and Adam
`pNInz6obpgDQGcFmaJgB`, `output_format=pcm_16000`), clips concatenated with
1s of digital silence. Fully synthetic — no real person's voice or rights
involved. Regenerate with different text/voices if it ever needs replacing;
the functional test's assertions are structural (2 speakers, A-B-A), not
timing-exact.
