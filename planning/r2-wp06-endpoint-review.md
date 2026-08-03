# R2-WP06 — endpoint review: administrative, upload, static, trusted proxies

**Reviewed 2026-08-03 against the R2 threat model**: the candidate serves
production workloads inside `docs/supported-profile.md`, behind the pinned
reviewed proxy, with hostile clients on the far side of that proxy and a
non-hostile but fallible operator configuring it.

R2-WP06 asks to "revisar todos os endpoints administrativos, upload, static e
trust proxies". One finding, two confirmations, and one thing that is a property
of the profile rather than of the code.

---

## 1. Trusted proxies — TRUST-001: a prefix cannot be anchored, and the API's own
   safety argument is wrong in one direction

**Severity: LOW-MEDIUM. Not a framework defect; a documented property that is
false, and whose examples exhibit the failure.**

`web.trust_proxies` takes address **prefixes** matched with
`strings.has_prefix` against the rendered peer address
(`web/client_address.odin:207`). The design note argues for prefixes over CIDR
and rests on this asymmetry:

> *"A wrong CIDR mask can trust a network you did not mean to trust; a wrong
> prefix can only fail to trust one you did."*

**The second half is false.** `render_peer` produces a bare address with no port
and no terminator (`web/internal/transport/odin_http_adapter.odin:79`), so every
entry is an *unanchored* prefix and there is no way to express "exactly this
address". Measured:

| entry | also trusts |
|---|---|
| `10.0.0.1` | `10.0.0.10`–`10.0.0.19`, `10.0.0.100`–`10.0.0.199` — 110 extra hosts |
| `192.168.1` | all of `192.168.10.x`, `192.168.11.x`, … |
| `::1` | any IPv6 address rendering as `::1…`, e.g. `::1a2b` |

The API's own doc comment offers `"127.0.0.1"` and `"::1"` as example entries.
`127.0.0.1` over-matching `127.0.0.10` is harmless because the extra addresses
are loopback; `::1` over-matching `::1a2b` is not obviously harmless, and neither
is the natural act of naming one proxy by its address.

**Why this matters under the R2 threat model.** Trusting an address means
believing its `X-Forwarded-For`, which decides `client_ip` — the value an
application uses for rate limiting, audit and abuse decisions. Widening the
trusted set by 110 hosts is not exploitable by the far-side client on its own,
but it converts "one compromised host on the management network" into "spoof any
client IP", and the operator who wrote a single address has no way to know.

**Available mitigation today, no code change:** end every entry at a component
boundary — `"10.0.0.1."` is not a legal address so it cannot be used; the working
forms are network prefixes with the separator, `"10."`, `"192.168."`,
`"10.0.0."`. Naming a *single* proxy exactly is not expressible.

**Not fixed here.** A boundary-anchored match or an exact-address form is a
change to the meaning of a public API, and readiness rule G5 is explicit that a
plan may name a public need and may not invent a signature. The need is named:
*an entry that means one address and only that address*. What can be done without
a decision is to correct the doc comment so it stops asserting an asymmetry the
matcher does not have, and to stop offering `"127.0.0.1"`/`"::1"` as examples of
a form that is safe only by accident.

---

## 2. Static — confirmed, and the design is the reason

`web/static.odin` refuses rather than resolves, which is the property that
survives a reviewer:

- **`..` anywhere is rejected**, textually, not collapsed — so a component that
  would pass a textual check and be decoded by something later has nowhere to
  go (`:25`, `:323`);
- **dotfiles are refused** (`:334`);
- **`lstat`, not `stat`** (`:408`): a symlink reports `.Symlink` and is rejected
  whatever it points at, with no resolved-path string comparison to get wrong;
- **intermediate components are checked too** (`:384`), which is the half that
  is usually missed — a link in the middle of the path traverses just as well as
  one at the end. `build/check_security_backlog.sh` pins the intermediate-symlink
  test by name (F7).

**No Range support**, deliberately and documented (`:62`). That removes the
partial-response machinery entirely rather than shipping it half-implemented, and
the R2 threat model has no requirement it fails.

**Conditional requests:** `If-None-Match` is compared with the WEAK function over
a list, corrected by audit R10 from a single exact byte compare (`:101`). That is
correctness, not security, but a wrong comparison here serves stale bytes.

---

## 3. Upload — confirmed, with the slot leak now tested rather than argued

`web.enable_upload` is opt-in, and admission is bounded before a byte is read
(`web/internal/ingest/ingest.odin:149`). Files are created `0600` inside the
configured directory, never under the client's filename and never in a silent
`/tmp` (`:196`). Per-upload quota, concurrency and process quotas all bound it.

The review's one open item is closed in the same work package: **F-007**, the
admission slot that `begin` kept when `os.open` failed, was pinned by an argument
and is now pinned by
`tests/ingest-leak::upload_admission_survives_an_unopenable_spool`, with the
mutant wired into `build/check_merged_fix_mutations.sh`. The reason it mattered
is the recovery, not the failure: a briefly unwritable spool directory used to
retire `max_concurrent` slots permanently.

---

## 4. Administrative endpoints — there are none, and that is the finding

**The framework ships no administrative surface.** No admin listener, no
management routes, no debug endpoints. R2-WP03 considered an administrative
listener as arm A and ADR-050 chose arm B instead — an out-of-band snapshot file
written by a thread that owns no lane — so the metric path has no network
between it and its reader.

What exists is what applications add. Two shapes appear in this repository and
they are not equivalent:

- `ops/soak/soak-server` exposes `/stats` **as an ordinary route** on the Handler
  lanes. That is the exact configuration OBS-001 was found in: under saturation
  it stops answering, and an absent scrape is indistinguishable from a lost
  packet. It is kept because the soak needs a comparison arm, not because it is
  the recommendation.
- `examples/04-middleware` gates `/admin` behind an API-key middleware. It is an
  example of middleware, not a hardened admin endpoint, and the R2 threat model
  should not have it read as one.

**The profile consequence, which `docs/supported-profile.md` does not currently
state:** an application that adds an administrative route puts it on the same
lanes as its traffic, behind the same edge, with no separate authentication
story from the framework. There is nothing to review in the framework because
the framework declines to have one — and a reader of the profile cannot learn
that today.

---

## What this review does NOT establish

- **It is a reading, not a campaign.** No traffic was sent at any endpoint for
  this document. The static and upload conclusions rest on the existing named
  tests; TRUST-001 rests on the matcher's semantics, verified against
  `strings.has_prefix` behaviour and not against a running server.
- **TRUST-001 has no test.** It is a property of a documented contract rather
  than a defect in code, and writing a test would mean first deciding what the
  contract should say — which is the owner's call under G5.
- **No authentication, authorization or session review.** The framework provides
  none of the three; whatever an application builds on `web.use` is outside this
  profile's claims and outside this review.
- **Nothing here is a fuzz result or a framing result.** Those are
  `evidence/2026-08-03-r2-wire-fuzz/` and
  `evidence/2026-08-03-r2-proxy-framing/`.
