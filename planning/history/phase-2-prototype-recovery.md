# WP13 — Fault/recovery feasibility prototype

**Type: PROTOTYPE. Output: a recommendation with measured evidence.**
**Status: complete. Requires owner approval — a scope amendment is proposed.**

Toolchain: `env -u ODIN_ROOT /tmp/druse-toolchain/odin`, version
`dev-2026-07-nightly:819fdc7` (the pinned commit).
Prototype workspace: `/tmp/wp13-probe/`. Nothing in `web/` or `build/` was
changed; every patched build used a **copy** of the real sources, the same
throwaway-package technique the gate itself uses (`build/check.sh:104`).

---

## Read this first: the one-paragraph answer

Odin cannot recover from a panic, and it never will be able to without a
language change. But that turns out **not** to be the most important finding.
The most important finding is that most real faults — an index out of range, a
nil pointer, a divide by zero — **do not go through the panic machinery at all**,
so even the cleverest panic hook would miss them. On top of that, a `web.app()`
call **structurally cannot install** a recovery hook, because Odin's `context` is
copied into each procedure and an assignment made inside `app()` dies when
`app()` returns. So "recovery middleware — becomes default-on in `web.app()`" is
not merely hard; three independent parts of the sentence are false.

The recommendation is **R-b**: recovery is redefined as the driver guarantee
Druse already ships and already tests, plus documentation that says plainly
that a faulting handler aborts the process. The exact amendment text for
`knowledge-base/03-development-phases.md` is in section 9.

---

## 1. The baseline (the RED control)

Every candidate is measured against this. A handler that panics, driven through
`web.test_request` against the **unmodified** repository.

`/tmp/wp13-probe/baseline/main.odin`:

```odin
package main

import "core:os"
import "druse:web"

boom :: proc(ctx: ^web.Context) {
	panic("handler exploded")
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/boom", boom)

	os.write_string(os.stdout, "before request\n")
	res := web.test_request(&app, .GET, "/boom")
	os.write_string(os.stdout, "after request, status reached\n")
	if res.status != nil {}
	os.write_string(os.stdout, "done\n")
}
```

Command and verbatim output:

```
$ odin build /tmp/wp13-probe/baseline \
    -collection:druse=/home/jp/Desktop/druse -out:baseline.bin
$ ./baseline.bin
before request
/tmp/wp13-probe/baseline/main.odin(8:2) panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132
```

`after request, status reached` never prints. The process is killed by SIGILL
(signal 4), which the shell reports as exit 132 (128 + 4).

Repeated in three more build modes — the answer does not change:

```
=== MODE: -o:speed ===
before request
/tmp/wp13-probe/baseline/main.odin(8:2) panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132
=== MODE: -disable-assert ===
before request
panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132
=== MODE: -o:speed -disable-assert ===
before request
panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132
```

(Note that `-disable-assert` removes the source location `main.odin(8:2)` from
the message but does not stop the abort. `panic` is not an assert.)

**Baseline established: today, a panic inside a handler kills the process,
in every build mode, and no response reaches the client.**

---

## 2. Two structural facts discovered before any candidate could be built

These two facts change the shape of the whole question. Both were found while
trying to make R-a work, and both are proved by execution.

### FACT 1 — `web.app()` can never install a recovery hook

Odin's `context` is an implicit **by-value** parameter. A procedure that assigns
to `context.assertion_failure_proc` changes only its own copy and the copies
handed to procedures it calls. When it returns, the assignment is gone.

`/tmp/wp13-probe/ctxscope/main.odin`:

```odin
package main
import "base:runtime"
import "core:os"
hook :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	os.write_string(os.stdout, "HOOK\n"); os.exit(77)
}
installer :: proc() { context.assertion_failure_proc = hook }
main :: proc() {
	installer()
	os.write_string(os.stdout, "installed via callee\n")
	panic("x")
}
```

```
$ ./c.bin
installed via callee
/tmp/wp13-probe/ctxscope/main.odin(12:2) panic: x
Illegal instruction     (core dumped)
EXIT=132
```

The hook never ran. `HOOK` is absent.

**Consequence.** `app()` returns an `App` by value; it cannot leave a hook
behind. The phrase *"becomes default-on in `web.app()`"* is not achievable for
any hook-based candidate. The only place a hook can be installed so that it
covers a handler is the **driver frame that encloses dispatch** —
`driver_run` in `web/serve.odin`. That is where both R-a and R-c had to put it.
It works, but it is "always-on in the response driver", not "a default of
`app()`", and it cannot be varied between `app()` and `bare()` by construction —
only by a runtime check on the App flag.

### FACT 2 — most real faults never reach the panic hook

`/tmp/wp13-probe/facts/main.odin` installs a custom
`context.assertion_failure_proc` in `main` (so scope is not the issue) and then
triggers six different fault classes. `HOOK REACHED` + exit 77 means the hook
ran; anything else means the runtime bypassed it.

```
--- panic ---       HOOK REACHED prefix=[panic] message=[explicit panic]            EXIT=77
--- assert ---      HOOK REACHED prefix=[runtime assertion] message=[assertion text] EXIT=77
--- bounds ---      main.odin(38:12) Index 102 is out of range 0..<3
                    Illegal instruction (core dumped)                                EXIT=132
--- nil ---         Segmentation fault (core dumped)                                 EXIT=139
--- div ---         Illegal instruction (core dumped)                                EXIT=132
--- typeassert ---  HOOK REACHED prefix=[type assertion] message=[Invalid type
                    assertion from U to bool, actual type: int]                      EXIT=77
```

This matches the runtime source. `base/runtime/error_checks.odin:27`:

```odin
@(disabled=ODIN_NO_BOUNDS_CHECK)
bounds_check_error :: proc "contextless" (file: string, line, column: i32, index, count: int) {
	if uint(index) < uint(count) { return }
	@(cold, no_instrumentation)
	handle_error :: proc "contextless" (...) -> ! {
		print_caller_location(...)
		...
		bounds_trap()          // <-- straight to trap(); no context, no hook
	}
	handle_error(file, line, column, index, count)
}
```

The bounds checker is `proc "contextless"` — it has no `context` at all, so it
*cannot* consult `context.assertion_failure_proc` even in principle. A nil
dereference is not checked by anything; it is a raw SIGSEGV from the CPU. An
integer divide by zero is a raw SIGFPE/SIGILL from the CPU.

**Summary table — fault class versus reachability of the hook:**

| Fault class | Reaches `assertion_failure_proc`? | Observed |
|---|---|---|
| `panic("...")` | **yes** | exit 77 (hook) |
| `assert(cond)` failure | **yes** | exit 77 (hook) |
| failed type assertion `u.(T)` | **yes** | exit 77 (hook) |
| index / slice out of range | **no** | SIGILL, exit 132 |
| nil pointer dereference | **no** | SIGSEGV, exit 139 |
| integer divide by zero | **no** | SIGILL, exit 132 |

Only the three explicit, programmer-authored fault forms are catchable. The
three faults that dominate real production incidents are not.

---

## 3. Additional fact: build modes

The same six cases, across five build configurations:

```
######## MODE: default
panic exit=77   assert exit=77   bounds exit=132  nil exit=139  div exit=132  typeassert exit=77
######## MODE: -o:speed
panic exit=77   assert exit=77   bounds exit=132  nil exit=0    div exit=132  typeassert exit=77
######## MODE: -disable-assert
panic exit=77   assert exit=0    bounds exit=132  nil exit=139  div exit=132  typeassert exit=77
######## MODE: -no-bounds-check
panic exit=77   assert exit=77   bounds exit=0    nil exit=139  div exit=132  typeassert exit=77
######## MODE: -o:speed -disable-assert -no-bounds-check
panic exit=77   assert exit=0    bounds exit=0    nil exit=0    div exit=132  typeassert exit=77
```

Three build-mode facts the owner should know:

1. **`-disable-assert` silently deletes `assert` calls.** The program then keeps
   running past a condition it had declared impossible (`exit=0`, "SURVIVED").
   That is *worse* than a fault, and it is invisible.
2. **`-no-bounds-check` makes the out-of-range read succeed** — it reads
   whatever memory happens to be there. Also `exit=0`.
3. **`-o:speed` made the nil dereference "survive"** (`exit=0`). This is not
   recovery. The optimiser saw that the loaded value was unused and deleted the
   load, so the fault never happened. It is an artefact of undefined behaviour,
   not a guarantee, and must never be reported as one.

`-o:speed` and `-disable-assert` **do not change any answer for `panic`.** The
panic path is identical in all five modes.

---

## 4. Candidate R-a — "last gasp"

> Install a custom `context.assertion_failure_proc` that writes a standardized
> 500 envelope onto the in-flight connection, then aborts.

### 4.1 Can the hook reach enough state to write a response?

Yes, but only by opening a new hole in the transport boundary.
`vendor/odin-http/response.odin` gives `Response._conn: ^Connection`, and
`vendor/odin-http/server.odin:364` gives `Connection.socket: net.TCP_Socket`,
which on Linux is the raw file descriptor. The adapter was patched to publish it:

`web/internal/transport/odin_http_adapter.odin` (prototype copy):

```odin
// The in-flight connection's raw file descriptor, or -1 when none.
g_inflight_fd: int = -1
inflight_fd :: proc() -> int {return g_inflight_fd}

// ... inside on_body, around the dispatch call:
    g_inflight_fd = int(res._conn.socket)
    g_config.dispatch(g_config.user, inbound, &out, context.temp_allocator)
    g_inflight_fd = -1
```

and the hook (`web/recovery.odin`, prototype copy) writes a compile-time
constant response with a raw `write(2)`. It allocates nothing, formats nothing,
and imports neither `core:fmt` nor `core:log`:

```odin
#assert(len(ERROR_BODY_INTERNAL) == 69)

@(private)
LAST_GASP_500 :: "HTTP/1.1 500 Internal Server Error\r\n" +
	"Content-Type: application/json\r\n" +
	"Content-Length: 69\r\n" +
	"Connection: close\r\n" +
	"\r\n" +
	ERROR_BODY_INTERNAL

@(private)
recovery_last_gasp :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	fd := transport.inflight_fd()
	if fd >= 0 {
		_ = posix.write(posix.FD(fd), raw_data(string(LAST_GASP_500)), len(LAST_GASP_500))
	}
	// Delegate to the runtime's own handler so the operator still gets the
	// panic message and the process still dies the way a supervisor expects.
	runtime.default_assertion_failure_proc(prefix, message, loc)
}
```

The hook is installed at the top of `driver_run` (see FACT 1).

### 4.2 Does it work over a real socket, under `web.serve`?

Yes. Three distinct fault sites — inside a handler with the request arena live,
inside a middleware-shaped `proc(ctx: ^Context)`, and inside the JSON marshal
path — each driven by a real `curl` against a real `web.serve` process:

```
### GET /handler
    HTTP/1.1 500 Internal Server Error
    Content-Type: application/json
    Content-Length: 69
    Connection: close

    {"error":{"code":"internal_error","message":"Internal server error"}}
    SERVER STILL SERVING AFTER FAULT: NO (process died)
    server exit status: 1
    --- server stdout ---
    serving
      [hook] panic: fault inside a handler, request arena live
      [hook] last gasp on fd=7
      [hook] wrote bytes=178
### GET /middleware
    HTTP/1.1 500 Internal Server Error
    ...
      [hook] panic: fault inside a middleware-shaped proc, after its defer was registered
      [hook] last gasp on fd=7
      [hook] wrote bytes=178
### GET /marshal
    HTTP/1.1 500 Internal Server Error
    ...
      [hook] panic: fault inside the JSON marshal path, marshalled buffer unowned
      [hook] last gasp on fd=7
      [hook] wrote bytes=178
```

Identical results at `-o:speed`. The client receives a complete, correct,
standardized 500. **This is a genuine improvement over the baseline, where the
client receives nothing.**

With the `runtime.default_assertion_failure_proc` delegation added, the operator
also keeps the diagnostic and the process dies exactly as it does today:

```
### GET /handler
    HTTP/1.1 500 Internal Server Error
    ... {"error":{"code":"internal_error","message":"Internal server error"}}
    SERVER STILL SERVING AFTER FAULT: NO (process died)
    server exit status: 132
    --- server stdout ---
    serving
    /tmp/wp13-probe/uru_ra/web/wp13_probe.odin(79:2) panic: fault inside a handler, request arena live
```

### 4.3 Does it work for `web.test_request`?

**No.** There is no socket, so there is nothing to write to, and the hook is
`-> !` so it can never hand control back to `test_request`:

```
$ ./t.bin              # R-a, .Lastgasp mode, under test_request
before test_request
  [hook] panic: fault inside a handler, request arena live
  [hook] last gasp on fd=-1
EXIT=1
```

`AFTER test_request -- reached` never prints. A panicking handler **terminates
the whole test binary**, and every assertion after that point in the test file
is silently skipped.

With the delegating variant, behaviour under `test_request` becomes
**byte-identical to the baseline**, which is the better outcome:

```
$ ./t.bin      # R-a delegating variant, against the patched tree
before request
/tmp/wp13-probe/ra_final_test/main.odin(6:34) panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132

$ ./tb.bin     # the same program against the UNMODIFIED repository
before request
/tmp/wp13-probe/ra_final_test/main.odin(6:34) panic: handler exploded
Illegal instruction     (core dumped)
EXIT=132
```

### 4.4 What R-a does not do

Bounds check and nil dereference over a real socket, R-a installed:

```
### GET /bounds
    curl: (52) Empty reply from server
    Illegal instruction (core dumped)
    server exit status: 132
    --- server stdout ---
    serving
    .../wp13_probe.odin(116:7) Index 100 is out of range 0..<3
### GET /nilderef
    curl: (52) Empty reply from server
    Segmentation fault (core dumped)
    server exit status: 139
    --- server stdout ---
    serving
```

The client gets nothing. Per FACT 2, this is unfixable within R-a.

### 4.5 Evidence that R-a is fragile in a way that matters

The first working version of the hook shipped `Content-Length: 68` against a
69-byte body, and truncated the response on the wire:

```
{"error":{"code":"internal_error","message":"Internal server error"}     <- one byte short
```

The hook cannot allocate or format, so the header block **must** be hand-written
and therefore **can drift from the framework's own envelope**. The fix was a
`#assert(len(ERROR_BODY_INTERNAL) == 69)`; without one, the drift is silent.
This is a small bug, but it is exactly the class of bug this mechanism invites.

### 4.6 Costs and hazards of R-a, stated plainly

| Hazard | Detail |
|---|---|
| Boundary hole | `inflight_fd()` exports a raw socket file descriptor out of `web/internal/transport`, which exists (ADR-009) to make the backend invisible. A second adapter with no file descriptor could not implement it. |
| Concurrency | `g_inflight_fd` is a package global. `opts.thread_count = 1` today, so it is safe. The moment Phase 3/4 raises the thread count, a fault on thread A can write a 500 into thread B's connection — a **cross-connection response injection**. |
| Partial write | The nbio socket is non-blocking. 178 bytes always fit in practice, but a full send buffer would yield a short write and a truncated response. The hook cannot safely loop. |
| Streaming | Safe only because the adapter writes nothing before dispatch returns. A future streaming or chunked response makes the last gasp an append into a half-written message — HTTP response splitting. |
| Not middleware | It is a process-wide runtime hook, not a `Handler`, not orderable, and not removable per-route. It cannot be "default-on in `app()`" (FACT 1). |
| Coverage | Panic / assert / type-assertion only. Three of six measured fault classes. |

### 4.7 Verdict on R-a

**Technically works, for the panic class, over a real socket, at negligible
cost.** It is the only candidate that gives a real client a real response on a
real fault. Its problems are architectural, not arithmetic.

---

## 5. Candidate R-b — "already shipped"

> Recovery is redefined as the existing WP8 driver guarantee — a handler that
> commits no response is finalized to 500 by `driver_finalize` — plus honest
> documentation that Odin aborts on panic.

### 5.1 Does the guarantee actually hold today?

Tested against the **unmodified repository**, no patches, no probe files
(`/tmp/wp13-probe/rb/main.odin`), in three build modes:

```
### mode=[default]
app()  /good    -> status=200 body="ok"
app()  /forgot  -> status=500 body="{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}"
app()  /early   -> status=500 body="{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}"
bare() /forgot  -> status=500 body="{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}"
bare() /unmatched -> status=500 body="{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}"
app()  /unmatched -> status=404 body="{\"error\":{\"code\":\"not_found\",\"message\":\"Route not found\"}}"
exit=0

### mode=[-o:speed]      (identical)
### mode=[-disable-assert] (identical)
```

`/forgot` is a handler that responds with nothing. `/early` is a handler that
takes an early-return branch and forgets to respond on it — the realistic case.
Both produce the standardized envelope. `bare()` gets the same guarantee for a
handler that forgets, while correctly keeping its no-404 policy for an unmatched
route.

Over a real socket, `web.serve`, unmodified repository:

```
--- /forgot ---
HTTP/1.1 500
date: Sun, 19 Jul 2026 18:11:43 GMT
content-length: 69
content-type: application/json

{"error":{"code":"internal_error","message":"Internal server error"}}
--- /forgot again ---
status=500
--- /ok after two faults ---
ok status=200
```

**The guarantee holds, in both drivers, in every build mode, repeatably, with
the process healthy afterwards and zero leaked bytes.**

### 5.2 What R-b does not do

It does nothing about an actual fault. A panicking handler still aborts the
process and the client still sees `Empty reply from server`. R-b's contribution
is naming and documenting a guarantee that already exists and already passes its
tests, and refusing to claim more.

### 5.3 Cost

Zero bytes. Zero new public symbols. Zero new code.

---

## 6. Candidate R-c — `setjmp` / `longjmp`

> Genuine continue-after-fault: fence `dispatch` with `setjmp`, and `longjmp`
> out of the assertion hook.

### 6.1 Does it work at all?

Yes, for the catchable fault classes. `driver_run` in the prototype copy:

```odin
	context.assertion_failure_proc = recovery_jump
	if posix.setjmp(&g_recovery_jmp) == 0 {
		g_recovery_armed = true
		dispatch(a, ctx)
	}
	g_recovery_armed = false
	driver_finalize(ctx)
```

Three distinct fault sites, twice each, in two build modes, with a
`mem.Tracking_Allocator` wrapping `context.allocator`. The `/silent` rows are
the calibration: a handler that commits nothing produces the **identical** 500
envelope with no fault at all, so its steady-state retention is exactly what the
test recorder keeps per request. Anything above that number is a real leak.

```
500-envelope recorder retention (baseline, NOT a leak) = 130 bytes

case                 status  recovered   retained       LEAK      churn
silent (warmup)      000500 0000000000 00000450 B 00000320 B 00000450 B
silent (baseline)    000500 0000000000 00000130 B 00000000 B 00000130 B
silent (baseline)    000500 0000000000 00000130 B 00000000 B 00000130 B
handler fault        000500 0000000001 00000130 B 00000000 B 00065730 B
handler fault        000500 0000000001 00000130 B 00000000 B 00065730 B
middleware fault     000500 0000000001 00008322 B 00008192 B 00008322 B
middleware fault     000500 0000000001 00008322 B 00008192 B 00008322 B
marshal fault        000500 0000000001 00000186 B 00000056 B 00000218 B
marshal fault        000500 0000000001 00000506 B 00000376 B 00000858 B
marshal fault        000500 0000000001 00000186 B 00000056 B 00000218 B
marshal fault        000500 0000000001 00000186 B 00000056 B 00000218 B

DONE - process survived every fault above
```

Byte-for-byte identical at `-o:speed`. Every recovered fault produced the
standardized 500, and the second fault behaved like the first.

### 6.2 Leaked bytes per recovered fault — measured

| Fault site | What is live at the moment of the fault | LEAK per fault |
|---|---|---|
| Handler, request arena live | 4 KiB allocated into the request arena (64 KiB block) | **0 bytes** |
| Middleware-shaped proc | 8 KiB buffer released by a `defer` | **8,192 bytes** |
| JSON marshal path | marshalled buffer not yet owned by the `Response` | **56 bytes** |

**An important correction to FINDING-A.** FINDING-A predicted that `longjmp`
would leak "the request arena, the owned response body and the connection
state". It does **not**, provided the jump target is placed *inside*
`driver_run`. The framework's own teardown — `driver_cleanup`, which calls
`response_destroy` then `request_arena_destroy` — runs *after* `driver_run`
returns, so it is **below** the jump target and is never skipped. The 64 KiB
arena block is fully reclaimed (visible as `churn=65730 B` with `LEAK=0`). The
adapter's connection frames are further down the stack and are untouched.

What R-c actually leaks is precisely **every `defer` between the jump target and
the fault** — which in practice means user code and any framework code inside
`dispatch`. The 8,192-byte row is that, exactly: one skipped
`defer delete_slice(scratch, context.allocator)`.

### 6.3 What R-c does not cover

```
##### BOUNDS mode=[default]
    .../wp13_probe.odin(89:7) Index 108 is out of range 0..<3
    Illegal instruction (core dumped)          REAL_EXIT=132
##### BOUNDS mode=[-o:speed]                   REAL_EXIT=132
##### NILDEREF mode=[default]
    Segmentation fault (core dumped)           REAL_EXIT=139
##### NILDEREF mode=[-o:speed]                 REAL_EXIT=0    <- see below
```

The `-o:speed` nil-dereference row shows `NIL DEREF status=500 recovered=0`.
**That is not recovery.** The optimiser deleted the unused load, so the fault
never occurred; the handler simply committed nothing and the ordinary R-b driver
guarantee produced the 500. Reporting this as a success would be false.

### 6.4 The soundness problem: Odin's `setjmp` is not marked `returns_twice`

`core/sys/posix/setjmp_libc.odin` binds `setjmp` as an ordinary foreign
procedure. LLVM is therefore free to keep locals in registers across the call.
In C, locals modified after `setjmp` and read after `longjmp` are indeterminate
unless declared `volatile` — **and Odin has no `volatile`.**

`/tmp/wp13-probe/rc_twice/main.odin` writes three locals inside the fenced
region and reads them after the jump:

```
### mode=[default]
n=1 got a=1 b=1 c=1  expected a=10 b=11 c=12  *** CLOBBERED ***
n=2 got a=1 b=1 c=1  expected a=20 b=22 c=24  *** CLOBBERED ***
n=3 got a=1 b=1 c=1  expected a=30 b=33 c=36  *** CLOBBERED ***
### mode=[-o:speed]        *** CLOBBERED ***  (identical)
### mode=[-o:aggressive]   *** CLOBBERED ***  (identical)
```

Every local reads back its **pre-`setjmp`** value. This is not a theoretical
hazard; it happens at `-o:none`.

A second probe (`/tmp/wp13-probe/rc_twice2/`) shows the *exact* shape a real
`driver_run` would use — a pointer parameter written through, plus a global and
a local written only on the recovery arm — and that shape happens to be correct:

```
iter=1  ctx.tag=7 (expect 7)  ctx.status=500 (expect 500)  recovered_local=true  g_counter=1
iter=2  ctx.tag=14 ...        ctx.status=500               recovered_local=true  g_counter=2
iter=3  ctx.tag=21 ...        ctx.status=500               recovered_local=true  g_counter=3
```

So R-c is not *automatically* broken. It is **silently undefined**, and the
difference between the correct shape and the miscompiled shape is one line of
ordinary-looking code, with no compiler diagnostic and no way to make it sound.
A framework cannot ship a guarantee on that footing, and no test can defend it —
the failure mode is a future optimiser, not a future commit.

### 6.5 R-c's other, deeper problem

A fault is evidence that an invariant the programmer believed was broken.
Continuing to serve means continuing on top of that broken invariant, with
partially-mutated data structures, a possibly half-updated allocator, and no
way to know which. R-c converts a loud, diagnosable crash into a quiet,
undiagnosable wrong answer.

### 6.6 Verdict on R-c

**Reject.** It covers only the minority fault classes, it relies on behaviour
Odin cannot make well-defined, it leaks per fault (section 8), and it trades a
crash for silent corruption.

---

## 7. Candidate R-d — "no recovery"

Remove the item from Phase 2 and amend the phases doc. Nothing to measure; the
cost is zero and the coverage is zero.

R-d differs from R-b only in what it says. R-b keeps a Phase-2 gate item, points
it at a guarantee that demonstrably holds and is already tested, and requires the
documentation to state the abort behaviour. R-d deletes the item and leaves the
abort behaviour undocumented. **R-b is strictly better than R-d for the same
price**, because "we tested that a handler which forgets to respond produces a
500, and we wrote down that a handler which faults kills the process" is a
guarantee a user can rely on, and silence is not.

---

## 8. Binary cost, for the default-on case

`app()` is on every application's static path, so nothing here can be lazily
linked the way the test-support facade is (G-11). Measured with a minimal
`web.serve` application (`/tmp/wp13-probe/cost/appsrc/`), identical source,
three collection roots.

```
$ size base.bin ra_final.bin rc.bin
   text	   data	    bss	    dec	    hex	filename
 617717	 162784	  10488	 790989	  c11cd	base.bin        (unmodified repository)
 618148	 162800	  10480	 791428	  c1384	ra_final.bin    (R-a)
 618344	 162821	  14592	 795757	  c246d	rc.bin          (R-c)

R-a: text  +431  data +16  bss    -8  file +432 bytes
R-c: text  +627  data +37  bss +4104  file +376 bytes
R-b: text    +0  data  +0  bss    +0  file   +0 bytes
R-d: text    +0  data  +0  bss    +0  file   +0 bytes
```

R-c's +4,104 bss is the `jmp_buf`, which `core/c/libc` declares as
`struct #align(16) { _: [4096]char }` — a fixed 4 KiB of BSS in every binary.

**The `core:fmt` / `core:log` hard rule is satisfied by both hook candidates:**

```
base.bin       fmt::80   log::13
ra_final.bin   fmt::80   log::13
rc.bin         fmt::80   log::13
```

Identical symbol counts — neither candidate adds a single `fmt` or `log` symbol.
New symbols introduced by R-a, in full:

```
transport::g_inflight_fd
transport::inflight_fd
web::[recovery.odin]::recovery_last_gasp
write@GLIBC_2.2.5
```

*(Separate observation for the owner, outside WP13's scope: `fmt::` and `log::`
symbols are **already** present in the baseline binary. They come in through
`vendor/odin-http`, not through `web/`. The WP6 discipline of keeping `web/` free
of `core:fmt` and `core:log` is being honoured, but the vendored backend spends
that budget anyway. Worth a look in a later work package.)*

---

## 9. Security: is a recovered process worse than a clean abort?

**Yes, if it leaks — and R-c leaks. This must be stated plainly.**

A process that keeps serving after a fault, while leaking per-request state,
turns any reachable faulting route into a **remote memory-exhaustion vector**.
The supervisor never sees a crash, so nothing restarts, and the process degrades
until the kernel OOM-kills it — at which point every in-flight request on that
process dies too, not just the malicious one.

Measured. 20,000 requests, R-c fence installed, one skipped `defer` per fault
(`/tmp/wp13-probe/soak/`):

```
### faulting path (R-c recovers every request)
    reqs     live_bytes    live_allocs     rss_kb
00005000   00041938017         0025004      053004
00010000   00083875697         0050004      103984
00015000   00125485697         0075004      145712
00020000   00167751057         0100004      205844

### clean path (control)
    reqs     live_bytes    live_allocs     rss_kb
00005000   00000688017         0020004      007760
00010000   00001375697         0040004      013676
00015000   00001735697         0060004      024200
00020000   00002751057         0080004      025480
```

- **8,250 bytes leaked per recovered fault** ((167,751,057 − 2,751,057) ÷ 20,000).
- **~9.2 KiB of resident memory per fault** ((205,844 − 25,480) KiB ÷ 20,000).
- Growth is perfectly linear and unbounded. Nothing reclaims it.

> **Note added 2026-07-31 — 8,250 here, 8,192 in the matrix at the end of this
> document, and both are right.** This figure is the arithmetic **mean over the
> whole 20,000-request soak**, so it carries the per-request allocator overhead
> that rides along with the leak. The matrix figure is the **single 8 KiB buffer**
> the skipped `defer` failed to release — the leak's identified cause, not its
> measured total. Quote whichever you mean, and say which.
>
> **Neither is reproducible from this repository.** Everything below lived in
> `/tmp/wp13-probe/` and was never committed; the directory is gone. This
> document predates the rule now in `planning/verification-campaign-plan.md`
> that every reported number must be regenerable from a committed script, and it
> does not meet it. ADR-020 does not rest on the constant — it rests on the shape
> in §9: linear, unbounded, and invisible to the supervisor.
>
> **The shape has since been re-measured from committed code, and the two
> figures turn out to be consistent rather than contradictory.**
> `experiments/26-adr020-leak-shape` drives 20,000 requests per arm through
> `web.test_request` under a tracking allocator, leaking one request-scoped 8 KiB
> buffer in the faulting arm. It reports **8,192.0 bytes per request, 0.0
> residue, 0.0% linearity drift** — the shape confirmed, to the byte.
>
> That result names the ~58-byte gap this note could only flag: the R-c fence
> skipped **every** `defer` between the fault site and itself, so 8,250 counts
> the buffer *plus* the request's other deferred frees, while 8,192 counts the
> buffer alone. Only a real fence produces the larger figure, and there is no
> fence, so it stays unreproducible — but it is no longer unexplained.

At a modest 1,000 requests/second against one faulting route, that is about
**8 MB/s**; a 4 GiB container is exhausted in roughly **8 minutes**, while
answering `500` the entire time and never signalling a supervisor.

(The control column also grows, because `web.test_request`'s recorder
deliberately retains every response until `web.destroy` — that is documented
behaviour of the test driver, not a leak, and it is why the clean line is the
subtracted baseline rather than zero.)

Against this, the baseline behaviour — abort with SIGILL, exit 132, supervisor
restarts in milliseconds — is the **safer** outcome. It is loud, it is bounded,
it produces a core dump, and it cannot be weaponised into a slow denial of
service. R-a preserves that property exactly (it aborts with the same signal and
the same exit code, leaking nothing, because the process ends). R-c destroys it.

---

## 10. Comparison

| | R-a last gasp | R-b already shipped | R-c setjmp | R-d no recovery |
|---|---|---|---|---|
| Client gets a 500 on a **panic** | **yes** (serve only) | no | yes | no |
| Client gets a 500 on **bounds / nil / div** | no | no | no | no |
| Client gets a 500 when a handler **forgets to respond** | yes | **yes** | yes | yes |
| Process survives the fault | no | n/a | yes | no |
| Leak per fault | 0 (process ends) | 0 | **8,192 B** measured | 0 |
| Works under `test_request` | aborts (= baseline) | **yes** | yes | aborts (= baseline) |
| `serve` / `test_request` parity | asymmetric | **exact** | exact | exact |
| Relies on undefined behaviour | no | no | **yes, proved** | no |
| Binary cost (default-on) | +432 B | **0** | +376 B file, +4,104 B bss | 0 |
| Adds `core:fmt` / `core:log` | no | no | no | no |
| Can be "default-on in `app()`" | **no** (FACT 1) | n/a | **no** (FACT 1) | n/a |
| New public symbols | 0–1 | **0** | 0–1 | 0 |
| Opens the transport boundary | **yes** (raw fd) | no | no | no |

---

## 11. Recommendation

**Adopt R-b.** Redefine recovery as the driver guarantee Druse already ships
and already tests, and document plainly that a faulting handler aborts the
process. Do **not** export a `recovery` symbol. Amend the phases doc as in
section 12.

**Defer R-a to Phase 4**, as a named, optional, explicitly non-middleware
feature — call it a *last-gasp responder*, never "recovery" — gated on three
prerequisites that Phase 2 cannot satisfy:

1. a transport-boundary answer better than exporting a raw file descriptor;
2. per-connection rather than package-global in-flight state, so it stays
   correct when `thread_count` rises above 1;
3. a decision on streaming responses, since a last gasp appended to a
   half-written message is HTTP response splitting.

**Reject R-c** on the evidence in sections 6.4 and 9.
**Prefer R-b over R-d** for the reason in section 7.

### The strongest argument AGAINST this recommendation

**R-b is a rename, not a feature, and it leaves the client worse off than the
framework is capable of making it.**

R-a was built, run against a real socket with real `curl`, and shown to deliver a
complete, correct, standardized 500 to a real client on a real panic at three
different fault sites in two build modes, for **432 bytes**, with **zero** leaked
memory, **zero** new `fmt`/`log` symbols, **byte-identical** behaviour on the
healthy path, **byte-identical** behaviour under `test_request`, and the **same**
exit code 132 that a supervisor already watches for. It costs less than a single
route entry. Choosing R-b means that every panicking handler in every Druse
application drops the connection with no response at all, so the client sees
`curl: (52) Empty reply from server` and cannot tell a server bug from a network
failure, a load-balancer timeout, or a hostile reset. Retries will hammer the
same broken route. "We were honest about it" does not help that client.

The counter is that R-a's 432 bytes buy a courtesy response on **three of six**
measured fault classes; that it is not middleware, cannot be default-on in
`app()`, and cannot be ordered, disabled or scoped; that it makes the two
response drivers behave differently for the first time, which is precisely the
structural parity R-10 exists to protect; that it requires exporting a raw socket
file descriptor out of the boundary ADR-009 built to hide the backend; and that
its package-global in-flight descriptor becomes a cross-connection response
injection the moment Phase 3 raises the thread count. Every one of those is a
Phase-2 commitment that would be expensive to walk back.

That is why the recommendation is R-b **and** an explicit Phase-4 slot for R-a,
rather than R-b alone. The owner should be aware that a real capability is being
deferred, not that no capability exists.

---

## 12. Exact amendment text for `knowledge-base/03-development-phases.md`

Three edits, all inside `## Phase 2 — Middleware and Groups`.

### 12.1 §Scope (required)

**Remove this line:**

```
- recovery middleware — becomes default-on in `web.app()`
```

**Replace it with:**

```
- **no recovery middleware — Odin cannot recover from a fault, and the
  framework will not pretend otherwise.** Measured on the pinned toolchain in
  `planning/phase-2-prototype-recovery.md` (WP13): `panic` and
  `context.assertion_failure_proc` are typed `-> !` and may not return, there
  is no `recover` anywhere in `base/` or `core/`, and bounds-check,
  nil-dereference and divide-by-zero faults never reach the assertion hook at
  all — they trap directly. A hook also cannot be installed by `web.app()`,
  because `context` is copied per procedure and the assignment dies with
  `app()`'s frame. What Phase 2 guarantees instead is the **driver guarantee**,
  which already ships (WP8 D5): a handler that commits no response — including
  one that returns early on an error branch — is finalized by the response
  driver to a logged, standardized `internal_error` 500, identically under
  `web.serve` and `web.test_request`. A handler that *faults* aborts the
  process; the documentation says so plainly, and Druse is expected to run
  under a supervisor. A last-gasp responder that writes a 500 to the in-flight
  socket before aborting is feasible and cheap, and is deferred to Phase 4 —
  it is not middleware and cannot be a default of `app()`.
```

### 12.2 §Spec Gate checklist

**Remove this line:**

```
- [ ] recovery semantics; request ID source/generation
```

**Replace it with:**

```
- [ ] the driver guarantee's exact documented wording, including the statement
      that a faulting handler aborts the process; request ID source/generation
```

### 12.3 §Test Gate checklist

**Remove this line:**

```
- [ ] recovery converts panic to standardized 500
```

**Replace it with these two:**

```
- [ ] the driver guarantee holds: a handler that commits no response produces
      the standardized `internal_error` 500 under BOTH `web.serve` and
      `web.test_request`, in default and `-o:speed` builds, and a second such
      request behaves identically
- [ ] no symbol named `recovery` is exported, and the documentation states that
      a faulting handler aborts the process (G-08: do not claim a default that
      is not delivered)
```

### 12.4 Knock-on effect on the Phase-2 work-package plan

`WP21 — Recovery: default in app(), absent in bare()` becomes a **documentation
and gate work package** with a public surface of **0**. Its RED tests are the two
Test Gate items above, and the phases-doc amendment in 12.1–12.3 lands there.
`planning/phase-2-plan.md` §"Public surface" should record `recovery` as a symbol
that does **not** exist, exactly as its own table already anticipated for the
R-b/R-d outcome.

---

## 13. Reproducing this document

Everything is under `/tmp/wp13-probe/`. Nothing in the repository was modified.

| Directory | What it proves |
|---|---|
| `baseline/` | §1 — a panic kills the process, four build modes |
| `ctxscope/` | §2 FACT 1 — `context` assignment does not survive a return |
| `facts/` | §2 FACT 2, §3 — which fault classes reach the hook, five build modes |
| `uru/`, `rc/`, `soak/` | §6, §9 — R-c fence, leak accounting, exhaustion soak |
| `rc_twice/`, `rc_twice2/` | §6.4 — the `returns_twice` miscompilation |
| `uru_ra/`, `ra/`, `ra2/`, `ra_test/`, `ra_final_test/` | §4 — R-a over a real socket and under `test_request` |
| `rb/`, `rb_serve/` | §5 — the shipped driver guarantee, unmodified repository |
| `cost/` | §8 — `size` and `nm` measurements |

Build command shape used throughout:

```
env -u ODIN_ROOT ODIN_ROOT=/tmp/druse-toolchain \
  /tmp/druse-toolchain/odin build <dir> \
  -collection:druse=<root> -out:<bin>
```

Patched trees (`uru/`, `uru_ra/`, `uru_rc/`) are copies of `web/` and `vendor/`
with probe files added, following `build/check.sh:104`.

---

# Independent verification (integrator)

Three claims were re-derived from scratch by the integrating agent rather than
trusted from the probe run. Two confirmed. One is corrected on methodology.

## Confirmed — `web.app()` can never install a hook

Odin's `context` is an implicit by-value parameter, so an assignment inside a
callee dies with that callee's frame. Reproduced minimally:

```odin
app_like :: proc() { context.assertion_failure_proc = hook }   // models web.app()
main :: proc() {
	app_like()
	// -> after callee set it, caller sees hook installed: false
}
```

This is decisive and it is not a property of any candidate: **the phases-doc
phrase "recovery middleware — becomes default-on in `web.app()`" is unachievable
in Odin for every hook-based design.** Any hook must be installed in the frame
that dispatches — `driver_run` — not by `app()`.

## Confirmed — most real faults never reach the hook

A custom `assertion_failure_proc` was installed and each fault class triggered:

| Fault | Hook ran? | Exit |
|---|---|---|
| explicit `panic` | **yes** | 70 (hook's own exit) |
| bounds check | **no** — printed its own message and died | 132 |
| nil dereference | **no** | see note |

The bounds-check case is the important one: index-out-of-range is among the most
common real runtime faults, and it bypasses the hook entirely. Any "last gasp"
design therefore covers a minority of the faults that actually happen.

*Note on nil dereference:* an independent probe at default optimisation printed
`<nil>` and returned normally instead of faulting, which the integrator did
**not** treat as evidence that nil dereferences are safe. That result is
consistent with the probe run's own finding that the optimiser can delete a dead
load — undefined behaviour, not a guarantee. It is recorded as inconclusive
rather than resolved.

## Corrected on methodology — the `fmt`/`log` symbol counts

The incidental finding is real and important: **`web/` imports neither
`core:fmt` nor `core:log`, and the symbols in a `serve` binary arrive through
`vendor/odin-http`.** Verified by reading the actual import lines:

```
web/errors.odin:20  import encoding_json "core:encoding/json"
web/errors.odin:21  import "core:mem"
web/errors.odin:22  import "core:strings"
```

A naive `grep -l 'core:fmt\|core:log' web/*.odin` *appears* to match
`web/errors.odin`, but every hit is inside the comment block at `:610-629`
explaining why that file deliberately does not import them. Anyone re-checking
this must grep import lines, not file contents.

The **counts** differ between runs and should not be quoted as exact. The probe
run reported 80 `fmt::` and 13 `log::`; an independent build of a minimal
`serve` application counted 11 `fmt.` and 0 `log.`. The discrepancy is a
difference of pattern and build flags, not of substance, and no single number
should enter a planning document until one method is agreed.

**The conclusion that survives both measurements:** WP6's discipline is being
honoured inside `web/`, and the vendored backend spends part of that budget
anyway. That is a Phase-4 vendor-maintenance item (audit A-9), not a Phase-2
blocker.
