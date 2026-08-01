// Internal regression fixture for build/check_wp123_controls.sh.
//
// This file is copied beside the shipped transport sources because the
// registry lifetime operations are deliberately private. Keeping the test at
// the package boundary avoids widening production API only to make the race
// observable.
package transport

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

WP123_Retire_State :: struct {
	handle: Server_Handle,
	done:   bool,
}

wp123_retire_worker :: proc(state: ^WP123_Retire_State) {
	server_retire(state.handle)
	sync.atomic_store(&state.done, true)
}

@(test)
wp123_retiring_slot_is_not_reused_until_old_readers_leave :: proc(t: ^testing.T) {
	old_server, new_server: int

	old_handle, old_published := server_publish(rawptr(&old_server), nil, nil)
	testing.expect(t, old_published, "the old server must claim a registry slot")
	if !old_published {
		return
	}

	old_entry, old_acquired := server_acquire(old_handle)
	testing.expect(t, old_acquired, "the old reader must enter its registry slot")
	if !old_acquired {
		server_retire(old_handle)
		return
	}

	state := WP123_Retire_State{handle = old_handle}
	worker := thread.create_and_start_with_poly_data(&state, wp123_retire_worker)
	defer thread.destroy(worker)

	// Retire publishes live=false before waiting for the reader deliberately
	// held above. At this point the row is unavailable to readers but must remain
	// unavailable to publishers until its pointers have been cleared.
	retire_started := false
	for _ in 0 ..< 1000 {
		if !sync.atomic_load(&old_entry.live) {
			retire_started = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, retire_started, "retire must reach its reader wait")
	if !retire_started {
		server_leave(old_entry)
		thread.join(worker)
		return
	}

	new_handle, new_published := server_publish(rawptr(&new_server), nil, nil)
	testing.expect(t, new_published, "the new server must claim another slot")
	if !new_published {
		server_leave(old_entry)
		thread.join(worker)
		return
	}

	old_slot, _, old_split := server_handle_split(old_handle)
	new_slot, _, new_split := server_handle_split(new_handle)
	testing.expect(t, old_split && new_split, "both server handles must split")
	testing.expect(
		t,
		old_slot != new_slot,
		"RETIRING-SLOT-REUSED: a publisher claimed a row whose old reader is still inside",
	)
	testing.expect(
		t,
		old_entry.server == rawptr(&old_server),
		"RETIRING-SLOT-CROSSWIRE: the old reader observed the new server pointer",
	)

	new_entry, new_acquired := server_acquire(new_handle)
	testing.expect(t, new_acquired, "the new server handle must be live")
	if new_acquired {
		testing.expect(
			t,
			new_entry.server == rawptr(&new_server),
			"the new handle must resolve to the new server",
		)
		server_leave(new_entry)
	}

	// Let the old retire finish. It may clear only the old row.
	server_leave(old_entry)
	thread.join(worker)
	testing.expect(t, sync.atomic_load(&state.done), "the old retire must finish")

	new_entry_after, new_acquired_after := server_acquire(new_handle)
	testing.expect(t, new_acquired_after, "the new handle must survive the old retire")
	if new_acquired_after {
		testing.expect(
			t,
			new_entry_after.server == rawptr(&new_server),
			"RETIRING-SLOT-ERASED: the old retire cleared the new server pointer",
		)
		server_leave(new_entry_after)
	}
	server_retire(new_handle)
}
