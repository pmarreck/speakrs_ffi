/* speakrs-diarize — C CLI for speakrs_ffi, dogfooding the public C FFI.
 *
 * Reads raw f32le mono 16 kHz PCM from a file or stdin, prints the JSON
 * diarization result to stdout. Decode anything to that format with:
 *   ffmpeg -i input.mp3 -f f32le -ac 1 -ar 16000 - | speakrs-diarize -
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <speakrs_ffi.h>

#if defined(__aarch64__) || defined(_M_ARM64)
#define ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define ARCH "x86_64"
#else
#define ARCH "unknown-arch"
#endif

#if defined(__APPLE__)
#define OS "macos"
#elif defined(__linux__)
#define OS "linux"
#else
#define OS "unknown-os"
#endif

static void usage(FILE *to) {
	fprintf(to,
		"Usage: speakrs-diarize [OPTIONS] <pcm-file | - | @stdin>\n"
		"\n"
		"Input: raw f32le mono 16 kHz PCM samples ('-' or '@stdin' for stdin).\n"
		"  ffmpeg -i input.mp3 -f f32le -ac 1 -ar 16000 - | speakrs-diarize -\n"
		"\n"
		"Options:\n"
		"  --mode MODE        cpu | coreml | coreml-fast | cuda | cuda-fast | migraphx\n"
		"                     (default: coreml on macOS, cpu elsewhere)\n"
		"  --models-dir DIR   load models from DIR instead of auto-downloading\n"
		"  --opts JSON        raw options JSON (overrides --mode/--models-dir)\n"
		"  -h, --help         this help\n"
		"  --about            one-line description\n"
		"  --version          library version\n"
		"\n"
		"Output: JSON to stdout. Exit 0 on success, 1 on any error.\n");
}

/* Minimal JSON string escaper for embedding paths in opts (handles \" \\ and
 * control chars; paths with spaces pass through untouched). */
static void json_escape_into(char *dst, size_t dstlen, const char *src) {
	size_t j = 0;
	for (size_t i = 0; src[i] && j + 7 < dstlen; i++) {
		unsigned char c = (unsigned char)src[i];
		if (c == '"' || c == '\\') {
			dst[j++] = '\\';
			dst[j++] = (char)c;
		} else if (c < 0x20) {
			j += (size_t)snprintf(dst + j, dstlen - j, "\\u%04x", c);
		} else {
			dst[j++] = (char)c;
		}
	}
	dst[j] = '\0';
}

static float *read_all_f32(FILE *f, size_t *out_count) {
	size_t cap = 1 << 20, len = 0; /* bytes */
	unsigned char *buf = malloc(cap);
	if (!buf) return NULL;
	size_t n;
	while ((n = fread(buf + len, 1, cap - len, f)) > 0) {
		len += n;
		if (len == cap) {
			cap *= 2;
			unsigned char *nb = realloc(buf, cap);
			if (!nb) { free(buf); return NULL; }
			buf = nb;
		}
	}
	if (len % 4 != 0)
		fprintf(stderr, "warning: input size %zu is not a multiple of 4; trailing bytes ignored\n", len);
	*out_count = len / 4;
	return (float *)buf;
}

int main(int argc, char **argv) {
	const char *mode = NULL, *models_dir = NULL, *raw_opts = NULL, *input = NULL;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "/h")) {
			usage(stdout);
			return 0;
		} else if (!strcmp(a, "--about")) {
			printf("speakrs-diarize %s — speaker diarization (speakrs C FFI) for %s/%s\n",
			       speakrs_ffi_version(), OS, ARCH);
			return 0;
		} else if (!strcmp(a, "--version")) {
			printf("%s\n", speakrs_ffi_version());
			return 0;
		} else if (!strcmp(a, "--mode") && i + 1 < argc) {
			mode = argv[++i];
		} else if (!strcmp(a, "--models-dir") && i + 1 < argc) {
			models_dir = argv[++i];
		} else if (!strcmp(a, "--opts") && i + 1 < argc) {
			raw_opts = argv[++i];
		} else if (!strcmp(a, "--")) {
			if (i + 1 < argc) input = argv[++i];
		} else if (a[0] == '-' && strcmp(a, "-") != 0) {
			fprintf(stderr, "error: unknown option %s\n", a);
			usage(stderr);
			return 1;
		} else {
			input = a;
		}
	}

	if (!input) {
		fprintf(stderr, "error: no input file (use '-' or '@stdin' for stdin)\n");
		usage(stderr);
		return 1;
	}

	FILE *f;
	if (!strcmp(input, "-") || !strcmp(input, "@stdin")) {
		f = stdin;
	} else {
		f = fopen(input, "rb");
		if (!f) {
			fprintf(stderr, "error: cannot open %s\n", input);
			return 1;
		}
	}

	size_t num_samples = 0;
	float *samples = read_all_f32(f, &num_samples);
	if (f != stdin) fclose(f);
	if (!samples) {
		fprintf(stderr, "error: out of memory reading input\n");
		return 1;
	}

	/* Assemble opts JSON */
	char opts_buf[8192];
	const char *opts = NULL;
	if (raw_opts) {
		opts = raw_opts;
	} else if (mode || models_dir) {
		char esc_mode[256] = "", esc_dir[4096] = "";
		if (mode) json_escape_into(esc_mode, sizeof esc_mode, mode);
		if (models_dir) json_escape_into(esc_dir, sizeof esc_dir, models_dir);
		int w = snprintf(opts_buf, sizeof opts_buf, "{%s%s%s%s%s%s%s}",
			mode ? "\"mode\":\"" : "", mode ? esc_mode : "", mode ? "\"" : "",
			(mode && models_dir) ? "," : "",
			models_dir ? "\"models_dir\":\"" : "", models_dir ? esc_dir : "",
			models_dir ? "\"" : "");
		if (w < 0 || (size_t)w >= sizeof opts_buf) {
			fprintf(stderr, "error: options too long\n");
			free(samples);
			return 1;
		}
		opts = opts_buf;
	}

	fprintf(stderr, "diarizing %zu samples (%.1fs of 16kHz audio)...\n",
	        num_samples, (double)num_samples / 16000.0);

	char *result = speakrs_ffi_diarize(samples, num_samples, opts);
	free(samples);
	if (!result) { /* contractually impossible, but belt and braces */
		fprintf(stderr, "error: library returned NULL\n");
		return 1;
	}

	printf("%s\n", result);
	int ok = strstr(result, "\"ok\":true") != NULL;
	speakrs_ffi_free(result);
	return ok ? 0 : 1;
}
