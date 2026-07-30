# WP12 — Middleware mechanism prototype: findings

**Type: PROTOTYPE. No production file was modified. This document is the only
repository output.**

Toolchain: `/tmp/druse-toolchain/odin`, version
`dev-2026-07-nightly:819fdc7` — the pin in `odin-version.txt`. Every command
below was run with `env -u ODIN_ROOT` so that the pinned distribution resolves
its own `core`.

Machine: Linux 6.8.0-86-generic, x86_64, default `ulimit -s` = 8192 KiB.

---

## How to read this document

You do not need to run anything. Every section states the command that was run,
the output it produced verbatim, and what that means. Where the plan required a
probe to be *able to fail*, a **negative control** was run first: a deliberately
broken version, proving the measurement detects the failure it claims to rule
out.

Nothing here is a promise. WP15 ratifies; WP12 only reports what the compiler
and the machine did.

---

## The prototype, in one page

The prototype is a copy of `web/` in a throwaway directory, plus one new file,
`middleware_proto.odin`, plus small additions to five copied files. **The
repository's `web/` was not touched.** The technique is the one
`build/check.sh:104` already uses for internal tests: copy `web/*.odin` into a
fresh directory, add files declaring `package web`, and run `odin test` or
`odin build` on that directory.

The shape under test:

```odin
// Middleware IS the frozen Handler type. No new type.
use  :: proc(a: ^App, middleware: Handler)
next :: proc(ctx: ^Context)

get  :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler)
```

Three mechanisms:

1. **Flattening at registration.** `use` appends to an App-owned list of global
   middleware. Each `get`/`post`/… appends `globals ++ route-middleware ++
   handler` into one App-owned pool (`[dynamic]Handler`), and the route stores
   the **index pair** `chain_start, chain_len` — never a slice.
2. **A monotonic cursor.** The Context carries `chain: []Handler` (materialised
   at dispatch from the pool) and `chain_index: int`. `next` reads the index,
   advances it, then calls that step. It is never rewound.
3. **A miss chain.** A second flattened chain of the globals terminating in a
   step that performs the automatic 404/405, so global middleware observes a
   miss.

Ownership, one sentence each:

* `mw_globals: [dynamic]Handler` — owned by the App, created lazily on the first
  `use`, freed exactly once by `destroy`.
* `mw_pool: [dynamic]Handler` — owned by the App, created lazily on the first
  registration, freed exactly once by `destroy`.
* `ctx.private.chain` — a **view** over `mw_pool`, valid only for the request;
  it owns nothing and is never freed.
* Nothing per-request is allocated (P9).

---

## Files created (all outside the repository)

```
/tmp/wp12-probe/root_mw/web/middleware_proto.odin   the new machinery
/tmp/wp12-probe/root_mw/web/{app,context,dispatch_table,dispatch_match,routing}.odin
                                                    copies, with the additions below
/tmp/wp12-probe/root_base/web/*.odin                pristine Phase-1 copies (baseline)
/tmp/wp12-probe/root_mwc/                           as root_mw but with the P9
                                                    negative control removed, used
                                                    for the honest P11 binary figure
/tmp/wp12-probe/tests/*.odin                        the probe tests
/tmp/wp12-probe/p10/, p11/, d121/, d125/            standalone probe programs
```

The additions to the copied files, in full:

* `app.odin` — four fields on `App_Internal` (`mw_pool`, `mw_globals`,
  `miss_start`, `miss_len`) and one call, `mw_destroy(a)`, in `destroy`.
* `context.odin` — three fields on `Context_Internal` (`chain`, `chain_index`,
  `miss_app`).
* `dispatch_table.odin` — two int fields on `Route_Entry` (`chain_start`,
  `chain_len`); `route_register` gained `route_mw: ..Handler` and one call to
  `chain_flatten`.
* `dispatch_match.odin` — `dispatch` calls `chain_run` instead of
  `entry.handler(ctx)`, and the 404/405 tail was replaced by the miss chain.
* `routing.odin` — the five registration procedures gained
  `middleware: ..Handler`.

---

# P1 — a cursor and `next` compile, reusing the frozen `Handler` type

### Command

```
cd /tmp/wp12-probe && rm -rf runall && mkdir runall \
  && cp root_mw/web/*.odin runall/ && cp tests/*.odin runall/
env -u ODIN_ROOT /tmp/druse-toolchain/odin test /tmp/wp12-probe/runall \
  -collection:druse=/tmp/wp12-probe/root_mw \
  -out:/tmp/wp12-probe/out/runall -define:ODIN_TEST_THREADS=1
```

(`-define:ODIN_TEST_THREADS=1` is required: the probes share one ordering buffer,
and the default parallel runner interleaves them into nonsense. That was
observed, not assumed — the first run produced
`"P>H<PA><AA>B>A><BC>HH<C<B<A…"`.)

### Output (the P1 line)

```
P1  1 global + handler        : A>H<A
```

with `status=OK`.

`A>` is "middleware A entered", `H` is "the route handler ran", `<A` is
"middleware A resumed after `next` returned".

### Conclusion

**It compiles and it works, with no new type.** The middleware is declared as an
ordinary `proc(ctx: ^web.Context)` — the frozen `Handler` shape — and is
registered with `use(&app, mw_a)` without a cast. The cursor is two fields on
`Context_Internal` and adds no public name.

---

# P2 — exact pre-order across three global middleware and a route handler

### Command

Same run as P1.

### Output

```
P2  3 globals + handler       : A>B>C>H<C<B<A
```

### Conclusion

**Registration order is execution order.** `use(A)`, `use(B)`, `use(C)` then
`get("/x", H)` produces exactly `A → B → C → H`, and unwinds `C → B → A`. The
string is the complete, exact observed order; there is no interleaving and no
surprise.

Route-level middleware nests inside the globals:

```
P12 global A + route-level B,C: A>B>C>H<C<B<A
```

from `use(&a, mw_a); get(&a, "/x", h_final, mw_b, mw_c)` — the globals run
first, then the route's own, then the handler.

---

# P3 — short-circuit

Middleware 2 responds and returns **without** calling `next`.

### Output

```
P3  short-circuit at mw2      : A>STOP<A   status=Forbidden body="denied"
```

Asserted, and the assertions passed:

* the order string is exactly `A>STOP<A`;
* it contains no `C>` — middleware 3 never ran;
* it contains no `H` — the handler never ran;
* the status is `Forbidden` and the body is `"denied"` — the short-circuiting
  middleware's own response is what the client gets.

### Conclusion

**Short-circuit works and is total.** Everything after the middleware that
declined to call `next` — later middleware *and* the route handler — does not
run. Middleware 1 still resumes (`<A`), which is what makes a logger able to log
a rejected request.

---

# P4 — post-`next` code runs, and the unwind order is the exact reverse

### Output

```
P2/P4  3 globals + handler    : A>B>C>H<C<B<A
```

The P4 test splits that string and asserts the two halves independently:
pre-order `A>B>C>` and unwind `<C<B<A`.

### Conclusion

**Code after `next` runs, and the unwind is the exact reverse of the entry
order.** This is a property of the recursion, not of bookkeeping: each
middleware's frame is still live while the rest of the chain runs, so its
post-`next` statements execute as that frame returns.

This is what makes timing middleware and "log the status we ended up sending"
possible — and it is also the reason the stack is consumed linearly (P10).

---

# P5 — a post-`next` attempt to respond is rejected by the existing guard

The middleware calls `next`, then — after the handler has already committed a
200 — calls `web.text(ctx, .Internal_Server_Error, "late")`. **No new response
writer was added**: this goes through the shipped `text` responder and therefore
through the shipped `response_commit_owned` guard.

### Output

```
P5  post-next respond attempt : P>H<P   status=OK body="handler"
```

A second probe (`p5b`) does the same through `no_content`, which uses the *other*
commit path, `response_commit`:

```
P5b: order "N>H<N", status OK, body "handler"   (asserted, passed)
```

### Conclusion

**The existing single-commit guard already covers this, on both commit paths,
with no change.** The late response is discarded; the first response survives
byte-identically — same status, same body. `response_commit_owned` additionally
frees the late body immediately, so the rejected attempt does not leak.

This is the audit's A-7 concern answered: middleware needs **no** seventh
response writer.

---

# P6 — `next` called twice by one middleware

The middleware body is `mark("T>"); next(ctx); next(ctx); mark("<T")`.

### Output

```
P6  next() called twice       : T>B>H<B<T   status=OK
```

### Conclusion

**The second `next` is a silent no-op. The handler runs exactly once.**

This is not luck; it falls out of the cursor being monotonic. By the time the
first `next` returns, the index has been advanced past the end of the chain by
the steps below, so the second call finds `chain_index >= len(chain)` and
returns immediately.

Note this **contradicts the assumption written into the plan** ("re-entering the
remainder runs the handler twice and the second response is rejected by the
commit guard"). With this cursor design there is nothing to re-enter and nothing
for the guard to reject. A design that stored a per-frame index instead of one
per-request index *would* re-run the remainder; the monotonic design was chosen
and measured, and it is strictly better.

---

# P7 — a middleware that neither calls `next` nor responds

### Output

```
P7  neither next nor respond  : S   status=Internal_Server_Error
```

with the framework log line:

```
druse: a handler returned without producing a response; the driver is sending
500. A handler must call a web.* responder, or the route is a bare() miss.
```

and the asserted body equal to `ERROR_BODY_INTERNAL`.

### Conclusion

**Yes — the existing WP8 D5 `driver_finalize` already handles it, unchanged.**
A middleware that falls off the end without responding is indistinguishable, to
the driver, from a handler that did the same: the response is uncommitted, so
the driver logs and sends the standard 500 envelope. It does not hang, and it
does not fabricate a 200.

---

# P8 — CRITICAL: chain storage that cannot dangle

Three parts. The first is the required **negative control**: it must actually
reproduce the corruption, or it is not evidence.

To make the reproduction deterministic the pool uses an allocator that **fills
every block it releases with `0xAA`** before freeing it. Without that, whether
the bug shows depends on whether the heap happens to reuse the block — see P8b,
which is the more alarming result.

### Command

Same `odin test` run as P1.

### Output — half 1: `[]Handler` slice storage

```
P8 pool data pointer before growth = 0x781f325fd048  (len=2 cap=8)
P8 stored []Handler[0] = 0x5ebff2a5d430  expected h1 = 0x5ebff2a5d430
P8 pool data pointer after  growth = 0x781f325fd428  (len=66 cap=128)
P8 stored slice still points at    = 0x781f325fd048
P8 HALF 1 (slice storage): stored_slice[0] = 0xaaaaaaaaaaaaaaaa, h1 = 0x5ebff2a5d430  -> CORRUPT
```

The pool moved from `…d048` to `…d428`. The stored slice still points at
`…d048`, which is now freed memory. Reading step 0 of the chain yields
`0xaaaaaaaaaaaaaaaa` — not a procedure. **Calling through it would jump to a
garbage address.**

### Output — half 2: index-pair storage

```
P8 HALF 2 (index pair):    pool[0:2][0] = 0x5ebff2a5d430, h1 = 0x5ebff2a5d430  -> CORRECT
```

The same chain, stored as `start=0, len=2` and re-sliced from the pool's current
storage, resolves to exactly the right handler. **Immune.**

### Output — the same thing through the REAL registration path

`p8c` builds a real `App` on the poisoning allocator, registers one route,
captures the slice a naive `Route_Entry` would have stored, then registers 64
more routes:

```
P8c after 1 registration: naive slice[0] = 0x5ebff2a5d430 (h1 = 0x5ebff2a5d430)
P8c after 65 registrations: naive slice[0] = 0xaaaaaaaaaaaaaaaa  -> CORRUPT
P8c index pair (0,1) resolves to 0x5ebff2a5d430 -> CORRECT
```

### Output — P8b, the same bug on the ordinary heap

```
P8b plain heap allocator: pool moved false (0x781f325fd048 -> 0x781f325fd048);
    stale slice reads THE CORRECT VALUE ANYWAY (silent latent bug)
```

### Conclusion

**Confirmed exactly as the plan predicted, and worse than predicted.**

Storing `[]Handler` on a `Route_Entry` produces a use-after-free the moment the
pool reallocates. And on the ordinary allocator the pool sometimes grows *in
place*, so the same wrong code reads back correctly and the test suite passes —
a latent corruption that appears only at some particular route count, on some
particular machine, in production.

**Index pairs (`chain_start`, `chain_len`) are immune by construction** and cost
two ints per route. There is no reason to consider anything else.

---

# P9 — CRITICAL: zero allocations at dispatch

Measured with `mem.Tracking_Allocator` wrapped around **both** `context.allocator`
and `context.temp_allocator`, around the real pipeline `driver_run` +
`driver_cleanup` — the same procedures `serve` runs. (Deliberately not
`test_request`: the test recorder makes owned copies of every response by
design, so counting those would measure the test transport, not the chain.)

Five middleware, and a terminal handler (`no_content`) that allocates nothing of
its own, so the number reported is the chain machinery's own cost.

A warm-up request runs first, outside the measurement, so one-time lazy
initialisation is not counted.

### Negative control

`CHAIN_ALLOC_NEGATIVE_CONTROL` switches `chain_run` to copy the chain into a
fresh per-request allocation — the exact mistake the measurement must catch.

### Output

```
P9 NEGATIVE CONTROL (chain copied per request): allocations=1 temp_allocations=0 bytes=48
P9 REAL (index-pair chain, 5 middleware):       allocations=0 temp_allocations=0 bytes=0
```

### Conclusion

**The measurement can fail — it caught the deliberately allocating chain (1
allocation, 48 bytes). The real chain allocates nothing: zero allocations, zero
bytes, and it does not touch the temp allocator either.**

This is the acceptance criterion the plan set, and it is met. The cursor is two
field writes on a Context that already exists; the chain is a view over storage
the App already owns.

---

# P10 — stack depth: where recursion actually breaks

`next` is recursive by construction. That is not an implementation choice that
could be avoided while keeping post-`next` code (P4): a middleware's frame must
stay live while the rest of the chain runs.

### Command

```
env -u ODIN_ROOT /tmp/druse-toolchain/odin build /tmp/wp12-probe/p10 \
  -collection:druse=/tmp/wp12-probe/root_mw -out:/tmp/wp12-probe/out/p10
for n in 1 8 64 512 4096; do /tmp/wp12-probe/out/p10 $n; done
```

The program registers N middleware, dispatches one request, and reports the
distance between a stack address taken before dispatch and one taken in the
deepest frame.

### Output — default (debug) build, 8 MiB stack

```
N=1  status=No_Content  middleware_entered=1  stack_bytes=1904  bytes_per_frame=1904.0
N=8  status=No_Content  middleware_entered=8  stack_bytes=2464  bytes_per_frame=308.0
N=64  status=No_Content  middleware_entered=64  stack_bytes=6944  bytes_per_frame=108.5
N=512  status=No_Content  middleware_entered=512  stack_bytes=42784  bytes_per_frame=83.6
N=4096  status=No_Content  middleware_entered=4096  stack_bytes=329504  bytes_per_frame=80.4
```

(The `bytes_per_frame` at small N is dominated by the fixed ~1.8 KiB of dispatch
frames below the chain; the marginal cost per middleware is 80 bytes.)

### Output — finding the break

```
N=32768  status=No_Content  ... stack_bytes=2623264  bytes_per_frame=80.1
N=65536  status=No_Content  ... stack_bytes=5244704  bytes_per_frame=80.0
N=100000 status=No_Content  ... stack_bytes=8001824  bytes_per_frame=80.0
N=104000 status=No_Content  ... stack_bytes=8321824  bytes_per_frame=80.0
N=106000 -> SEGFAULT
N=107000 -> SEGFAULT
N=108000 -> SEGFAULT
N=110000 -> SEGFAULT
N=200000 -> SEGFAULT
```

### Output — `-o:speed`

```
N=1     stack_bytes=47     bytes_per_frame=47.0
N=8     stack_bytes=159    bytes_per_frame=19.9
N=64    stack_bytes=1055   bytes_per_frame=16.5
N=512   stack_bytes=8223   bytes_per_frame=16.1
N=4096  stack_bytes=65567  bytes_per_frame=16.0
```

### Output — a deliberately small stack (models a constrained worker thread)

```
ulimit -s 512   # 512 KiB
N=512   OK (42784 bytes)
N=4096  OK (329504 bytes)
N=6000  OK (481824 bytes)
N=6500  -> SEGFAULT
N=8000  -> SEGFAULT
```

### Table

| build | stack | bytes per middleware | practical bound |
|---|---|---|---|
| debug (default) | 8 MiB | 80 | **~105,000** (OK at 104,000; crashes at 106,000) |
| `-o:speed` | 8 MiB | 16 | **~500,000** (extrapolated from 16 B/frame) |
| debug (default) | 512 KiB | 80 | **~6,200** (OK at 6,000; crashes at 6,500) |

### Conclusion

**The plan's stop condition ("practical bound under 32") is not remotely
approached.** Even a 512 KiB stack — far smaller than anything the current
transport uses — carries six thousand middleware. On the ordinary 8 MiB main
stack the limit is around a hundred thousand.

A realistic application has fewer than twenty. Recursion is not a constraint
here. The failure mode when the bound *is* exceeded is a segfault, not a
diagnostic — which is worth one sentence in the WP15 documentation, but not a
design change.

---

# P11 — binary cost with the machinery present and zero middleware registered

The application is `examples/01-hello-world/main.odin`, **unmodified**, built
twice against two collection roots that differ only in whether `web/` contains
the chain machinery. The middleware-capable root used here (`root_mwc`) has the
P9 negative control stripped out, because that code would not exist in
production.

### Command

```
env -u ODIN_ROOT /tmp/druse-toolchain/odin build /tmp/wp12-probe/p11 \
  -collection:druse=/tmp/wp12-probe/root_base -out:/tmp/wp12-probe/out/p11-base
env -u ODIN_ROOT /tmp/druse-toolchain/odin build /tmp/wp12-probe/p11 \
  -collection:druse=/tmp/wp12-probe/root_mwc  -out:/tmp/wp12-probe/out/p11-mwc
stat -c '%s  %n' out/p11-base out/p11-mwc
size out/p11-base out/p11-mwc
```

### Output

```
=== default flags ===
868088  out/p11-base
869920  out/p11-mwc

=== -o:speed ===
606216  out/p11s-base
607264  out/p11s-mwc

   text	   data	    bss	    dec	    hex	filename
 617546	 162781	  10488	 790815	  c111f	out/p11-base
 621246	 164168	  10488	 795902	  c24fe	out/p11-mwc
 415466	 159069	  10408	 584943	  8ecef	out/p11s-base
 417990	 160405	  10408	 588803	  8fc03	out/p11s-mwc
```

| build | baseline | with machinery, zero middleware | delta |
|---|---|---|---|
| default | 868,088 B | 869,920 B | **+1,832 B (+0.21 %)** |
| `-o:speed` | 606,216 B | 607,264 B | **+1,048 B (+0.17 %)** |

### `nm` symbol delta (new symbols only)

```
__$equal$$struct{method:web::Method,pattern:string,handler:web::Handler,has_param:bool,valid:bool,chain_start:int,chain_len:int}
runtime::append_elem:proc(array:^[dynamic]web::Handler, …)
runtime::delete_dynamic_array:proc(array:[dynamic]web::Handler, …)
runtime::make_dynamic_array:proc(T:$[dynamic]web::Handler, …)
web::[middleware_proto.odin]::chain_flatten
web::[middleware_proto.odin]::chain_run
web::[middleware_proto.odin]::miss_chain_ensure
web::[middleware_proto.odin]::miss_terminal
web::[middleware_proto.odin]::mw_destroy
web::next
```

**`use` is absent from the binary.** An application that never calls it does not
link it — the same dead-code elimination G-11 relies on.

### Conclusion

**+1,832 bytes (default) / +1,048 bytes (`-o:speed`) for an application that
registers no middleware at all.** Three of the ten new symbols are the generic
`[dynamic]Handler` instantiations, which exist because `route_register` now
flattens unconditionally; a lazier design that skips the pool entirely when the
App has no middleware would remove most of this, at the cost of a branch in
dispatch.

This is a G-11 human-review item, as the plan requires. It is small, but it is
not zero, and the owner should decide whether ~1.8 KiB on every Druse binary
is acceptable rent for a feature many applications will not use.

---

# P12 — variadic route-level middleware

### Source compatibility

```
for ex in 01-hello-world 02-json-api 03-route-params; do
  env -u ODIN_ROOT /tmp/druse-toolchain/odin build \
    /tmp/druse-wp12/examples/$ex \
    -collection:druse=/tmp/wp12-probe/root_mwc -out:/tmp/wp12-probe/out/ex-$ex
done
```

```
OK: examples/01-hello-world compiled unchanged
OK: examples/02-json-api compiled unchanged
OK: examples/03-route-params compiled unchanged
```

Every existing three-argument call site still compiles, untouched.

### Exact `odin doc` signature lines

Baseline (`root_base`):

```
		delete :: proc(a: ^App, pattern: string, handler: Handler) {...}
		get :: proc(a: ^App, pattern: string, handler: Handler) {...}
		patch :: proc(a: ^App, pattern: string, handler: Handler) {...}
		post :: proc(a: ^App, pattern: string, handler: Handler) {...}
		put :: proc(a: ^App, pattern: string, handler: Handler) {...}
```

With the machinery (`root_mwc`):

```
		delete :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler) {...}
		get :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler) {...}
		next :: proc(ctx: ^Context) {...}
		patch :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler) {...}
		post :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler) {...}
		put :: proc(a: ^App, pattern: string, handler: Handler, middleware: ..Handler) {...}
		use :: proc(a: ^App, middleware: Handler) {...}
```

That is the complete documented delta: five signatures mutate, two names are
added.

### Allocation at registration

```
P12 1 route, 0 globals, 0 route-mw : allocs=3 bytes=514 pool_len=1
P12 1 route, 0 globals, 1 route-mw : allocs=3 bytes=514 pool_len=2
P12 1 route, 0 globals, 2 route-mw : allocs=3 bytes=514 pool_len=3
P12 1 route, 3 globals, 0 route-mw : allocs=4 bytes=578 pool_len=4
P12 20 routes, 5 globals           : allocs=29 bytes=5224 pool_len=120
```

### Conclusion

**It compiles, it is source-compatible with every Phase-1 call site, and the
variadic itself costs no heap allocation.** Passing two route-level middleware
adds exactly two pool slots and **zero** additional allocations (3 → 3): Odin
passes the variadic as a stack slice.

Registration does allocate, as the spec permits: the pool array grows
amortised. Note the flattening is **quadratic in globals × routes** — 20 routes
with 5 globals produce a 120-entry pool (20 × (5 + 1)). At realistic sizes this
is nothing (120 pointers = 960 bytes); at 1,000 routes × 10 globals it would be
11,000 pointers = 88 KiB, still nothing. It is worth stating in the WP15
documentation so nobody is surprised.

---

# P13 — the miss chain: does a global middleware observe a 404?

### Naive flattening: no

Chains attach to routes. A miss has no route. Under the naive design the plan
describes, `dispatch` reaches the 404/405 tail without ever entering a chain, so
`logger` never logs a 404 and `request_id` never stamps one.

### With a second flattened miss chain: yes

The prototype builds a second chain — the globals, terminating in
`miss_terminal`, which is the existing automatic 404/405 logic expressed as a
`Handler`.

```
P13 miss chain, 404           : A>B><B<A   status=Not_Found
P13 miss chain, 405           : A>B><B<A   status=Method_Not_Allowed
```

The empty gap between `B>` and `<B` is the terminal step, which produces the
response and marks nothing. Both middleware observe the miss on the way in and
on the way out, and the response is the unchanged standard envelope
(`ERROR_BODY_NOT_FOUND_ROUTE`, asserted byte-for-byte, and the 405 still carries
its `Allow` header).

### What it costs

1. **Two App fields** (`miss_start`, `miss_len`) and **one Context field**
   (`miss_app`). The last one exists purely because a `Handler` receives only
   the Context, and the automatic 404/405 needs the App to build `Allow`. That
   is a real wart: it re-introduces, on the Context, precisely the App back-
   pointer `Context_Internal` was documented as deliberately not having.
2. **Lazy construction with invalidation.** A miss belongs to no registration,
   so the chain cannot be built at registration time; it is built at the first
   miss and invalidated by every later `use`. Rebuilding **appends** to the pool
   without reclaiming the old chain:

   ```
   D-12.4 pool length after each (use + miss) cycle: [3, 6, 10, 15]
   ```

   Bounded by the number of `use` calls, which is bounded by the program text,
   so it is not a leak — but it is untidy and needs a sentence of explanation.
3. **`bare()` is inconsistent.** `dispatch` returns before the miss chain when
   `default_responses` is false, so under `bare()` a global middleware observes
   nothing on a miss:

   ```
   D-12.4 bare() miss: order="" status=Internal_Server_Error
   ```

   (The 500 is `driver_finalize` doing its job; that is the documented `bare()`
   behaviour.) Either `bare()` gains a miss chain whose terminal step does
   nothing, or the documentation must state that `bare()` misses skip
   middleware.

### Conclusion

**It works, and it costs roughly thirty lines plus one design blemish.** The
blemish (`miss_app` on the Context) is avoidable if WP15 is willing to make the
miss terminal a special-cased step the dispatcher recognises rather than an
ordinary `Handler`, at the cost of a branch in `next`.

---

# D-12.1 — distinct `Middleware` type, or reuse `Handler`?

Four compile probes, run with `odin check … -file`. A negative control was run
first to prove the checks are real.

### Negative control

```
env -u ODIN_ROOT odin check /tmp/wp12-probe/d121/z_control.odin -file \
  -collection:druse=/tmp/wp12-probe/root_mwc -no-entry-point
```

```
/tmp/wp12-probe/d121/z_control.odin(8:21) Error: Cannot convert untyped value '42'
to 'Middleware' from 'untyped integer'
(exit 1)
```

The check is real and reports type errors.

### Probe A — `use_distinct(&app, my_mw)` with **no** cast, where
`Middleware :: distinct proc(ctx: ^web.Context)`

```
(exit 0)
```

**It compiles.** No cast is needed at the call site.

### Probe E — a value already typed `web.Handler`, passed where `Middleware` is
expected

```
h: web.Handler = my_mw
use_distinct(&app, h)
```

```
(exit 0)
```

**It compiles.** A `Handler` converts implicitly to the distinct `Middleware`.

### Probe G — the reverse: a `Middleware` passed to `web.get` as the handler

```
(exit 0)
```

**It compiles too.**

### Control — is Odin's `distinct` rule strict at all on this toolchain?

```
My_Int :: distinct int
take :: proc(x: My_Int) {}
i: int = 1
take(i)
```

```
Error: Cannot assign value 'i' of type 'int' to 'My_Int' in a procedure argument
	Suggestion: The expression may be directly casted to type My_Int
(exit 1)
```

**Strict for `int`, not strict for procedure types.**

### Conclusion

On `dev-2026-07-nightly:819fdc7`, a distinct procedure type converts implicitly
in **both** directions. It therefore imposes **no** call-site cost — and
provides **no** protection either. The counter-argument the plan wanted recorded
("`use(&app, list_users)` would then compile") is real, but a distinct type does
not prevent it: probe E shows a `Handler` still converts.

**RECOMMENDATION: reuse `Handler`. Add no `Middleware` type.**

**STRONGEST ARGUMENT AGAINST:** the type name is documentation, and losing it
costs readability at every declaration site — a reader of `use(&app, audit)`
cannot tell from types alone whether `audit` is expected to call `next`. And the
implicit-conversion behaviour above is a property of *this compiler build*, not
a language guarantee; a future Odin that tightens `distinct` for procedure types
would suddenly make a distinct `Middleware` both safe and cheap, and reversing
the decision then would be a breaking change to a frozen signature. Reusing
`Handler` forecloses that.

---

# D-12.2 — chain storage

Settled by P8.

**RECOMMENDATION: index pairs (`chain_start, chain_len: int`) into one
App-owned `[dynamic]Handler` pool.** Never a stored `[]Handler`.

**STRONGEST ARGUMENT AGAINST:** indices are a hand-rolled pointer that the
compiler does not check. Nothing stops a future edit from clearing or
compacting the pool and leaving every route pointing at the wrong offsets — a
class of bug that is silent, whereas a dangling slice at least corrupts loudly
under a poisoning allocator. A fixed-capacity pool sized once at first dispatch,
or an arena that never reallocates, would let slices be safe *and* checked. The
answer is that neither can be sized before registration finishes, so indices win
— but the invariant "the pool is append-only and never compacted" must be
written down and enforced, not assumed.

---

# D-12.3 — the post-`next` promise: B1 (specified and tested) or B3 (documented
as forbidden, untested)

The mechanism works (P4) and the danger it creates is already contained (P5).

**RECOMMENDATION: B1 — specify it and test it.**

The reasoning: post-`next` code is not an accident of the implementation that
could be left undefined. It is the direct consequence of `next` being a call
(P4), it cannot be prevented without removing `web.next`, and it is *already*
observable to any application that writes a statement after `next`. Documenting
it as forbidden while it demonstrably works is the "observable but undocumented"
state the Phase-2 plan itself calls the worst of both. And the one genuinely
dangerous thing an application can do there — respond a second time — is already
rejected, byte-identically, by the shipped guard (P5, both commit paths), so B1
promises nothing new about failure behaviour.

**STRONGEST ARGUMENT AGAINST:** B1 freezes an ordering guarantee across a future
implementation change WP12 has not prototyped. If Phase 3 or 4 ever wants an
iterative dispatcher, an async transport, or a chain that resumes on a different
thread, "post-`next` code runs, in exact reverse order" becomes a promise the
new execution model must reproduce — and reproducing exact reverse order without
a live stack frame per middleware is expensive. B3 keeps that door open at the
price of an honesty gap that lasts only until someone tries it.

---

# D-12.4 — do app-level middleware run on a 404 or 405?

**RECOMMENDATION: yes, via the flattened miss chain (P13) — and fix the `bare()`
inconsistency at the same time.**

The reasoning: the plan itself calls this a first-class semantic decision, and
the alternative is a framework where `logger` silently does not log the majority
of the traffic a scanner sends, and `request_id` cannot correlate a 404. It also
matters for security: once WP24 adds rate limiting or audit middleware, "misses
are invisible" is exactly the hole an attacker probes.

**STRONGEST ARGUMENT AGAINST:** it is the single most expensive decision here in
complexity per unit of value. It needs a second chain, lazy construction, an
invalidation rule, a pool that grows on every `use`-after-miss, an App
back-pointer on the Context that `context.odin` explicitly documents as
deliberately absent, and a `bare()` special case. Every one of those is a place
for a future bug. A framework that instead documented "middleware runs on
matched routes only; register a catch-all route if you need to see misses" would
be smaller, would need none of that machinery, and would be defensible.

---

# D-12.5 — does `use` apply retroactively?

Measured:

```
D-12.5 route registered BEFORE use(): H
D-12.5 route registered AFTER  use(): A>H<A
```

### The deliberately mis-ordered program

```odin
web.get(&app, "/admin/users", admin_users)   // looks protected. IS NOT.
web.use(&app, require_auth)
web.get(&app, "/admin/keys", admin_keys)     // is protected.
```

```
env -u ODIN_ROOT /tmp/druse-toolchain/odin run /tmp/wp12-probe/d125 \
  -collection:druse=/tmp/wp12-probe/root_mwc -out:/tmp/wp12-probe/out/d125
```

```
  [admin_users ran — SECRETS SERVED]
GET /admin/users -> OK
  [require_auth ran]
GET /admin/keys  -> Unauthorized
```

### How confusing is it?

**Very.** The program reads top to bottom as "these are my admin routes and this
is my auth middleware". Nothing about it looks wrong. Both routes are in the
same block, under the same prefix, with the same intent. One of them serves
secrets to an unauthenticated caller and the other does not, and the only signal
is line order. There is no error, no warning, and no runtime symptom — the
insecure route returns a perfectly healthy `200 OK`.

This is not a hypothetical readability complaint; it is an authentication
bypass produced by moving one line.

**RECOMMENDATION: no retroaction — `use` affects only registrations that follow
it — AND WP15 must not ship it as documentation alone.** At minimum,
`web.use` should refuse (through the existing typed report path) to run after
the first registration, or `serve` should report at startup when routes were
registered before any `use`. A rule enforced only by a paragraph is not enforced.

**STRONGEST ARGUMENT AGAINST:** retroactive `use` — a second pass that rebuilds
every chain when registration finishes — removes the footgun entirely and is not
hard: chains are already flattened from a pool, so rebuilding is one loop at
first dispatch. The cost is that "registration is done" becomes a real state the
App has to have, `use`-after-`serve` becomes an error case, and the ordering of
a middleware relative to route-level middleware becomes less obvious. That is a
real price, but "less obvious ordering" is a smaller harm than the transcript
above.

---

# D-12.6 — `next` called twice

Measured (P6): with a monotonic per-request cursor, the second call is a silent
no-op and the handler runs exactly once.

**RECOMMENDATION: keep the monotonic cursor, document the second call as a
no-op, and do not report it.**

The reasoning: the plan's premise — that a double `next` re-runs the remainder
and gets caught by the commit guard — is an artefact of a per-frame cursor that
this prototype does not use. With one index per request there is nothing to
re-enter. A no-op is the safest available behaviour: idempotent, allocation-free,
and impossible to turn into a duplicated side effect.

**STRONGEST ARGUMENT AGAINST:** silence hides a bug. A middleware that calls
`next` twice is always wrong — usually a missing `return` on an early-exit
branch — and the framework has a typed report path precisely so that "obviously
wrong" is not silent. The counter to the counter is that the check costs a
comparison the framework would have to run per `next` call on every request,
forever, to catch a mistake the compiler cannot see and that produces no
observable damage. If WP15 wants it, the honest place is a debug-build-only
assertion, not a runtime report.

---

# D-12.7 — variadic route-level middleware

Settled by P12: it compiles, all three existing examples build unchanged, the
`odin doc` delta is five mutated signatures plus two new names, and the variadic
adds zero heap allocations.

**RECOMMENDATION: adopt `get(a, pattern, handler, middleware: ..Handler)` on all
five registration procedures.**

**STRONGEST ARGUMENT AGAINST:** it mutates five frozen signatures for a
convenience, and a variadic tail is the least readable way to express "this
route has an auth guard" — `get(&app, "/x", h, auth, audit)` gives the reader
five positional arguments with no cue about which are middleware or what order
they run in. A route-group API (`group(&app, "/admin", auth)`) would express the
same intent better and would leave the five signatures alone. Route groups are
explicitly out of WP12's scope, so this recommendation is being made without
having seen the alternative it would compete with.

---

# Decisions table

| # | Question | Recommendation | Strongest argument against |
|---|---|---|---|
| D-12.1 | distinct `Middleware` type? | **No — reuse `Handler`.** A distinct proc type converts implicitly both ways on this toolchain: no call-site cost, no safety either. | Loses the documentation value of the name, and bets that Odin's lax proc-type `distinct` rule never tightens. |
| D-12.2 | chain storage | **Index pairs into one App-owned pool.** Slice storage reproduces a use-after-free (P8), and does so *silently* on the ordinary heap (P8b). | Indices are unchecked by the compiler; the "append-only, never compacted" invariant must be enforced, not assumed. |
| D-12.3 | post-`next` promise | **B1 — specify and test it.** It works (P4) and the dangerous case is already guarded (P5). | Freezes exact reverse-order unwinding against any future non-recursive or async dispatcher. |
| D-12.4 | middleware on 404/405 | **Yes, via the miss chain.** Otherwise logging and audit middleware miss most hostile traffic. | The most complexity per unit of value here: second chain, lazy rebuild, pool growth, an App pointer on the Context, and a `bare()` special case. |
| D-12.5 | `use` retroactive? | **No retroaction — and enforce it, not just document it.** The mis-ordered program is an auth bypass with no symptom. | A second flattening pass would remove the footgun entirely, at the price of a "registration finished" state. |
| D-12.6 | `next` twice | **Silent no-op; document it; do not report.** The monotonic cursor makes it harmless by construction. | Silence hides an always-wrong caller; a debug-only assertion would be the honest compromise. |
| D-12.7 | variadic route middleware | **Adopt it.** Compiles, source-compatible, zero heap cost. | Mutates five frozen signatures for something route groups might express better — and route groups were out of scope here. |

**ADR-005 recommendation to the owner: ACCEPT the mechanism.** Every acceptance
criterion the plan set was met — zero dispatch allocations, a practical depth
bound four orders of magnitude above the realistic need, no new handler shape,
no new response writer, and no change required to the single-commit guard or the
driver finalization. The two items that deserve the owner's explicit attention
before WP15 are the ~1.8 KiB binary rent for applications with no middleware
(P11) and the D-12.5 ordering footgun, which is a security property and should
not ship as prose alone.

---

# What I could not determine

1. **Whether `use` should be blocked after the first registration** (the D-12.5
   enforcement). The prototype demonstrates the hazard but does not implement a
   guard, and whether the framework's typed report path is the right instrument
   — or whether it should be a compile-time impossibility via a different API
   shape — is a WP15 design question this work package did not explore.

2. **The real cost of the `-o:speed` P11 delta on a realistic application.** The
   measurement uses `examples/01-hello-world`, which is the smallest possible
   program. A large application might amortise the machinery to nothing, or the
   quadratic pool might matter; neither was measured.

3. **Whether a lazier design removes the P11 cost entirely.** Skipping the pool
   when the App has no middleware would remove the `[dynamic]Handler` generic
   instantiations, which are three of the ten added symbols. That variant was
   not built.

4. **Behaviour under the real socket transport.** Every dispatch probe drives
   `driver_run`/`driver_cleanup` or `test_request`, which is the same core
   pipeline `serve` uses (WP9's whole point), but nothing was run over a real
   socket. The stack measurements in P10 were taken on the process's main stack;
   if a future transport dispatches on a thread with a smaller stack, the P10
   512 KiB row is the relevant one.

5. **Interaction with panic/recovery (WP13).** A recursive chain has N live
   frames when a fault occurs. Whether any recovery mechanism WP13 recommends
   can unwind them, and what a partially-unwound chain means for post-`next`
   code, was not investigated and is a genuine dependency between the two
   prototypes.

6. **Whether `next` should be callable from a route handler.** Nothing prevents
   a handler — which is just the last chain step — from calling `next`. It would
   find the chain exhausted and return (same mechanism as P6), so it is
   harmless, but it was not tested and no policy is proposed.

7. **Thread safety.** The cursor lives on the Context, which is per-request, so
   concurrent requests do not share it. But the App-owned pool is read during
   dispatch and written during registration, and nothing enforces that
   registration has finished before serving begins. The current transport makes
   this moot; a future one may not.

---

# Independent verification (integrator)

Three of the probe results were re-derived from scratch, in a separate
prototype, by the integrating agent rather than the one that ran the probes.
Two confirmed cleanly. One corrected the *reasoning* behind an otherwise
correct measurement.

## Confirmed — P2/P3/P4 ordering, and P9 zero allocations

An independently written cursor reproduced the same observable behaviour:

```
order (3 middleware): 1>2>3>H<3<2<1
short-circuit:        1>STOP<1
cursor allocations:   0
```

Post-`next` code runs, unwind is exact reverse, short-circuit is total, and the
cursor itself allocates nothing at dispatch.

## Confirmed — D-12.1, and the compiler fact behind it

`Middleware :: distinct proc(ctx: ^Context)` really does convert implicitly in
**both** directions, while `distinct int` does not:

```
takes_middleware(var_h)   // Handler    -> Middleware : compiles
takes_handler(var_m)      // Middleware -> Handler    : compiles

takes_int(di)             // Dint -> int : Error: Cannot assign value 'di' of
                          //               type 'Dint' to 'int'
```

So a distinct middleware type costs nothing at call sites and buys nothing in
safety. Reusing `Handler` is the right call, for the reason given.

## Corrected — P6 is a property of the DESIGN, not of "a monotonic cursor"

P6 measured that a second `next` is a silent no-op, and that measurement is
correct for the prototype as built. The stated explanation — that it "falls out
of the cursor being monotonic" — is **not sufficient**, and a counter-example
shows why.

An independent cursor that is *also* monotonic and *also* per-request, but which
calls the terminal handler on fall-through rather than treating it as the last
step inside the bound, runs the handler **twice**:

```
next() called twice -> T>B>H<BH<T
handler ran 2 time(s)
```

The difference is not the cursor. It is **whether the terminal handler sits
inside the index bound or outside it**. Written one way the second `next` is
harmless; written the other way it re-runs the route handler, with every side
effect that implies — the response is still rejected by the commit guard, but a
database write is not.

This matters for WP15 and WP17: the no-op behaviour is a **design constraint to
be specified and tested**, not a property that comes for free. The
recommendation stands (keep the monotonic cursor, document the second call as a
no-op), but it must be accompanied by a test that fails if a future refactor
moves the terminal handler outside the bound.
