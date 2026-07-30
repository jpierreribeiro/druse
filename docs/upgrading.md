# Upgrading Druse

**Who this is for:** whoever pins Druse in a real application and has to move
it forward without discovering a silent behaviour change in production.

Druse has **not cut a public release or a version tag yet** (the roadmap holds
tags until milestone M2). Until then, you consume it by pinning a commit, and
this document tells you how to move that pin safely.

## How you consume it

Odin has no package manager, so a dependency is a **vendored or submodule'd
copy pinned to a commit**, wired in with a collection:

```
odin build your-app -collection:druse=path/to/druse
```

Two things are part of the contract, not just the source:

- **The core commit** — the exact `druse` revision you built against.
- **The Odin toolchain commit** — Druse pins one nightly in
  `odin-version.txt`, and its gate refuses any other. Your build should use the
  same toolchain, because Druse's guarantees are only measured against it.

Record both in your own build, the way Druse records its own.

## What is frozen, and what that buys you

Phases 1–5 are **frozen**: the public surface (the 63-symbol application ledger
plus the 2 test-support symbols) is pinned by a gate that fails the build if a
symbol is added, removed, renamed, moved between ledgers, or has its signature
changed without a recorded amendment. Concretely, when you move your pin
forward:

- **A frozen symbol will not have changed its signature under you.** If it did,
  the change carries a spec amendment you can read — it is never silent.
- **New symbols may appear** in a later phase; they never break existing code.
- **Behaviour recorded in a freeze manifest** (`planning/phase-N-freeze.md`) is
  evidence-backed and stable. Behaviour explicitly recorded as *not delivered*
  in those manifests is exactly that — do not build on it.

## How to move the pin

1. Read the commits between your pin and the target — specifically the
   `planning/phase-*-freeze.md` and `planning/adrs.md` changes. An **ADR
   amendment** or a **freeze amendment** is where a real behaviour change is
   announced.
2. **Look for compatibility breaks called out as such.** They are rare and
   deliberate — for example, ADR-037 changed how `client_ip` resolves
   `X-Forwarded-For` (from the leftmost entry to walking from the right), which
   changes the value your rate limits and audit logs see. A break like that is
   named in its ADR with its reversibility; it is never a quiet edit.
3. Rebuild with Druse's pinned toolchain and **run your own tests** — the
   in-memory `web.test_request` path (see the Quick Start) exercises your
   handlers without a socket, so a behaviour change surfaces in your suite
   rather than in production.
4. Move the toolchain pin only when `odin-version.txt` moves, and to the commit
   it names.

## What has no compatibility promise yet

- **Private and internal types.** Anything under `web/internal/`, the vendored
  backend under `vendor/`, and any `@(private)` symbol is not public surface and
  may change between commits. If your application reached into one, that is the
  one place an upgrade can surprise you — don't.
- **Planned, unfrozen phases.** Streaming (Phase 7), the data and composition
  Crystals, and anything an ADR marks PROPOSED are still moving.
- **Platform.** The gate validates Linux x86-64 only (see
  `docs/platform-contract.md`). Other platforms are unverified.

## Before you ship an upgrade

The same checklist Druse applies to itself is a good one for you: toolchain
pinned, your gate green, your handlers' behaviour unchanged under
`web.test_request`, the freeze/ADR amendments between pins read, and any named
compatibility break understood and accounted for. A move that clears those is a
move that will not page you.
