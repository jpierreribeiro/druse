package transport

import ingest "druse:web/internal/ingest"

// Phase 7.5-C2 — the transport boundary's upload accessors.
//
// `package web` may NOT import `web/internal/ingest` directly (ADR-009: only the
// transport boundary may name a private lifecycle package), exactly as it names
// the stream registry only through `stream_begin`/`stream_send` here rather than
// importing `web/internal/stream`. These thin wrappers let `web.upload` /
// `web.upload_persist` and the driver's teardown operate on the owned spool
// through its opaque handle (the `^ingest.Spool` carried as a `rawptr` in
// `Inbound.upload` / the Context) without the core ever naming the ingest type.

// upload_path returns the spooled body's on-disk path, or "" for a nil handle.
upload_path :: proc(handle: rawptr) -> string {
	if handle == nil {
		return ""
	}
	return ingest.spool_path((^ingest.Spool)(handle))
}

// upload_size returns the spooled body's byte length, or 0 for a nil handle.
upload_size :: proc(handle: rawptr) -> i64 {
	if handle == nil {
		return 0
	}
	return ingest.spooled_bytes((^ingest.Spool)(handle))
}

// upload_persist transfers the spooled body out of the spool namespace (a
// rename); after it succeeds, teardown will not delete the file. Nil handle or a
// non-Ready/terminal spool returns false.
upload_persist :: proc(handle: rawptr, destination: string) -> bool {
	if handle == nil {
		return false
	}
	return ingest.persist((^ingest.Spool)(handle), destination)
}

// upload_cancel is the driver's teardown cleanup: it deletes the spooled file
// exactly once, and is a no-op if the handle is nil or the spool was already
// persisted or cancelled. The reason is advisory — cancel cleans up regardless.
upload_cancel :: proc(handle: rawptr) {
	if handle == nil {
		return
	}
	ingest.cancel((^ingest.Spool)(handle), .Disconnected)
}
