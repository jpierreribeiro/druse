# C-08 — The httprouter comparative study

**Status: STEP 1 DONE, STEP 2 DEFERRED WITH A CRITERION (Closure, WP C-08).**
Non-blocking by construction: **zero public API change**, and it is not a
readiness gate. It sits in this phase because it is a "review what already
exists" exercise of the same spirit as C-01 and C-02.

---

## 1. The value ranking, and why the corpus was the thing to take

`httprouter` is **reference, not dependency**. Druse already has a private,
segment-oriented radix router: the WP29 benchmark fell from ~883 µs to ~1.5 µs
at 5,000 routes and is near-constant from 5 to 5,000. So the question was never
"should we adopt it" but "what is worth learning from it", and the honest
ranking is:

| What | Value | Taken? |
|---|---|---|
| The **test corpus** | **very high** | ✅ step 1, `tests/c08-router-corpus` |
| Implementation reference | high | read, not copied |
| A new benchmark competitor | high | ⏸ step 2, deferred with a criterion |
| Copying the router | low | no |
| Copying its HTTP semantics | **low / dangerous** | **refused, and pinned as a negative corpus** |

---

## 2. Step 1 — the corpus, and why it is a NEGATIVE corpus

The obvious use of another router's tests is to check that you agree with it.
That would be exactly wrong here. Druse differs from httprouter in three
places **deliberately**, each with a security or predictability argument, so the
corpus runs to prove that **every difference is intentional and pinned**. A
regression *toward* httprouter's behaviour must fail the build.

`tests/c08-router-corpus/external_corpus_test.odin` — ten cases, all green.

**Where the two agree, and agreement is evidence** (a router that failed these
would be broken on its own terms): overlapping static prefixes
(`/`, `/c`, `/co`, `/con`, `/contact`, `/cona`, `/cmd`, `/single`) each
resolving to themselves while unregistered prefixes 404 rather than
nearest-matching; deep paths; multi-parameter paths; a parameter never matching
across a separator; Unicode routes resolving by bytes.

**The three deliberate differences, now pinned:**

1. **Precedence with backtracking.** httprouter *forbids* a static and a
   parameter route at the same position. Druse accepts both — static wins,
   **with controlled backtracking**: `/users/me/settings` and
   `/users/:id/profile` coexist, and `/users/me/profile` must abandon the static
   branch and succeed on the parameter branch. **This is the test a literal port
   of httprouter's tree would fail**, which is exactly the alarm step 2 needs.
2. **No automatic path correction.** httprouter answers 301 for a missing or
   extra trailing slash, and offers case-insensitive lookup and `CleanPath`.
   Druse answers 404/400 and never rewrites: `/users` ≠ `/users/`, `/Users` ≠
   `/users`, and `..`, `.`, `//`, `%2e%2e`, `%2F` are refused *before* routing.
   The argument is not taste — **a normaliser that gets it wrong produces a path
   the check already approved**, while a rejection cannot.
3. **No catch-all.** httprouter has `*filepath`. Druse's parameter is one
   segment; multi-segment serving is a `mount`, which owns its prefix entirely
   and applies the static-file security rules. `/files/:name` must 404 for
   `/files/a/b/c` rather than capture it.

**Where Druse does more, recorded so the comparison is honest in both
directions:** automatic HEAD and OPTIONS, 405 with a frozen-order `Allow`,
alloc-free per-request params, and fail-closed conflict diagnostics (a poisoned
App, not a panic) for `/users/:id` beside `/users/:uid`.

### One finding about the method itself

Two of this file's assertions were **wrong when first written**, and both were
wrong in the same direction: they had imported the *other* system's
expectations. The `Allow` case asserted an alphabetical list including `HEAD`
and `OPTIONS`; Druse's frozen order is `GET, POST, PUT, PATCH, DELETE`
filtered to the registered methods. The conflict case used
`/users/:id` + `/users/:uid/posts`, which are different positions and correctly
*not* a conflict.

That is the characteristic risk of a comparative study, and it is worth stating
rather than quietly fixing: **reading another system's tests makes its
assumptions feel like defaults.** The corpus is only safe as a negative corpus
because each case is written against Druse's own documented rule, not against
a memory of how the other router behaves. The note stays in the test file.

---

## 3. Step 2 — the `radix_compact` experiment, deferred with a criterion

The one cost Druse's router has never measured is **registration time and
memory**: a node plus a map per distinct segment. An httprouter-inspired
compressed-radix competitor (`radix_compact` beside the current `radix_idx`)
would measure it — registration per route, memory at 50 / 500 / 5,000 routes,
node and map counts, teardown cost, lookup p50/p95, `Allow` build, and
deep/shared-prefix behaviour — in Druse's own harness, under the same gate.

**Deferred, not dropped, and the criterion is explicit:** it is kept **only on
material gain**, and it must pass §2's precedence-with-backtracking test
unchanged. That test is the guard: a compact implementation that "wins" by
adopting httprouter's tree has not won, it has changed the semantics.

**Why not now.** It is an optimisation with no readiness consequence, and this
phase's budget belongs to the perimeters that do have one. Registration cost is
paid once at boot; the lookup cost, which is paid per request, is already
measured and already near-constant to 5,000 routes.

---

## 4. Licence

`httprouter` is **BSD 3-Clause**. No httprouter *code* is copied — what is
adapted is the shape of its test cases. The copyright notice, the three
conditions and the disclaimer are reproduced in full at the head of
`tests/c08-router-corpus/external_corpus_test.odin`, and
`build/check_c08_controls.sh` fails if that notice is removed.
