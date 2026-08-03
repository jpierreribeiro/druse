# R2-WP06 — assurance, first pass

**Decision: R2-WP06 remains OPEN. Four items closed, four still owed. The gate
stays at R1.**

This package covers what was finished in one pass and, more usefully, what the
measurements say about a criterion R2-WP08 has already committed to.

## Closed

### 1. F-005 — an oversized header block answered, instead of vanishing

The finding was reported on 2026-07-28 and **had never been fixed**.

A header section over `limit_headers` answered `431` when a complete line
exhausted the budget, and **closed the connection with no response and no log
line** when a single line was larger than the remaining budget. Measured at
`limit_headers = 8000`:

| Header block | Response |
|---|---|
| 7,932 bytes | `200` |
| 8,032 bytes | `431` |
| **8,532 bytes** | **silence** — no response, no log |

Two requests over the same limit received two different protocol outcomes,
decided by how the bytes fell across lines. The client cannot distinguish the
silent close from a network fault, and the operator gets nothing.

Fixed as vendor patch 44 (`OFFER UPSTREAM`: `.Too_Long` while scanning headers
has exactly one meaning, and RFC 9110 §15.5.18 defines 431 for it).

**The corpus needed a new outcome, and that is the part worth recording.** WP9's
`Rejected` permits a bare close (D6) — for most malformed framing there is
nothing truthful to answer. For F-005 that permission *is the defect*, so a case
written against `Rejected` would have been **green on the vulnerable server**.
`Rejected_With_Status` makes the status mandatory.

Two cases, not one: the single oversized line, and the many-complete-lines shape
that already answered 431 before the fix. Only the first would leave nothing to
catch a repair that fixed one path by breaking the other.
`raw/wp9-mutations.out`: nine guards, each detected.

### 2. SECURITY.md said "five" while the ledger held forty-five

The vendored-dependency section had not been updated since Phase 6. A number a
human maintains is a number that was true once, and on a security page it is
worse than absent: a reporter reads it as the size of the divergence they are
trusting.

It now states 45, carries a `security-patch-count` marker, and
`build/check_vendor_policy.sh` checks **both** the marker and the prose against
the ledger. Both mutants verified red, each for its own reason.

The page also gained a **"What has NOT been done"** section — no third-party
audit, no fuzzing campaign against the current candidate, no CVE process, and
the supported profile as the boundary of the claim. A security policy that lists
only successes reads as a completeness claim.

### 3. Rebuild from a clean clone — and the answer is *not* byte-identical

`ops/release/verify-rebuild.sh` clones the commit twice, builds with the pinned
toolchain, and compares. Measured (`raw/rebuild-two-clean-clones.txt`):

```
build_a_sha256=396138bbfa137a316085ff3e7e46b007e715e68f2a3c134959f751eced4eb83f
build_b_sha256=96d61da8e3f8818d509cb6cf47181f52fd1bca0050ffefa9c1760ff9de4ccb54
build_a_bytes=918640
build_b_bytes=918640
byte_identical=no
size_delta_bytes=0
```

Same commit, same compiler, same flags, same machine: **different bytes,
identical size.** The delta is content, not structure.

The script **records this rather than failing on it**, deliberately. R2-WP06's
own text asks to "comparar hashes de dois builds no mesmo ambiente; se não
reprodutíveis, registrar fontes de nondeterminismo" — this is that clause being
honoured. A gate demanding byte identity would be red forever for a reason
nobody can fix inside this project.

### 4. Two defects in the ledger itself, found by writing the BOM

The bill of materials was supposed to be bookkeeping. It disagreed with the gate
— 45 against 44 — and the disagreement was real on both sides.

- **ID 42 was used twice.** The T6/M7 deletion and the acceptor-saturation
  bridge shared it. The source marker `DRUSE PATCH 42` in
  `vendor/odin-http/server.odin` and the tests that cite it point at the second,
  so the first **had no identity anyone could reach**. R3-WP02 lists "eliminar
  numeração duplicada e definir ID estável por patch" as work; it is done, and
  gated. The deletion is now 45, with a ledger note: the earlier evidence
  package cites the old number and is left untouched, because evidence is
  immutable and a note is the honest reconciliation.
- **`DELETED` was not a disposition the gate could see.** Its pattern matched
  only `OFFER UPSTREAM`, `CARRY` and `APPEARS FIXED UPSTREAM`, so the entry
  resolved by removing 1,295 lines was invisible to the count — which is exactly
  why the duplicate ID survived: 45 rows reading as 44. A divergence resolved by
  deletion is as much a disposition as one resolved by a patch, and a gate that
  cannot see it cannot notice it being edited or dropped.

Both are now checked: duplicate IDs fail, and the row count must equal the ID
count. The BOM counts the way the gate counts rather than producing a second
number — a second source of truth is how this pair survived in the first place.

## What this measurement does to R2-WP08

**R2-WP08's exit criteria include: *"artefato implantado é byte-idêntico ao
aprovado"*.**

That criterion is now **measured as unsatisfiable** with the pinned toolchain.
It is not a matter of effort or discipline. Two builds of one commit differ.

This is recorded here, and not resolved, because changing a gate's exit criteria
is the gate owner's decision and not this work package's. The options are
visible: pin the artefact itself (build once, hash it, deploy that file) rather
than requiring the build to be reproducible; or adopt a reproducible toolchain;
or restate the criterion as provenance rather than identity. **R2-WP08 cannot be
closed as written**, and finding that out now is cheaper than finding it out at
the board.

## Still owed by R2-WP06

Named, because "first pass" otherwise reads as "done":

- **smuggling/framing through the real proxy** — the corpus runs against the
  server directly; a parser divergence between Caddy and Druse is a different
  test and has not been run;
- **fuzz / sanitised corpus against the candidate** — the corpus above is
  hand-written cases, not generated ones. A fresh scan is what R2-WP06 asks for
  and the reconciliation explicitly did not re-scan the product after several
  phases;
- **review of administrative, upload, static and trust-proxy endpoints**;
- **indirect pins F8, F12 and F-007 against the R2 threat model**;
- **~~a versioned BOM with hashes~~** — done: `ops/release/generate-bom.sh`,
  `druse_bom 1`. Deliberately **not** called SPDX or CycloneDX: no generator
  understands Odin packages, and emitting their schema name would make a
  consumer's scanner report a clean bill for a project it never examined.

## What this does NOT establish

- **No third-party review.** Everything here is this project auditing itself.
- **F-005 is fixed, not proven absent elsewhere.** The same class — a guard that
  runs only on the well-formed path — was not swept for across the transport.
- **The rebuild result is one machine, one run.** It shows non-determinism
  exists; it does not characterise its source. Nothing here identifies *what*
  differs between the two binaries.
- **Nothing here is a soak, a capacity envelope, or a canary.** R2-WP04, WP05
  and WP07 are untouched by this package.
