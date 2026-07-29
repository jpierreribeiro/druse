// Private opt-in large-body ingest — implemented by WP94 against the WP87
// body corpus and phase-7-spec.md §4.2 (OQ-20 Amendment 1).
//
// Shape selected by WP86's ingest arms: bounded spool (arm F's append loop
// under arm G's admission). Admission is capped BELOW handler-lane capacity
// and refuses with a typed result before any body byte is read; the spool
// appends one chunk buffer at a time, so a body of any size costs one chunk
// of memory, never its length; the ordinary synchronous Handler runs only
// once the body is Ready, receiving an explicitly owned spool. Every terminal
// path has a pre-registered outcome and deletes the partial file exactly once
// unless the application explicitly persists it.
//
// Not imported by `web`: the buffered path (G7-10) is untouched, and no name
// here is a public ledger candidate (names freeze at WP101). The parser that
// feeds `append_chunk` for multipart is WP94's second component; this file is
// the ownership/quota/cleanup substrate it and a raw-body consumer share.
package uruquim_internal_ingest

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

// Typed terminal results of an opt-in large-body ingest (§4.2: every path has
// a pre-registered outcome; none is a silent 200 or a hang).
Ingest_Result :: enum {
	Unimplemented, // retained for corpus ABI; no path returns it since WP94
	Ready,
	Refused_Admission,
	Quota_Exceeded,
	Process_Quota_Exceeded,
	Disk_Full,
	Disconnected,
	Timed_Out,
	Cancelled_By_Drain,
}

// §4.2 registered defaults. Zero selects them; the temp directory has no
// default — opting in requires designating one, so the core never writes to a
// silent /tmp an operator did not choose.
DEFAULT_PER_UPLOAD_QUOTA :: i64(1) << 30 // 1 GiB
DEFAULT_PROCESS_QUOTA :: i64(8) << 30 // 8 GiB
DEFAULT_MEMORY_PREFIX :: 64 * 1024
SPOOL_PREFIX :: "uruquim-spool-"

Spool_Config :: struct {
	dir:               string,
	per_upload_quota:  i64,
	process_quota:     i64,
	max_concurrent:    int,
	memory_prefix_max: int,
}

@(private)
Spool_State :: enum u8 {
	Open, // accepting chunks
	Ready, // finished, owned by one consumer, cleanup still pending
	Terminal, // cancelled or persisted; cleanup has run exactly once
}

Spool :: struct {
	admission: ^Admission,
	file:      ^os.File,
	path:      string,
	written:   i64,
	state:     Spool_State,
}

Admission :: struct {
	mu:            sync.Mutex,
	cfg:           Spool_Config,
	active:        int,
	process_bytes: i64, // total spooled bytes across live spools; drives the process quota
	seq:           u64, // filename entropy source, monotonic under mu
	draining:      bool, // WP95: set at drain; admission then refuses
	initialized:   bool,
}

resolve_config :: proc(cfg: Spool_Config) -> Spool_Config {
	c := cfg
	if c.per_upload_quota <= 0 {c.per_upload_quota = DEFAULT_PER_UPLOAD_QUOTA}
	if c.process_quota <= 0 {c.process_quota = DEFAULT_PROCESS_QUOTA}
	if c.max_concurrent <= 0 {c.max_concurrent = 1}
	if c.memory_prefix_max <= 0 {c.memory_prefix_max = DEFAULT_MEMORY_PREFIX}
	return c
}

admission_init :: proc(a: ^Admission, cfg: Spool_Config) -> bool {
	if a.initialized || len(cfg.dir) == 0 {
		return false // no dir = no opt-in; the core never picks a spool dir
	}
	a.cfg = resolve_config(cfg)
	a.active = 0
	a.process_bytes = 0
	a.seq = 0
	a.initialized = true
	return true
}

// sweep_orphans removes leftover spool files at boot (audit M8).
//
// EXPORTED, AND CALLED FROM THE SERVER START RATHER THAN FROM `admission_init`.
// It lived in `admission_init` first, and the gate caught why that is wrong:
// `admission_init` is a library primitive, and several `Admission` values can
// exist in one process against one directory — the WP87 suite does exactly
// that, four tests in parallel — so a sweep there deletes another Admission's
// LIVE spool. Taking ownership of a directory is a property of a SERVER
// starting, which happens once per process; initialising a struct is not.
//
// Nothing cleaned them. A spool is unlinked at request teardown, so the steady
// state is empty — but a crash, a kill -9 or an OOM leaves the partial behind,
// and across restarts those accumulate until an operator notices. The failure
// is silent and cumulative, which is the shape that gets found by a full disk.
//
// IT DELETES ONLY THE FRAMEWORK'S OWN NAMESPACE, never the directory's other
// contents: the prefix match is the whole authority for removing a file, and
// anything an application put in there is untouched.
//
// THE HAZARD IT ACCEPTS, and why the directory's contract had to be written
// down before this could be added: if two server instances share one spool
// directory, the second one's boot deletes the first one's LIVE spools. There
// is no portable way to tell a live spool from an abandoned one — an mtime
// threshold races a slow upload, and file locks are not available in the pinned
// core. So the directory is now documented as owned by exactly one instance,
// and this sweep is correct under that contract and destructive outside it.
//
// Failures are ignored on purpose. A directory that cannot be read at boot is
// reported by the first spool that tries to open a file in it, with a better
// message than a sweep could give.
sweep_orphans :: proc(dir: string) {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for entry in entries {
		if !strings.has_prefix(entry.name, SPOOL_PREFIX) {
			continue
		}
		full := strings.concatenate({dir, "/", entry.name}, context.temp_allocator)
		_ = os.remove(full)
	}
}

admission_destroy :: proc(a: ^Admission) {
	a^ = Admission{}
}

// admit reserves one bounded ingest slot, or refuses BEFORE any byte is read.
admit :: proc(a: ^Admission) -> Ingest_Result {
	if !a.initialized {
		return .Refused_Admission
	}
	sync.mutex_lock(&a.mu)
	defer sync.mutex_unlock(&a.mu)
	if a.draining {
		// WP95 — no new large-body ingest is admitted once drain begins; a
		// Handler that would start one gets the same typed refusal as one
		// that hit the concurrency cap. In-flight spools finish or are
		// cancelled by the request that owns them.
		return .Refused_Admission
	}
	if a.active >= a.cfg.max_concurrent {
		return .Refused_Admission
	}
	a.active += 1
	return .Ready
}

// release_slot returns one reservation taken by `admit` when no spool will ever
// own it. `cancel` is the release path for a spool that opened; this is the
// release path for one that did not.
release_slot :: proc(a: ^Admission) {
	if !a.initialized {
		return
	}
	sync.mutex_lock(&a.mu)
	if a.active > 0 {
		a.active -= 1
	}
	sync.mutex_unlock(&a.mu)
}

// admission_drain stops admission; it does not touch in-flight spools, which
// are owned by the synchronous Handler holding them and are cancelled by that
// request's teardown at the process drain deadline (WP95, spec §2).
admission_drain :: proc(a: ^Admission) {
	if !a.initialized {
		return
	}
	sync.mutex_lock(&a.mu)
	a.draining = true
	sync.mutex_unlock(&a.mu)
}

// begin opens the spool file: a generated unpredictable `uruquim-spool-` name,
// 0600, inside cfg.dir — never the client filename, never a silent /tmp.
begin :: proc(a: ^Admission, s: ^Spool) -> Ingest_Result {
	if !a.initialized {
		return .Refused_Admission
	}
	sync.mutex_lock(&a.mu)
	a.seq += 1
	name := spool_name(a)
	sync.mutex_unlock(&a.mu)

	path := strings.concatenate({a.cfg.dir, "/", name})
	delete(name) // the entropy string is owned only until it is joined into path
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm_number(0o600))
	if err != nil {
		delete(path)
		// URUQUIM (ingest audit F2) — RELEASE THE SLOT WE NEVER GOT TO USE.
		// Every caller reserves with `admit` before calling `begin`, and the
		// only release path is `cancel`, which reaches the admission through
		// `s.admission` — a field this failure leaves unset. So an `os.open`
		// failure used to consume a slot permanently: a spool directory that
		// was briefly unwritable would retire `max_concurrent` slots and refuse
		// every subsequent upload with 503 for the life of the process, long
		// after the disk condition cleared.
		release_slot(a)
		return .Disk_Full
	}
	s^ = Spool {
		admission = a,
		file      = f,
		path      = path,
		written   = 0,
		state     = .Open,
	}
	return .Ready
}

// spool_name builds an unpredictable name. Caller holds a.mu. No CSPRNG is
// available in the pinned core and the file is 0600 in an app-designated
// directory, so entropy comes from a monotonic sequence mixed with the pid,
// the thread id and the admission address — enough that a name cannot be
// guessed and predicted for a symlink-race, which is the property §4.2 wants.
//
// AUDIT M8 — THE PID WAS IN THE COMMENT AND NOT IN THE CODE. This mixed the
// sequence, the thread id and the admission address, and the sentence above
// claimed a pid that was never there. Two processes started from the same
// image can share a thread id and a sequence, leaving only the heap address to
// separate them — which ASLR usually does and a deterministic allocator does
// not. The comment described the property that was wanted; the code now
// provides it.
@(private)
spool_name :: proc(a: ^Admission) -> string {
	mixed := a.seq
	mixed = mixed * 1099511628211 + u64(os.get_pid())
	mixed = mixed * 1099511628211 + u64(os.get_current_thread_id())
	mixed = mixed * 1099511628211 + u64(uintptr(a))
	buf: [32]u8
	hex := strconv.write_int(buf[:], i64(mixed), 16)
	return strings.concatenate({SPOOL_PREFIX, hex})
}

// append_chunk consumes one arriving chunk, enforcing BOTH quotas mid-body.
// The chunk is written straight to disk; the only memory this holds is the
// caller's transient buffer, so a body of any size costs one chunk.
append_chunk :: proc(s: ^Spool, chunk: []u8) -> Ingest_Result {
	if s.state != .Open {
		return .Cancelled_By_Drain
	}
	a := s.admission
	n := i64(len(chunk))

	if s.written + n > a.cfg.per_upload_quota {
		cancel(s, .Quota_Exceeded)
		return .Quota_Exceeded
	}
	sync.mutex_lock(&a.mu)
	over_process := a.process_bytes + n > a.cfg.process_quota
	if !over_process {
		a.process_bytes += n
	}
	sync.mutex_unlock(&a.mu)
	if over_process {
		cancel(s, .Process_Quota_Exceeded)
		return .Process_Quota_Exceeded
	}

	written, werr := os.write(s.file, chunk)
	if werr != nil || written != len(chunk) {
		// The bytes were reserved against the process quota above; give them
		// back before cleanup, so a disk-full does not leak the reservation.
		sync.mutex_lock(&a.mu)
		a.process_bytes -= n
		sync.mutex_unlock(&a.mu)
		cancel(s, .Disk_Full)
		return .Disk_Full
	}
	s.written += n
	return .Ready
}

// finish makes the body Ready and hands ownership to exactly one consumer.
// Automatic cleanup still runs (via cancel) unless the application persists.
finish :: proc(s: ^Spool) -> Ingest_Result {
	if s.state != .Open {
		return .Cancelled_By_Drain
	}
	if s.file != nil {
		os.close(s.file)
		s.file = nil
	}
	s.state = .Ready
	return .Ready
}

// cancel is the single cleanup path for disconnect, timeout, quota breach,
// disk-full and drain: the partial file is deleted exactly once; calling it
// twice — or after finish — is a safe no-op. Returns true when it (or an
// earlier call) has left the spool terminal.
cancel :: proc(s: ^Spool, reason: Ingest_Result) -> bool {
	if s.state == .Terminal {
		return true // already cleaned exactly once
	}
	a := s.admission
	if s.file != nil {
		os.close(s.file)
		s.file = nil
	}
	if len(s.path) > 0 {
		_ = os.remove(s.path)
	}
	// Release this spool's admission slot and its process-byte reservation
	// once, on the first terminal transition.
	if a != nil {
		sync.mutex_lock(&a.mu)
		if a.active > 0 {a.active -= 1}
		a.process_bytes -= s.written
		if a.process_bytes < 0 {a.process_bytes = 0}
		sync.mutex_unlock(&a.mu)
	}
	if len(s.path) > 0 {
		delete(s.path)
		s.path = ""
	}
	s.state = .Terminal
	return true
}

// persist transfers ownership OUT of the spool namespace (an explicit rename)
// — the only path that leaves a file behind (§4.2). After it, cleanup is a
// no-op that must not touch the transferred file.
persist :: proc(s: ^Spool, destination: string) -> bool {
	if s.state != .Ready || len(s.path) == 0 {
		return false
	}
	if os.rename(s.path, destination) != nil {
		return false
	}
	// The file now lives at `destination`; release the reservation and mark
	// terminal WITHOUT deleting anything.
	a := s.admission
	if a != nil {
		sync.mutex_lock(&a.mu)
		if a.active > 0 {a.active -= 1}
		a.process_bytes -= s.written
		if a.process_bytes < 0 {a.process_bytes = 0}
		sync.mutex_unlock(&a.mu)
	}
	delete(s.path)
	s.path = ""
	s.state = .Terminal
	return true
}

// --- corpus-observable state ------------------------------------------------

active_spools :: proc(a: ^Admission) -> int {
	if !a.initialized {
		return -1
	}
	sync.mutex_lock(&a.mu)
	defer sync.mutex_unlock(&a.mu)
	return a.active
}

spooled_bytes :: proc(s: ^Spool) -> i64 {
	return s.written
}

// spool_path returns the on-disk path of a Ready spool, for a consumer that
// will read or persist it. Empty once the spool is terminal.
spool_path :: proc(s: ^Spool) -> string {
	return s.path
}
