#!/usr/bin/env bash
# Functional diarization test against the committed two-speaker fixture.
#
# The fixture (tests/fixtures/two_speakers_16k.wav) is an A-B-A conversation:
# speaker Alice, 1s pause, speaker Bob, 1s pause, Alice again — synthesized
# with two clearly different ElevenLabs voices (see tests/fixtures/README.md).
# Assertions are structural, not timing-exact, so they're robust to model
# updates: exactly 2 speakers found, both with substantial speech, and the
# first/last speech belongs to the same speaker while the middle differs.
#
# Env:
#   SPEAKRS_DIARIZE_BIN      (required) path to speakrs-diarize
#   SPEAKRS_FFI_MODELS_DIR   (optional) offline models dir → --models-dir
#   SPEAKRS_FFI_MODE         (optional) execution mode (default: cpu when
#                            models dir given — hermetic; else platform default)
# NOTE: no `set -e` — commands under test may legitimately fail.
set -u

BIN="${SPEAKRS_DIARIZE_BIN:?set SPEAKRS_DIARIZE_BIN to the speakrs-diarize binary}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="${SPEAKRS_FFI_FIXTURE:-$HERE/../fixtures/two_speakers_16k.wav}"
TMP="${TMPDIR:-/tmp}/speakrs_ffi_functional_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$FIXTURE" ]; then
	echo "FAIL: fixture missing: $FIXTURE" >&2
	exit 1
fi

args=()
if [ -n "${SPEAKRS_FFI_MODELS_DIR:-}" ]; then
	args+=(--models-dir "$SPEAKRS_FFI_MODELS_DIR" --mode "${SPEAKRS_FFI_MODE:-cpu}")
elif [ -n "${SPEAKRS_FFI_MODE:-}" ]; then
	args+=(--mode "$SPEAKRS_FFI_MODE")
fi

ffmpeg -v error -i "$FIXTURE" -f f32le -ac 1 -ar 16000 "$TMP/fixture.pcm" || {
	echo "FAIL: ffmpeg could not decode fixture" >&2
	exit 1
}

out=$("$BIN" "${args[@]}" "$TMP/fixture.pcm" 2>"$TMP/stderr.log")
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "FAIL: speakrs-diarize exited $rc" >&2
	printf '%s\n' "$out" >&2
	cat "$TMP/stderr.log" >&2
	exit 1
fi

printf '%s' "$out" > "$TMP/out.json"
python3 - "$TMP/out.json" <<'EOF'
import json, sys
from collections import defaultdict

d = json.load(open(sys.argv[1]))
failures = []

def check(cond, msg):
	if cond:
		print(f"PASS: {msg}")
	else:
		failures.append(msg)
		print(f"FAIL: {msg}", file=sys.stderr)

check(d.get("ok") is True, "result ok:true")
segs = d.get("segments", [])
check(len(segs) >= 3, f"at least 3 segments (A-B-A turns; got {len(segs)})")

speakers = d.get("speakers", [])
check(len(speakers) == 2, f"exactly 2 speakers detected (got {len(speakers)}: {speakers})")

talk = defaultdict(float)
for s in segs:
	talk[s["speaker"]] += s["end"] - s["start"]
for sp, t in sorted(talk.items()):
	check(t >= 2.0, f"{sp} has substantial speech ({t:.1f}s >= 2.0s)")

if segs and len(speakers) == 2:
	first, last = segs[0]["speaker"], segs[-1]["speaker"]
	check(first == last, f"first and last speech are the same speaker (A-B-A; {first} vs {last})")
	other = [sp for sp in speakers if sp != first]
	check(len(other) == 1 and any(s["speaker"] == other[0] for s in segs[1:-1]),
	      "the other speaker appears in the middle (B of A-B-A)")

sys.exit(1 if failures else 0)
EOF
rc=$?

echo
if [ "$rc" -eq 0 ]; then
	echo "Functional diarization test PASSED."
else
	echo "Functional diarization test FAILED." >&2
	printf 'raw output: %s\n' "$out" >&2
fi
exit "$rc"
