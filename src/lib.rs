//! C FFI for the speakrs speaker-diarization library.
//!
//! Design: pure in-memory transform — PCM samples in, JSON string out.
//! No file I/O, no audio decoding; callers (Python via ctypes, the C CLI,
//! anything else) decode audio themselves (e.g. ffmpeg → f32le mono 16kHz)
//! and pass a raw sample buffer. This keeps the library deterministic and
//! trivially testable, and matches the hexagonal core-vs-adapter split.
//!
//! Error contract: every failure — including a Rust panic — is returned as
//! a JSON `{"ok":false,"error":"..."}` string. Panics never unwind across
//! the FFI boundary (undefined behavior); `catch_unwind` wraps everything.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::{Deserialize, Serialize};

/// NUL-terminated version string, valid for the life of the process.
static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

// ---------------------------------------------------------------------------
// Public C ABI
// ---------------------------------------------------------------------------

/// Returns the library version as a static NUL-terminated string.
/// The caller must NOT free this pointer.
#[no_mangle]
pub extern "C" fn speakrs_ffi_version() -> *const c_char {
	VERSION.as_ptr() as *const c_char
}

/// Diarize a buffer of mono 16 kHz f32 PCM samples (range [-1.0, 1.0]).
///
/// `opts_json` may be NULL (defaults apply) or a JSON object:
/// ```json
/// {
///   "mode": "cpu" | "coreml" | "coreml-fast" | "cuda" | "cuda-fast" | "migraphx",
///   "models_dir": "/path/to/models"   // optional; omit to auto-download (HF)
/// }
/// ```
/// Default mode is "coreml" on macOS, "cpu" elsewhere.
///
/// Returns a heap-allocated NUL-terminated JSON string the caller must
/// release with `speakrs_ffi_free`:
/// - success: `{"ok":true,"segments":[{"start":s,"end":e,"speaker":"SPEAKER_00"},...],"speakers":[...]}`
/// - failure: `{"ok":false,"error":"message"}`
///
/// # Safety
/// `samples` must point to `num_samples` valid f32s (or be NULL with
/// `num_samples == 0`); `opts_json` must be NULL or a valid NUL-terminated
/// C string.
#[no_mangle]
pub unsafe extern "C" fn speakrs_ffi_diarize(
	samples: *const f32,
	num_samples: usize,
	opts_json: *const c_char,
) -> *mut c_char {
	let result = catch_unwind(AssertUnwindSafe(|| diarize_impl(samples, num_samples, opts_json)));
	let json = match result {
		Ok(json) => json,
		Err(panic) => error_json(&format!("internal panic: {}", panic_message(&panic))),
	};
	into_c_string(json)
}

/// Free a string returned by `speakrs_ffi_diarize`. NULL is a no-op.
///
/// # Safety
/// `s` must be a pointer previously returned by this library (or NULL),
/// and must not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn speakrs_ffi_free(s: *mut c_char) {
	if !s.is_null() {
		drop(CString::from_raw(s));
	}
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
struct Opts {
	#[serde(default)]
	mode: Option<String>,
	#[serde(default)]
	models_dir: Option<String>,
}

#[derive(Serialize)]
struct SegmentOut {
	start: f64,
	end: f64,
	speaker: String,
}

#[derive(Serialize)]
struct SuccessOut {
	ok: bool,
	segments: Vec<SegmentOut>,
	speakers: Vec<String>,
}

const VALID_MODES: &str = "cpu, coreml, coreml-fast, cuda, cuda-fast, migraphx";

fn default_mode() -> &'static str {
	if cfg!(target_os = "macos") {
		"coreml"
	} else {
		"cpu"
	}
}

fn parse_mode(s: &str) -> Result<speakrs::ExecutionMode, String> {
	use speakrs::ExecutionMode as M;
	let mode = match s.to_ascii_lowercase().as_str() {
		"cpu" => M::Cpu,
		"coreml" => M::CoreMl,
		"coreml-fast" | "coreml_fast" => M::CoreMlFast,
		"cuda" => M::Cuda,
		"cuda-fast" | "cuda_fast" => M::CudaFast,
		"migraphx" => M::MiGraphX,
		other => return Err(format!("unknown mode {other:?}; valid modes: {VALID_MODES}")),
	};
	if matches!(mode, M::CoreMl | M::CoreMlFast) && !cfg!(target_os = "macos") {
		return Err(format!("mode {s:?} requires macOS (CoreML); valid here: cpu, cuda, cuda-fast, migraphx"));
	}
	Ok(mode)
}

fn diarize_impl(samples: *const f32, num_samples: usize, opts_json: *const c_char) -> String {
	// --- validate sample buffer ---
	if samples.is_null() && num_samples > 0 {
		return error_json("samples pointer is NULL but num_samples > 0");
	}
	if num_samples == 0 {
		return error_json("num_samples is 0 — nothing to diarize");
	}

	// --- parse opts ---
	let opts: Opts = if opts_json.is_null() {
		Opts::default()
	} else {
		let raw = match unsafe { CStr::from_ptr(opts_json) }.to_str() {
			Ok(s) => s,
			Err(_) => return error_json("opts_json is not valid UTF-8"),
		};
		match serde_json::from_str(raw) {
			Ok(o) => o,
			Err(e) => return error_json(&format!("opts_json parse error: {e}")),
		}
	};

	let mode = match parse_mode(opts.mode.as_deref().unwrap_or_else(|| default_mode())) {
		Ok(m) => m,
		Err(e) => return error_json(&e),
	};

	// --- build pipeline ---
	let mut pipeline = match &opts.models_dir {
		Some(dir) => {
			let path = std::path::Path::new(dir);
			if !path.is_dir() {
				return error_json(&format!("models_dir does not exist or is not a directory: {dir}"));
			}
			match speakrs::OwnedDiarizationPipeline::from_dir(path, mode) {
				Ok(p) => p,
				Err(e) => return error_json(&format!("failed to load models from {dir}: {e}")),
			}
		}
		None => match speakrs::OwnedDiarizationPipeline::from_pretrained(mode) {
			Ok(p) => p,
			Err(e) => return error_json(&format!("failed to load pretrained models: {e}")),
		},
	};

	// --- run ---
	let audio = unsafe { std::slice::from_raw_parts(samples, num_samples) };
	let result = match pipeline.run(audio) {
		Ok(r) => r,
		Err(e) => return error_json(&format!("diarization failed: {e}")),
	};

	use speakrs::pipeline::{FRAME_DURATION_SECONDS, FRAME_STEP_SECONDS};
	let segments: Vec<SegmentOut> = result
		.discrete_diarization
		.to_segments(FRAME_STEP_SECONDS, FRAME_DURATION_SECONDS)
		.into_iter()
		.map(|seg| SegmentOut {
			start: seg.start as f64,
			end: seg.end as f64,
			speaker: seg.speaker.to_string(),
		})
		.collect();

	let mut speakers: Vec<String> = segments.iter().map(|s| s.speaker.clone()).collect();
	speakers.sort();
	speakers.dedup();

	serde_json::to_string(&SuccessOut { ok: true, segments, speakers })
		.unwrap_or_else(|e| error_json(&format!("result serialization failed: {e}")))
}

fn error_json(msg: &str) -> String {
	serde_json::json!({ "ok": false, "error": msg }).to_string()
}

fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
	if let Some(s) = panic.downcast_ref::<&str>() {
		(*s).to_string()
	} else if let Some(s) = panic.downcast_ref::<String>() {
		s.clone()
	} else {
		"unknown panic payload".to_string()
	}
}

/// Convert a Rust String to a heap-allocated C string. Interior NULs are
/// replaced so conversion cannot fail (error messages may contain anything).
fn into_c_string(s: String) -> *mut c_char {
	let cleaned = s.replace('\0', "\u{FFFD}");
	CString::new(cleaned)
		.expect("no interior NULs after replacement")
		.into_raw()
}

// ---------------------------------------------------------------------------
// Tests — all sandbox-safe: no network, no model files. The happy path is
// covered by the gated integration test in tests/ and the CLI smoke test.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
	use super::*;
	use std::ffi::CString;

	/// Call diarize through the C ABI and return the parsed JSON.
	fn diarize_json(samples: &[f32], opts: Option<&str>) -> serde_json::Value {
		let opts_c = opts.map(|o| CString::new(o).unwrap());
		let ptr = unsafe {
			speakrs_ffi_diarize(
				if samples.is_empty() { std::ptr::null() } else { samples.as_ptr() },
				samples.len(),
				opts_c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
			)
		};
		assert!(!ptr.is_null(), "diarize must always return a string");
		let s = unsafe { CStr::from_ptr(ptr) }.to_str().expect("valid UTF-8").to_string();
		unsafe { speakrs_ffi_free(ptr) };
		serde_json::from_str(&s).expect("output must always be valid JSON")
	}

	#[test]
	fn version_is_non_null_and_semverish() {
		let v = unsafe { CStr::from_ptr(speakrs_ffi_version()) }.to_str().unwrap();
		assert!(!v.is_empty());
		// e.g. "0.1.0" — at least two dots-separated numeric components
		let parts: Vec<&str> = v.split('.').collect();
		assert!(parts.len() >= 2, "version {v:?} should look like semver");
		assert!(parts[0].chars().all(|c| c.is_ascii_digit()));
	}

	#[test]
	fn free_null_is_noop() {
		unsafe { speakrs_ffi_free(std::ptr::null_mut()) };
	}

	#[test]
	fn empty_samples_returns_error() {
		let out = diarize_json(&[], None);
		assert_eq!(out["ok"], false);
		assert!(out["error"].as_str().unwrap().contains("num_samples"));
	}

	#[test]
	fn null_samples_with_count_returns_error() {
		let opts = CString::new("{}").unwrap();
		let ptr = unsafe { speakrs_ffi_diarize(std::ptr::null(), 16000, opts.as_ptr()) };
		let s = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
		unsafe { speakrs_ffi_free(ptr) };
		let out: serde_json::Value = serde_json::from_str(&s).unwrap();
		assert_eq!(out["ok"], false);
		assert!(out["error"].as_str().unwrap().contains("NULL"));
	}

	#[test]
	fn invalid_opts_json_returns_error() {
		let out = diarize_json(&[0.0; 16000], Some("{ not json"));
		assert_eq!(out["ok"], false);
		assert!(out["error"].as_str().unwrap().contains("parse error"));
	}

	#[test]
	fn unknown_mode_returns_error_listing_valid_modes() {
		let out = diarize_json(&[0.0; 16000], Some(r#"{"mode":"warp9"}"#));
		assert_eq!(out["ok"], false);
		let msg = out["error"].as_str().unwrap();
		assert!(msg.contains("warp9"));
		assert!(msg.contains("coreml"), "error should list valid modes: {msg}");
	}

	#[test]
	fn nonexistent_models_dir_returns_error_without_network() {
		let out = diarize_json(
			&[0.0; 16000],
			Some(r#"{"mode":"cpu","models_dir":"/nonexistent/speakrs/models"}"#),
		);
		assert_eq!(out["ok"], false);
		assert!(out["error"].as_str().unwrap().contains("models_dir"));
	}

	#[test]
	fn empty_models_dir_fails_model_load_not_panic() {
		let dir = std::env::temp_dir().join(format!("speakrs_ffi_empty_{}", std::process::id()));
		std::fs::create_dir_all(&dir).unwrap();
		let opts = format!(r#"{{"mode":"cpu","models_dir":{:?}}}"#, dir.to_str().unwrap());
		let out = diarize_json(&[0.0; 16000], Some(&opts));
		std::fs::remove_dir_all(&dir).ok();
		assert_eq!(out["ok"], false);
		assert!(out["error"].as_str().unwrap().contains("failed to load models"));
	}

	#[test]
	fn coreml_mode_rejected_off_macos() {
		// On macOS this exercises the accept path far enough to fail later
		// (bad models dir); elsewhere it must fail fast with a platform error.
		let out = diarize_json(
			&[0.0; 16000],
			Some(r#"{"mode":"coreml","models_dir":"/nonexistent"}"#),
		);
		assert_eq!(out["ok"], false);
		if !cfg!(target_os = "macos") {
			assert!(out["error"].as_str().unwrap().contains("macOS"));
		}
	}
}
