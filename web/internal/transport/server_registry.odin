// WP123 — THE SERVER REGISTRY: what replaces `g_server`.
//
// WHAT WAS HERE BEFORE, and why replacing it is not tidying. WP43 moved the
// per-REQUEST state out of package globals and into the backend handler's own
// `user_data`, leaving one named exception behind: `g_server`, a single slot
// holding the running server's backend pointer, its stream registry and its
// upload admission. A single slot is a correct answer to "the running server"
// only while there is at most one, and it is a SILENT wrong answer the moment
// there are two — the second `serve` overwrites the first's pointers, and
// `web.stats`, `web.stop` and every `stream_send` in the process then answer
// about a server the caller never named. Nothing diagnoses it: from each
// server's own point of view nothing is wrong. ADR-018 accepted the per-server
// state that ends this, and this file is where the process-wide part of it
// lives.
//
// WHY A GLOBAL SURVIVES AT ALL, and it is a different global than before. The
// question is NOT lookup — a caller that holds an `^App` could reach a pointer
// through it directly. The question is LIFETIME. `Server_Runtime` lives in
// `serve`'s stack frame and the backend `http.Server` beside it, so both die
// when `serve` returns; a `stream_send` on another thread holding a raw pointer
// to either would be a use-after-free with no way to detect it. What makes that
// safe is a record that OUTLIVES every server and can answer "is the thing this
// handle names still alive?" — which a per-server lock, dying with its server,
// cannot. So the global stops being THE SERVER and becomes THE REGISTRY OF
// SERVERS, which is the only shape that is process-wide by nature.
//
// THE SHAPE IS THE ONE THIS CODEBASE ALREADY USES ONE LAYER DOWN. `stream.Token`
// answers exactly the same question about a detached stream — "how do I name
// something that may have died?" — with a slot plus a generation counter, and
// `web/internal/stream` has carried it since WP88. Reusing it here means one
// stale-safety idiom in the project rather than two.
//
// IT IS IN ITS OWN FILE ON PURPOSE. `build/check_public_api.sh` §8d forbids
// package-level variables in `odin_http_adapter.odin`, and used to carve out
// `g_server` by name. With the table here that carve-out is gone: the adapter
// declares NO package variable at all, and the one process-wide record is in a
// file whose entire subject is being process-wide. A second such global cannot
// arrive quietly in either file.
package transport

import ingest "druse:web/internal/ingest"
import stream "druse:web/internal/stream"
import "core:sync"
import "core:time"

// SERVER_TABLE_CAP bounds the servers one process may run CONCURRENTLY.
//
// Sixteen, and the number is chosen to be uninteresting rather than tuned: the
// motivating case is two (an application server beside an admin or metrics
// listener), the parallel test runner drives a handful, and a deployment that
// wanted seventeen listeners in one process has a topology question, not a
// capacity question. The cost is fixed: the table is BSS, sized at compile time,
// with no allocation and no teardown — which is what lets it outlive every
// server safely.
//
// A slot index must fit in `SERVER_SLOT_BITS` below.
SERVER_TABLE_CAP :: 16

// Server_Handle names one RUN of one server, stale-safely.
//
// It is a `u64` rather than a `{slot, generation}` struct for one reason that
// decides it: `web.stop` may be called from a SIGNAL HANDLER, so the handle has
// to be readable with a single atomic load. A two-field struct cannot be, and a
// handler that read a torn pair would stop a server nobody asked it to stop.
// The packing is the whole of the difference — the slot in the low
// `SERVER_SLOT_BITS`, biased by one so that the all-zero value is "no server",
// and the generation above it.
//
// `distinct` so it cannot be confused with any other integer that crosses this
// boundary, and so `web` can hold one without naming a transport-private type.
Server_Handle :: distinct u64

// SERVER_HANDLE_NONE is the zero value: the handle of an App that has never
// served, or of one whose server has returned. Every operation on it is the same
// no-op as the operation on a stale handle.
SERVER_HANDLE_NONE :: Server_Handle(0)

@(private)
SERVER_SLOT_BITS :: 8

@(private)
SERVER_SLOT_MASK :: u64(1 << SERVER_SLOT_BITS) - 1

#assert(SERVER_TABLE_CAP < int(SERVER_SLOT_MASK))

// How long a retire spins hot before it starts yielding instead. The wait is
// normally zero iterations — a reader has to be mid-call for it to be anything
// else — so this only decides how a rare, unlucky overlap behaves.
@(private)
SERVER_RETIRE_SPINS :: 256

// Server_Entry is one row: the three pointers a server-wide question needs, plus
// the two counters that make reading them safe without a lock.
//
// `generation` advances on every claim AND every release, so a handle minted for
// one run never names the next one to occupy the slot. `readers` counts the
// callers currently INSIDE the entry; a release waits for it to reach zero
// before the pointers are cleared and `serve` returns to destroy what they point
// at. That pair is what replaces the old mutex, and replacing it is the point:
// a mutex on this path is what made `stop` unusable from a signal handler.
@(private)
Server_Entry :: struct {
	generation: u64,
	// `claimed` and `live` are NOT the same bit, and conflating them was a real
	// defect in the first draft of this file.
	//
	// `live` gates READERS: it goes false the instant a retire begins, so nobody
	// new enters the row. `claimed` gates PUBLISHERS: it stays true until the
	// retire has finished draining its readers AND cleared the pointers.
	//
	// With one bit doing both jobs, a `serve` starting while another was retiring
	// could claim the slot the moment `live` went false — and the retire, still
	// running, would then clear `server`, `streams` and `admission` OUT FROM UNDER
	// the server that had just published them. The new server would be live, its
	// handle valid, its generation current, and every read through it would answer
	// as though no server were running. That is the same class of silent wrong
	// answer this whole file exists to remove, reintroduced one slot down.
	claimed:    bool,
	live:       bool,
	readers:    int,
	// The backend server, in `serve`'s frame. Read for the send-side counters and
	// for `http.server_shutdown`.
	//
	// A `rawptr` rather than a `^http.Server`, and not for taste: ADR-009 / WP8 D1
	// hold that EXACTLY ONE file names the vendored backend, and that file is
	// `odin_http_adapter.odin`. Naming the type here would make this a second one
	// — a boundary that erodes one convenience at a time. The adapter casts it
	// back at the two places that use it, which is the same opaque-pointer
	// discipline `Inbound.exchange` and `Inbound.upload` already use to cross this
	// package's own boundaries.
	server:     rawptr,
	// WP90b — the running server's detached-stream registry, for the callers with
	// no request in hand: `stream_send`, `stream_close`, `stream_live`.
	streams:    ^stream.Registry,
	// Phase 7.5-C2 — the running server's large-body ingest admission. Nil when
	// upload is not enabled.
	admission:  ^ingest.Admission,
}

// Server_Table is the process-wide record. `claim` serializes ALLOCATION of a
// slot and nothing else: it is taken by `serve`, on an ordinary thread, and
// never by a reader — which is what keeps every read path free of a lock a
// signal handler could deadlock on.
@(private)
Server_Table :: struct {
	claim:   sync.Mutex,
	entries: [SERVER_TABLE_CAP]Server_Entry,
}

// The one process-wide record. It is deliberately the ONLY package-level
// variable in this package (see the file header).
@(private)
g_servers: Server_Table

@(private)
server_handle_make :: proc(slot: int, generation: u64) -> Server_Handle {
	return Server_Handle((generation << SERVER_SLOT_BITS) | u64(slot + 1))
}

@(private)
server_handle_split :: proc(h: Server_Handle) -> (slot: int, generation: u64, ok: bool) {
	raw := u64(h)
	biased := int(raw & SERVER_SLOT_MASK)
	if biased <= 0 || biased > SERVER_TABLE_CAP {
		return 0, 0, false
	}
	return biased - 1, raw >> SERVER_SLOT_BITS, true
}

// server_publish claims a free slot for a starting server and returns its
// handle. Called by `serve` BEFORE the listen, so a failed listen has a handle
// to release.
//
// The pointers are stored BEFORE the entry goes live, so no reader can ever
// observe a live entry with an unfinished row. The slot it takes is one no
// retire is still inside — see `claimed`.
@(private)
server_publish :: proc(
	srv: rawptr,
	streams: ^stream.Registry,
	admission: ^ingest.Admission,
) -> (
	h: Server_Handle,
	ok: bool,
) {
	sync.lock(&g_servers.claim)
	defer sync.unlock(&g_servers.claim)
	for i in 0 ..< SERVER_TABLE_CAP {
		e := &g_servers.entries[i]
		if sync.atomic_load(&e.claimed) {
			continue
		}
		sync.atomic_store(&e.claimed, true)
		generation := sync.atomic_load(&e.generation) + 1
		e.server = srv
		e.streams = streams
		e.admission = admission
		sync.atomic_store(&e.generation, generation)
		sync.atomic_store(&e.live, true)
		return server_handle_make(i, generation), true
	}
	return SERVER_HANDLE_NONE, false
}

// server_retire ends a run: the handle stops naming anything, and the call does
// not return until every reader that was inside has left.
//
// THE ORDER IS THE SAFETY. The generation advances FIRST, so a reader arriving
// from here on fails its check and never touches the row; only then does this
// wait out the readers already inside. A reader that incremented `readers`
// before the bump reads the new generation and backs straight out. Both sides
// are sequentially consistent atomics, which is what makes that argument hold
// rather than merely sound plausible.
//
// It spins rather than blocks because the wait is over reader CRITICAL SECTIONS,
// every one of which is bounded and lock-free: a handful of atomic loads, or one
// bounded copy into a stream slot. There is nothing here for a reader to block
// on, so there is nothing for this to wait on indefinitely.
//
// And because the generation is bumped BEFORE the wait, no reader arriving from
// here on is admitted at all — so `readers` only ever falls. The spin therefore
// drains rather than races; it does not wait on an open population. It yields
// after a bounded burst all the same: a spin that never yields turns a
// descheduled reader into a burnt core, and this runs on a machine that may be
// running the rest of the gate beside it.
//
// The slot is released to publishers LAST, after the pointers are cleared. See
// `Server_Entry.claimed` for what went wrong when it was released first.
@(private)
server_retire :: proc(h: Server_Handle) {
	slot, generation, ok := server_handle_split(h)
	if !ok {
		return
	}
	e := &g_servers.entries[slot]
	if sync.atomic_load(&e.generation) != generation {
		return
	}
	sync.atomic_store(&e.live, false)
	sync.atomic_add(&e.generation, 1)
	spins := 0
	for sync.atomic_load(&e.readers) != 0 {
		spins += 1
		if spins < SERVER_RETIRE_SPINS {
			sync.cpu_relax()
		} else {
			time.sleep(50 * time.Microsecond)
		}
	}
	e.server = nil
	e.streams = nil
	e.admission = nil
	sync.atomic_store(&e.claimed, false)
}

// server_acquire enters the entry a handle names, or reports that it names
// nothing. Every caller must pair it with `server_leave`.
//
// ASYNC-SIGNAL-SAFE: three atomics and a bounds check, no allocation, no lock.
@(private)
server_acquire :: proc(h: Server_Handle) -> (e: ^Server_Entry, ok: bool) {
	slot, generation, split_ok := server_handle_split(h)
	if !split_ok {
		return nil, false
	}
	entry := &g_servers.entries[slot]
	sync.atomic_add(&entry.readers, 1)
	if sync.atomic_load(&entry.generation) != generation || !sync.atomic_load(&entry.live) {
		sync.atomic_sub(&entry.readers, 1)
		return nil, false
	}
	return entry, true
}

@(private)
server_leave :: proc(e: ^Server_Entry) {
	sync.atomic_sub(&e.readers, 1)
}

// server_current resolves the handle of the SOLE running server, or
// `SERVER_HANDLE_NONE` when none runs — or when more than one does.
//
// IT IS THE LEGACY RESOLVER AND IT IS DELIBERATELY AMBIGUITY-INTOLERANT. Its
// remaining callers are the ones that ask a process-wide question without a
// server in hand, which is exactly the question that stops having an answer once
// a process runs two. Returning nothing when the question is ambiguous is the
// only honest reply available to a caller that did not name a server: an
// arbitrary pick would be the silent cross-wire this whole work package exists
// to remove.
server_current :: proc() -> Server_Handle {
	found := SERVER_HANDLE_NONE
	for i in 0 ..< SERVER_TABLE_CAP {
		e := &g_servers.entries[i]
		if !sync.atomic_load(&e.live) {
			continue
		}
		if found != SERVER_HANDLE_NONE {
			return SERVER_HANDLE_NONE
		}
		found = server_handle_make(i, sync.atomic_load(&e.generation))
	}
	return found
}
