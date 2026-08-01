# 24 — shutdown race (transport audit B2)

Can the acceptor assign a connection into a lane event loop that has already
been destroyed?

ASan is the oracle. Build and run via `ops/campaign/run-campaign-b2.sh`, which
builds with `-sanitize:address` and refuses to start unless
`ulimit -l` is unlimited — without that, ASan plus io_uring reproduces F-C03-2
(a startup assert) instead of the bug under test.

## What the control reverts

`ops/campaign/lib.sh:revert_b2_fix`, both in `vendor/odin-http/server.odin`:

1. **`on_accept_dedicated`** — removes the refusal of late CQEs:
   ```odin
   if atomic_load(&s.closing) {
       if op.accept.err == nil { net.close(op.accept.client) }
       return
   }
   ```
2. **`_server_thread_shutdown`** — removes the `accept_drained` gate the lanes
   wait on before `nbio.release_thread_event_loop()`.

The deferred release of the ACCEPTOR's own loop (moved into `serve`, after
`sync.wait(&s.threads_closed)`) is deliberately left in place: it addresses the
reverse race, where a lane wakes a loop the acceptor just freed, and reverting
both at once would make an ASan report ambiguous about which fix it exercised.

## Expected outcomes

- **Control**: an ASan use-after-free or use-after-poison inside the lane's
  operation pool or MPSC ring, or a hard crash. Record the iteration.
- **Verify**: 50,000 iterations across the delay sweep, no report.
- **Control does not report**: say so in those words. The race was not
  reproduced on that hardware and the fix stands on the code argument alone.

## Not yet attempted

The audit container's `ulimit -l` is 8192 KiB, so the runner correctly refused
and neither arm has been executed anywhere. Both are owed on the campaign host.
