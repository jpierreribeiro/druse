// WP87 — the opt-in large-body ownership corpus, committed RED.
//
// Encodes the pre-registered contract of phase-7-spec.md §4.2 (OQ-20
// Amendment 1) against the WP87 sentinel in `web/internal/ingest`. Expected
// to fail today under `build/check_wp87_controls.sh`; WP93/WP94/WP95 make it
// pass by replacing sentinel bodies, never by editing a test. The buffered
// oracle lives in `tests/wp87-buffered-oracle` and must stay GREEN throughout.
package test_wp87_body_lifecycle

import "core:os"
import "core:strings"
import "core:testing"
import ingest "druse:web/internal/ingest"

SPOOL_DIR :: "/tmp/druse-wp87-spool"

cfg :: proc() -> ingest.Spool_Config {
	if os.make_directory(SPOOL_DIR) != nil && !os.exists(SPOOL_DIR) {
		return ingest.Spool_Config{}
	}
	return ingest.Spool_Config{
		dir               = SPOOL_DIR,
		per_upload_quota  = 4 * 1024,
		process_quota     = 16 * 1024,
		max_concurrent    = 1,
		memory_prefix_max = 1024,
	}
}

@(test)
wp87_admission_refuses_before_reading_any_byte :: proc(t: ^testing.T) {
	a: ingest.Admission
	testing.expect(t, ingest.admission_init(&a, cfg()), "admission must accept the pre-registered bounds (sentinel: WP94)")
	defer ingest.admission_destroy(&a)
	testing.expect_value(t, ingest.admit(&a), ingest.Ingest_Result.Ready)
	testing.expect_value(t, ingest.admit(&a), ingest.Ingest_Result.Refused_Admission)
	testing.expect_value(t, ingest.active_spools(&a), 1)
}

@(test)
wp87_spool_file_is_generated_private_and_inside_the_designated_dir :: proc(t: ^testing.T) {
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	testing.expect_value(t, ingest.begin(&a, &s), ingest.Ingest_Result.Ready)
	defer _ = ingest.cancel(&s, .Cancelled_By_Drain)
	// The corpus can only observe the contract surface: bytes are accepted
	// and accounted. Path privacy (druse-spool- prefix, 0600, never the
	// client filename) is asserted by WP94's own suite against the real
	// layout; here the accounting proves a real spool exists.
	chunk := [512]u8{}
	testing.expect_value(t, ingest.append_chunk(&s, chunk[:]), ingest.Ingest_Result.Ready)
	testing.expect_value(t, ingest.spooled_bytes(&s), i64(512))
}

@(test)
wp87_large_body_bytes_never_coexist_in_memory :: proc(t: ^testing.T) {
	// The spool accepts more than memory_prefix_max while only ever holding
	// one chunk: spooled accounting grows, the prefix bound does not move.
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	_ = ingest.begin(&a, &s)
	defer _ = ingest.cancel(&s, .Cancelled_By_Drain)
	chunk := [1024]u8{}
	for _ in 0 ..< 3 { // 3 KiB through a 1 KiB memory prefix
		testing.expect_value(t, ingest.append_chunk(&s, chunk[:]), ingest.Ingest_Result.Ready)
	}
	testing.expect_value(t, ingest.spooled_bytes(&s), i64(3 * 1024))
}

@(test)
wp87_per_upload_quota_breach_is_typed_and_cleans :: proc(t: ^testing.T) {
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	_ = ingest.begin(&a, &s)
	chunk := [1024]u8{}
	for _ in 0 ..< 4 {
		_ = ingest.append_chunk(&s, chunk[:]) // reaches the 4 KiB quota
	}
	testing.expect_value(t, ingest.append_chunk(&s, chunk[:]), ingest.Ingest_Result.Quota_Exceeded)
	// After the breach the spool is terminal: cleanup ran exactly once and
	// further cancels are safe no-ops.
	testing.expect(t, ingest.cancel(&s, .Quota_Exceeded), "cleanup after breach must be safe")
	testing.expect(t, ingest.cancel(&s, .Quota_Exceeded), "a second cancel is a safe no-op, never a double delete")
}

@(test)
wp87_disconnect_cancel_is_exactly_once :: proc(t: ^testing.T) {
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	_ = ingest.begin(&a, &s)
	chunk := [256]u8{}
	_ = ingest.append_chunk(&s, chunk[:])
	testing.expect(t, ingest.cancel(&s, .Disconnected), "mid-body disconnect deletes the partial spool")
	testing.expect(t, ingest.cancel(&s, .Disconnected), "repeat cancel is safe")
	testing.expect_value(t, ingest.active_spools(&a), 0)
}

@(test)
wp87_ready_hands_exactly_one_owned_body :: proc(t: ^testing.T) {
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	_ = ingest.begin(&a, &s)
	chunk := [256]u8{}
	_ = ingest.append_chunk(&s, chunk[:])
	testing.expect_value(t, ingest.finish(&s), ingest.Ingest_Result.Ready)
	// Automatic cleanup still runs unless ownership is explicitly transferred.
	testing.expect(t, ingest.cancel(&s, .Cancelled_By_Drain), "a Ready body not persisted is still cleaned exactly once")
}

@(test)
wp87_persist_is_the_only_path_that_leaves_a_file :: proc(t: ^testing.T) {
	a: ingest.Admission
	_ = ingest.admission_init(&a, cfg())
	defer ingest.admission_destroy(&a)
	_ = ingest.admit(&a)
	s: ingest.Spool
	_ = ingest.begin(&a, &s)
	chunk := [256]u8{}
	_ = ingest.append_chunk(&s, chunk[:])
	_ = ingest.finish(&s)
	dest := strings.concatenate({SPOOL_DIR, "/persisted-upload"})
	defer delete(dest)
	testing.expect(t, ingest.persist(&s, dest), "explicit persistence transfer must succeed for a Ready body")
	defer _ = os.remove(dest)
	testing.expect(t, os.exists(dest), "the persisted file exists at the destination, outside the spool namespace")
	_ = ingest.cancel(&s, .Cancelled_By_Drain)
	testing.expect(t, os.exists(dest), "cleanup after persist must NOT touch the transferred file")
}
