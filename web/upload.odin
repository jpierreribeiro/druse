package web
// druse:file application

import transport "druse:web/internal/transport"

// Phase 7.5-C2 — the public opt-in large-body upload API.
//
// The Phase-7 spool substrate (`web/internal/ingest`) was built and tested but
// never wired into the request path; the buffered `max_body` cap answered every
// larger body with 413. This is the smallest public surface that wires it in:
// an App opts in with `enable_upload`, and a request body OVER `max_body` is
// then consumed to an owned, bounded spool instead of refused. Its Handler takes
// ownership with `upload`; the file is deleted automatically at request teardown
// unless the Handler transfers it with `upload_persist`. Bodies within `max_body`
// — and chunked bodies — are unaffected: the buffered path is unchanged.
//
// The spool enforces the §4.2 contract (per-upload and process quotas mid-body,
// bounded memory, generated 0600 filenames in an app-designated directory,
// exactly-once cleanup on every terminal path, admission refusal before a byte
// is read, drain cancellation). This surface only NAMES it.

// Upload_Config is the opt-in. `dir` is REQUIRED — the core never writes to a
// silent /tmp an operator did not choose. Zero quota/limit fields select the
// §4.2 registered defaults (1 GiB per upload, 8 GiB per process, 64 KiB memory
// prefix, and handler-lanes − 1 concurrent spools).
Upload_Config :: struct {
	// The directory spools are written into. **It is owned by exactly ONE
	// server instance** (audit M8), and that is a contract rather than a
	// preference: `enable_upload` SWEEPS leftover `druse-spool-` files out of
	// it at boot, because a crash or a `kill -9` leaves partials behind and
	// nothing else ever removes them — they accumulate across restarts until a
	// disk fills.
	//
	// Two instances sharing one directory therefore delete each other's live
	// spools on startup. There is no portable way to tell a live spool from an
	// abandoned one: an mtime threshold races a slow upload, and file locks are
	// not in the pinned core. Give each instance its own directory.
	//
	// Only the framework's own `druse-spool-` prefix is swept; anything else
	// in the directory is left alone.
	dir:               string,
	per_upload_quota:  i64,
	process_quota:     i64,
	max_concurrent:    int,
	memory_prefix_max: int,
}

// enable_upload turns on spooled large-body ingestion for this App. It must be
// called before `serve` and before any route registration or dispatch, like
// every other App-level setting (WP17 fail-closed ordering); a call after that
// is refused, not silently raced.
enable_upload :: proc(a: ^App, cfg: Upload_Config, loc := #caller_location) {
	// Same fail-closed ordering guard as `web.limits`: reject (and report) a
	// configuration that arrives after the App began serving or dispatched,
	// rather than racing the immutable snapshot. A prior poison stands.
	if app_is_serving(a) {
		app_reject_late_configuration(a, loc)
		return
	}
	if a.private.poisoned {
		return
	}
	if app_has_dispatched(a) {
		app_reject_late_configuration(a, loc)
		return
	}
	a.private.upload_enabled = true
	a.private.upload = cfg
}

// Upload describes a request body that was spooled to disk. `path` is the
// on-disk location (a generated name under the configured directory) and `size`
// its byte length; both are valid for the duration of the Handler. The upload is
// owned by the REQUEST, not by this value — it is a plain description, carrying
// no framework pointer (G-03). The file is deleted exactly once at request
// teardown UNLESS `upload_persist` transfers ownership out of the spool
// namespace.
Upload :: struct {
	path: string,
	size: i64,
}

// upload returns this request's spooled upload, or ok=false when the body was
// not spooled: it was within `max_body` (use `web.body`/`web.form_file`), the
// App did not `enable_upload`, or the request ran on the in-memory test
// transport.
//
// AUDIT M7 — WHAT IS IN THE FILE, WHEN THE BODY WAS A MULTIPART FORM. The
// spool holds the request body EXACTLY AS IT ARRIVED. For a
// `multipart/form-data` request that means the framing too, not the file the
// user picked. Measured, with `max_body` at 4096 and the same form sent twice:
//
//	within the cap   upload=no   form_field("caption")="hello"  form_file("photo")=100 bytes
//	over the cap     upload=yes  form_field=UNAVAILABLE         form_file=UNAVAILABLE
//	                 and the file's first bytes are:
//	                 `--B\r\nContent-Disposition: form-data; name="caption"\r\n\r\nhello`
//
// So an application that uploads a photo and crosses `max_body` receives a
// path whose first bytes are a boundary marker rather than a JPEG, and the two
// accessors it was using stop answering — silently, because `ok=false` is also
// what "no such field" looks like.
//
// THIS IS NOT AN OVERSIGHT WAITING FOR A STREAMING PARSER. One exists in
// `web/internal/ingest/multipart.odin` and is deliberately NOT wired: it
// appends to a carry buffer byte-by-byte and runs a substring search per byte,
// so wiring it would trade a documented limitation for a quadratic one. Parse
// the spooled file with a parser you choose, or keep multipart uploads under
// `max_body` and use `form_file`.
upload :: proc(ctx: ^Context) -> (up: Upload, ok: bool) {
	sp := ctx.private.upload
	if sp == nil {
		return {}, false
	}
	return Upload{path = transport.upload_path(sp), size = transport.upload_size(sp)}, true
}

// upload_persist transfers THIS REQUEST's spooled body to `destination` (an
// explicit rename out of the spool namespace) and hands ownership to the
// application: after it succeeds, request teardown will NOT delete the file.
// Persist is keyed on the Context, not on the `Upload` value, because the upload
// belongs to the request (and so the public surface carries no framework
// pointer). Returns false if the body was not spooled, is already terminal, or
// the rename failed (e.g. a cross-filesystem destination) — in which case
// teardown still cleans up.
upload_persist :: proc(ctx: ^Context, destination: string) -> bool {
	sp := ctx.private.upload
	if sp == nil {
		return false
	}
	return transport.upload_persist(sp, destination)
}
