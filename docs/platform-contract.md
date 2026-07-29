# Platform contract

**Status: PROPOSED, 2026-07-23.** The platform Druse actually targets, stated
as a **selected profile** — not a claim of full POSIX (IEEE 1003.1-2024)
conformance. Druse uses a small, named subset of operating-system services; this
document is that subset and the guarantees that depend on it. It lives at the
adapter/operations boundary, not in the public API.

## Supported profile

```text
- Linux x86-64 (the only platform the gate validates)
- POSIX process model, one server per process
- monotonic clock for all deadlines (request arrival, drain)
- supervisor-managed recovery (a faulting handler aborts the process; ADR-020)
- reverse-proxy-managed TLS, compression and edge rate limiting
```

Anything outside this profile is `NAO_APLICAVEL` until a future gate validates it
(other architectures/OSes are an ABERTO item with a registered trigger; see the
production-readiness audit).

## The OS services Druse relies on (the selected 1003.1 subset)

| Area | What Druse relies on | Where |
|---|---|---|
| Signals | `SIGTERM`/`SIGINT` delivered to the process; the application installs the handler and calls `web.stop` (the core installs none — ADR-040). `web.stop` is async-signal-safe (atomic flag + loop wake). | app `main`, `web/lifecycle.odin` |
| Signal-handler safety | Only async-signal-safe work in a handler: set a flag / call `web.stop`. No allocation, no logging from the handler itself. | `docs/operations.md` |
| Monotonic clock | Request-arrival and drain deadlines use a monotonic source; wall-clock changes must not move a deadline. | `web/limits.odin`, backend sweep |
| Interrupted syscalls | `EINTR` on accept/recv is transient and must not be fatal (see finding F9, routed to Phase 7). | `vendor/odin-http/server.odin` |
| File descriptors | Bounded by `Limits.max_connections`; the reservation (`reserved_conns`) keeps FDs for shutdown. Exhaustion (`EMFILE`/`ENFILE`) is refused, not fatal. | `web/limits.odin`, backend `on_accept` |
| Sockets | One owner per connection (the lane); close cancels the outstanding receive before freeing (WP58). Non-blocking I/O via `core:nbio`. | `vendor/odin-http/server.odin` |
| Files & symlinks | Static serving rejects `..`, percent-encoded separators, NUL, dotfiles and symlinks (final component; intermediate components too after F7). `os.read_entire_file_from_path`; whole-file buffered read. | `web/static.odin`, `web/path_policy.odin` |
| Atomicity | Migrations (data Crystal) use advisory locking and fail closed on concurrent apply; `CREATE TABLE IF NOT EXISTS` races are tolerated (`42P07`/`23505`). | data Crystal |
| Process under systemd | `Restart=always`, `TimeoutStopSec` is the outer bound for a stuck handler; logs to stdout/stderr (whichever sink the app installs). | `docs/operations.md` |

## Guarantees that depend on this profile

- **Graceful drain** assumes the monotonic clock and that the process manager
  delivers `SIGTERM` before `SIGKILL` with enough grace (≥ `max_drain_time`).
- **Slowloris/arrival deadline** assumes a monotonic timer and non-blocking
  accept/recv.
- **Bounded admission** assumes FD limits are the OS's, and that the reservation
  is honored.
- **Static-file safety** assumes POSIX `lstat`/`open` symlink semantics.

## Deviations

- Druse does not claim POSIX conformance and does not run a POSIX conformance
  suite; it validates only the selected subset above, on Linux x86-64, in the
  gate. The rest of 1003.1 is `NAO_APLICAVEL`.
- The core installs **no** signal handler by design (ADR-040): seizing process
  signals would fight the supervisor and the twelve-factor model.
