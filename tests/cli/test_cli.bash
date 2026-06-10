#!/usr/bin/env bash
# CLI surface tests for speakrs-diarize. Error paths only — no models, no
# network — so this runs identically in the Nix sandbox and locally.
# NOTE: deliberately no `set -e`; commands under test are EXPECTED to fail.
set -u

BIN="${SPEAKRS_DIARIZE_BIN:?set SPEAKRS_DIARIZE_BIN to the speakrs-diarize binary}"
TMP="${TMPDIR:-/tmp}/speakrs_ffi_cli_test_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# 1 second of silence: 16000 f32le samples = 64000 zero bytes
head -c 64000 /dev/zero > "$TMP/silence.pcm"

# --- help / about / version ---
out=$("$BIN" --help 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Usage:"; then
	pass "--help exits 0 with usage"
else
	fail "--help (rc=$rc)"
fi

out=$("$BIN" --about 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "speakrs-diarize" && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]; then
	pass "--about is one line"
else
	fail "--about (rc=$rc, out=$out)"
fi

out=$("$BIN" --version 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+'; then
	pass "--version prints semver"
else
	fail "--version (rc=$rc, out=$out)"
fi

# --- argument errors ---
out=$("$BIN" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no input"; then
	pass "no args errors"
else
	fail "no args (rc=$rc)"
fi

out=$("$BIN" --bogus-flag x 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "unknown option"; then
	pass "unknown option errors"
else
	fail "unknown option (rc=$rc)"
fi

out=$("$BIN" "$TMP/does-not-exist.pcm" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "cannot open"; then
	pass "missing input file errors"
else
	fail "missing input file (rc=$rc)"
fi

# --- FFI error paths (JSON to stdout, exit 1) ---
out=$("$BIN" --opts '{ not json' "$TMP/silence.pcm" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"ok":false' && printf '%s' "$out" | grep -q "parse error"; then
	pass "invalid opts JSON returns error JSON"
else
	fail "invalid opts JSON (rc=$rc, out=$out)"
fi

out=$("$BIN" --mode warp9 --models-dir /nonexistent "$TMP/silence.pcm" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "warp9"; then
	pass "unknown mode returns error JSON"
else
	fail "unknown mode (rc=$rc, out=$out)"
fi

out=$("$BIN" --mode cpu --models-dir "/nonexistent/speakrs models dir" "$TMP/silence.pcm" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"ok":false' && printf '%s' "$out" | grep -q "models_dir"; then
	pass "nonexistent models dir (with spaces) returns error JSON"
else
	fail "models dir with spaces (rc=$rc, out=$out)"
fi

# empty input via stdin
out=$(printf '' | "$BIN" --mode cpu --models-dir /nonexistent - 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "num_samples"; then
	pass "empty stdin returns error JSON"
else
	fail "empty stdin (rc=$rc, out=$out)"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "All CLI tests passed."
else
	echo "$failures CLI test(s) FAILED." >&2
fi
exit "$failures"
