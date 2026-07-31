# Druse

*A web framework for the Joy of Programming.*

An Odin microframework for real-world JSON APIs. Simple by default, explicit
when needed, data-oriented underneath.

[![gate](https://github.com/jpierreribeiro/druse/actions/workflows/gate.yml/badge.svg?branch=main)](https://github.com/jpierreribeiro/druse/actions/workflows/gate.yml)
[![release](https://img.shields.io/github/v/tag/jpierreribeiro/druse?label=release&sort=semver)](https://github.com/jpierreribeiro/druse/tags)
[![licence](https://img.shields.io/badge/licence-BSD--3--Clause-blue)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--07a-orange)](odin-version.txt)

More about the API is in the [documentation](docs/), and the fastest way in is
the [quick start](docs/quick-start.md).

## High level features

- Route requests to handlers with a macro free API.
- Parse requests with extractors that fail into a typed error response.
- Reach one typed application state value from every handler.
- Compose behaviour with middleware that short-circuits explicitly.
- Return JSON, text, bytes or a stream with the same commit-once contract.
- Grow the framework only through separate packages, never a plugin runtime.

That last point is what sets Druse apart. Optional capability lives in
[Druse Crystals](https://github.com/jpierreribeiro/druse-crystals), a companion
repository of first-party packages: PostgreSQL access, validation, outbound
HTTP, metrics. A Crystal is an ordinary Odin package with explicit
construction, ownership and teardown. There is no registry, no discovery hook,
no dynamic ABI and no extension container, so nothing you do not import costs
you anything, and the core cannot grow through a side door.

<!-- fragment: phase1/readme-taste -->
```odin
package main

import web "druse:web"

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/users/:id", get_user)

	web.serve(&app, 8080)
}

get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, User{id = id, name = "Jean"})
}
```

## Install

Vendor the repository or add it as a git submodule at a pinned commit, then
point Odin at it:

```sh
odin build your_app -collection:druse=path/to/druse
```

There is no package manager step because Odin has no package manager. The
toolchain version is part of the contract and is recorded in
[`odin-version.txt`](odin-version.txt).

## Ecosystem

| | |
|---|---|
| [druse](https://github.com/jpierreribeiro/druse) | the framework, this repository |
| [druse-crystals](https://github.com/jpierreribeiro/druse-crystals) | first-party optional packages and data tools |
| [druse-board](https://github.com/jpierreribeiro/druse-board) | a collaborative ops board, built to prove the framework by use |
| [druse-miniature](https://github.com/jpierreribeiro/druse-miniature) | a small application that proves the Crystals the same way |

## Where to start

- [`docs/quick-start.md`](docs/quick-start.md), from nothing to a running API.
- [`examples/01-hello-world`](examples/01-hello-world), the smallest complete
  program.
- [`examples/02-json-api`](examples/02-json-api), a CRUD-shaped JSON API.
- [`examples/04-middleware`](examples/04-middleware), the onion model,
  short-circuits and `next`.
- [`docs/`](docs/) has the guide, the API reference, the error contract and the
  operations manual.

## What it does not do

Stated plainly, because a framework that hides its edges wastes your time:

- **TLS.** Druse does not terminate TLS and will not. Put it behind a proxy.
- **One server per process.** `web.serve` owns the process's listening socket
  and blocks; `web.stats()` and `web.refused_connections()` take no server
  argument, so a second server in the same process would make them ambiguous.
- **Recoverable panic.** Odin has none, so a faulting handler aborts the
  process. A supervisor is mandatory, not a nicety. Read
  [`docs/operations.md`](docs/operations.md) before deploying.
- **Async handlers.** Handlers are synchronous and hold a lane while they run.
  Blocking work needs a worker, not a longer handler.

## Platform

**Linux x86-64 only, and by construction rather than by omission.** The vendored
bootstrap transport imports `core:sys/linux` and sets up an `io_uring` event
loop per Handler lane, so macOS and Windows do not compile at all: CI proves it
on every push by trying, and the build stops at `sched_yield` and
`setsockopt_base`.

This is not a gap waiting on testing. It lifts when the bootstrap transport is
replaced by the official Odin HTTP package, not before.

## Performance

Measured rather than asserted. The write-ups carry the method, the runs that
were discarded and why, and the caveats:

- [Against six other frameworks on a JSON
  response](docs/reports/2026-07-30-own-marshal.md), at an equal offered rate,
  with every peer server committed in this repository.
- [The encode path, profiled](docs/reports/2026-07-30-encode-profile.md).
- [Every report](docs/reports/).

Reproduce any of it with the harnesses in
[`bench/application_matrix/`](bench/application_matrix/); raw runs and
per-campaign checksums are in [`evidence/`](evidence/).

## Status

`v0.10.0`, pre-1.0. The public contract is 82 symbols, frozen, and the build
refuses to grow it without evidence. A breaking change moves the MINOR, and
`1.0` waits on accrued real-world use rather than on another checklist.

Notable changes are in [`CHANGELOG.md`](CHANGELOG.md); what is planned is in
[`planning/roadmap.md`](planning/roadmap.md).

The transport today is a vendored bootstrap
([`laytan/odin-http`](https://github.com/laytan/odin-http), patched and
recorded), meant to be replaced by the official Odin HTTP package once that
exists and passes the same conformance corpus.

## Contributing

Two things will surprise you, so they come first: the public API is frozen and
the build enforces it, and growing it requires measured evidence rather than
agreement. [`CONTRIBUTING.md`](CONTRIBUTING.md) explains both, and
[`SECURITY.md`](SECURITY.md) covers reporting.

Licensed under [BSD-3-Clause](LICENSE).
