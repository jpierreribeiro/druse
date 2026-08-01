package transport

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Retire_Audit_State :: struct {
	handle: Server_Handle,
	done:   bool,
}

retire_audit_worker :: proc(state: ^Retire_Audit_State) {
	server_retire(state.handle)
	sync.atomic_store(&state.done, true)
}

@(test)
audit_slot_is_reused_before_old_readers_leave :: proc(t: ^testing.T) {
	old_server, new_server: int

	old_handle, ok := server_publish(rawptr(&old_server), nil, nil)
	testing.expect(t, ok, "old server must claim a slot")
	old_entry, acquired := server_acquire(old_handle)
	testing.expect(t, acquired, "old reader must enter the slot")

	state := Retire_Audit_State{handle = old_handle}
	worker := thread.create_and_start_with_poly_data(&state, retire_audit_worker)
	defer thread.destroy(worker)

	// server_retire publishes live=false before waiting for this reader.
	for _ in 0 ..< 1000 {
		if !sync.atomic_load(&old_entry.live) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, !sync.atomic_load(&old_entry.live), "retire must reach its reader wait")

	// publish sees live=false and reuses the same slot while the old reader is
	// deliberately still inside its critical section.
	new_handle, new_ok := server_publish(rawptr(&new_server), nil, nil)
	testing.expect(t, new_ok, "new server must publish")
	old_slot, _, _ := server_handle_split(old_handle)
	new_slot, _, _ := server_handle_split(new_handle)
	testing.expect_value(t, new_slot, old_slot)
	testing.expect(
		t,
		old_entry.server == rawptr(&new_server),
		"an already-acquired old reader now observes the new server pointer",
	)

	server_leave(old_entry)
	thread.join(worker)
	testing.expect(t, sync.atomic_load(&state.done), "old retire must finish")

	// The old retire clears the row after the new publish. The new generation
	// and live flag still validate, but the pointer has been erased.
	new_entry, new_acquired := server_acquire(new_handle)
	testing.expect(t, new_acquired, "new handle still validates after old retire")
	if new_acquired {
		testing.expect(t, new_entry.server == nil, "old retire erased the live new server pointer")
		server_leave(new_entry)
	}
	server_retire(new_handle)
}
