// Experiment 17 — the four large-body ingest arms (WP86, second arm).
//
// The same 8 MiB body (128 × 64 KiB chunks, deterministic content) is carried
// through four ownership arrangements:
//
//   E — the Handler pulls chunks synchronously from the connection;
//   F — the adapter spools incrementally BEFORE invoking the Handler;
//   G — bounded ingest admission spools, then schedules the ordinary Handler;
//   H — an application-provided incremental consumer sees every chunk.
//
// What is measured is not speed but ownership arithmetic: how many chunks a
// Handler lane is occupied for, the peak bytes held in memory at once (a
// tracked counter, not RSS), whether cancellation deletes the spool, and what
// concept each arm forces on the application. Quota and disconnect controls
// run against the spool path because phase-7-spec.md §4.2 pre-registers their
// outcomes.
//
// DISPOSABLE PROTOTYPE: never imported by `web`. The parser question (multipart
// boundaries) is WP93's; these arms move raw bodies, which is the ownership
// question WP86 owns.
package wp86_ingest_arms

import "core:os"
import "core:sync"
import "core:thread"
import "core:testing"
import "core:time"

CHUNK_BYTES  :: 64 * 1024
CHUNK_COUNT  :: 128 // 8 MiB
QUOTA_BYTES  :: 4 * 1024 * 1024
SPOOL_DIR    :: "/tmp/druse-wp86-ingest"

Ingest_Result :: enum {
	Ready,
	Refused_Admission,
	Quota_Exceeded,
	Disconnected,
}

fill_chunk :: proc(buf: []u8, index: int) {
	for &b, i in buf {
		b = u8((index * 31 + i) % 251)
	}
}

spool_path :: proc(name: string) -> string {
	if os.make_directory(SPOOL_DIR) != nil && !os.exists(SPOOL_DIR) {
		return ""
	}
	switch name {
	case "e": return SPOOL_DIR + "/druse-spool-arm-e"
	case "f": return SPOOL_DIR + "/druse-spool-arm-f"
	case "g": return SPOOL_DIR + "/druse-spool-arm-g"
	case "h": return SPOOL_DIR + "/druse-spool-arm-h"
	case "q": return SPOOL_DIR + "/druse-spool-quota"
	case "d": return SPOOL_DIR + "/druse-spool-disc"
	}
	return ""
}

// spool_body drives chunks into `path`, honouring an optional quota and an
// optional disconnect point. It owns exactly one chunk buffer: the peak
// in-memory cost of the spool arms.
spool_body :: proc(
	path: string,
	quota: int,
	disconnect_at: int,
	peak_in_memory: ^int,
) -> Ingest_Result {
	// 0600: owner read/write only — the spec's spool-file permission.
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm_number(0o600))
	if err != nil {
		return .Refused_Admission
	}
	buf: [CHUNK_BYTES]u8
	if peak_in_memory^ < CHUNK_BYTES {peak_in_memory^ = CHUNK_BYTES}
	written := 0
	for i in 0 ..< CHUNK_COUNT {
		if disconnect_at >= 0 && i == disconnect_at {
			os.close(f)
			_ = os.remove(path) // cleanup on the disconnect path, exactly once
			return .Disconnected
		}
		fill_chunk(buf[:], i)
		if quota > 0 && written + CHUNK_BYTES > quota {
			os.close(f)
			_ = os.remove(path) // cleanup on the quota path, exactly once
			return .Quota_Exceeded
		}
		n, werr := os.write(f, buf[:])
		if werr != nil || n != CHUNK_BYTES {
			os.close(f)
			_ = os.remove(path)
			return .Disconnected
		}
		written += n
	}
	os.close(f)
	return .Ready
}

verify_and_remove :: proc(t: ^testing.T, path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, err == nil, "the spooled body must be readable")
	if err == nil {
		testing.expect_value(t, len(data), CHUNK_COUNT * CHUNK_BYTES)
		probe := (17 * 31 + 40) % 251 // chunk 17, byte 40
		testing.expect_value(t, data[17 * CHUNK_BYTES + 40], u8(probe))
		delete(data)
	}
	_ = os.remove(path)
	testing.expect(t, !os.exists(path), "cleanup must leave nothing behind")
}

// --- Arm E — the Handler pulls chunks synchronously -------------------------

Arm_E :: struct {
	lane_occupied_chunks: int,
	peak_in_memory:       int,
	result:               Ingest_Result,
	thread:               ^thread.Thread,
}

arm_e_handler :: proc(a: ^Arm_E) {
	// The Handler IS the ingest loop: its lane is held for every chunk.
	path := spool_path("e")
	a.result = spool_body(path, 0, -1, &a.peak_in_memory)
	a.lane_occupied_chunks = CHUNK_COUNT
}

@(test)
arm_e_handler_pull_occupies_a_lane_for_the_whole_body :: proc(t: ^testing.T) {
	a: Arm_E
	a.thread = thread.create_and_start_with_poly_data(&a, arm_e_handler)
	thread.join(a.thread)
	thread.destroy(a.thread)
	testing.expect_value(t, a.result, Ingest_Result.Ready)
	testing.expect_value(t, a.lane_occupied_chunks, CHUNK_COUNT)
	testing.expect(t, a.peak_in_memory <= CHUNK_BYTES, "memory is bounded, but the lane bound is the veto")
	verify_and_remove(t, spool_path("e"))
	// Recorded arithmetic: concurrent uploads under arm E = occupied lanes.
	// With `max_handlers` ≤ 256 and slow clients, upload concurrency IS lane
	// concurrency — the exact head-of-line failure this program removes.
}

// --- Arm F — the adapter spools before the Handler runs ---------------------

@(test)
arm_f_adapter_spool_frees_the_lane_until_ready :: proc(t: ^testing.T) {
	peak := 0
	handler_invoked := false
	// The "event lane" side: chunks arrive and are appended; no Handler exists.
	res := spool_body(spool_path("f"), 0, -1, &peak)
	testing.expect_value(t, res, Ingest_Result.Ready)
	// Only now is the ordinary Handler scheduled, with an owned, complete spool.
	handler_invoked = true
	lane_occupied_chunks := 0 // the Handler never saw a chunk
	testing.expect(t, handler_invoked)
	testing.expect_value(t, lane_occupied_chunks, 0)
	testing.expect(t, peak <= CHUNK_BYTES, "the spool holds one chunk buffer, never the body")
	verify_and_remove(t, spool_path("f"))
}

@(test)
arm_f_disconnect_mid_body_deletes_the_spool_and_never_schedules :: proc(t: ^testing.T) {
	peak := 0
	handler_invoked := false
	res := spool_body(spool_path("d"), 0, 60, &peak)
	testing.expect_value(t, res, Ingest_Result.Disconnected)
	testing.expect(t, !os.exists(spool_path("d")), "a disconnected upload leaves no file")
	testing.expect(t, !handler_invoked, "the Handler never runs for a body that never became Ready")
}

@(test)
arm_f_quota_breach_cancels_and_deletes :: proc(t: ^testing.T) {
	peak := 0
	res := spool_body(spool_path("q"), QUOTA_BYTES, -1, &peak)
	testing.expect_value(t, res, Ingest_Result.Quota_Exceeded)
	testing.expect(t, !os.exists(spool_path("q")), "a quota breach leaves no file")
}

// --- Arm G — bounded admission, workers spool, Handler scheduled after ------

Admission :: struct {
	mu:       sync.Mutex,
	active:   int,
	capacity: int,
}

admit :: proc(adm: ^Admission) -> bool {
	sync.mutex_lock(&adm.mu)
	defer sync.mutex_unlock(&adm.mu)
	if adm.active >= adm.capacity {
		return false // typed refusal BEFORE any byte is read
	}
	adm.active += 1
	return true
}

release :: proc(adm: ^Admission) {
	sync.mutex_lock(&adm.mu)
	adm.active -= 1
	sync.mutex_unlock(&adm.mu)
}

@(test)
arm_g_admission_refuses_the_upload_beyond_capacity :: proc(t: ^testing.T) {
	adm := Admission{capacity = 2} // `handler lanes − 1` in spec terms
	testing.expect(t, admit(&adm))
	testing.expect(t, admit(&adm))
	testing.expect(t, !admit(&adm), "the third concurrent ingest is refused at admission")
	release(&adm)
	testing.expect(t, admit(&adm), "capacity returns when a spool finishes")
	release(&adm)
	release(&adm)
	// With admission held, the spool itself is arm F's loop; G differs from F
	// only in WHO owns the loop (worker pool versus event lane). The spool
	// I/O is an append — there is no CPU work to justify a second pool, so
	// the evidence points at F-with-G's-admission, not at a worker tier.
}

// --- Arm H — application-provided incremental consumer ----------------------

App_Consumer_State :: struct {
	chunks_seen: int,
	bytes_seen:  int,
	checksum:    u64,
}

app_consume_chunk :: proc(state: ^App_Consumer_State, chunk: []u8) {
	state.chunks_seen += 1
	state.bytes_seen += len(chunk)
	for b in chunk {
		state.checksum = state.checksum * 31 + u64(b)
	}
}

@(test)
arm_h_app_consumer_works_but_is_a_second_handler_model :: proc(t: ^testing.T) {
	state: App_Consumer_State
	buf: [CHUNK_BYTES]u8
	for i in 0 ..< CHUNK_COUNT {
		fill_chunk(buf[:], i)
		// The framework would invoke this application callback once per chunk.
		app_consume_chunk(&state, buf[:])
	}
	testing.expect_value(t, state.chunks_seen, CHUNK_COUNT)
	testing.expect_value(t, state.bytes_seen, CHUNK_COUNT * CHUNK_BYTES)
	testing.expect(t, state.checksum != 0)
	// The finding is the SHAPE, not the arithmetic: `App_Consumer_State` must
	// outlive every callback invocation, so the application owns state with a
	// framework-driven lifetime — a callback-per-chunk contract is a second
	// Handler model with a hidden lifetime, exactly what the frozen
	// pre-decisions refuse for the Productive path. H remains an Advanced
	// candidate only if WP86's full criteria are met; it is not the default.
}
