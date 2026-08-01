# 23 — accept stall (transport audit B1)

Does the acceptor ever park holding a connection it never places?

Build and run via `ops/campaign/run-campaign-b1.sh`; see `ops/campaign/README.md`
for the procedure and `planning/verification-campaign-plan.md` for what counts as
an acceptance.

## What the control reverts

`ops/campaign/lib.sh:revert_b1_fix` applies these, all in
`vendor/odin-http/server.odin`. Listed here so a human can check the script did
what it claims.

1. **`accept_try_assign_pending`** — the seq-cst publish plus re-scan becomes the
   original Release store and immediate `return false`:
   ```odin
   sync.atomic_store_explicit(&s.pending_waiting, true, .Release)
   return false
   ```
2. **`accept_choose_lane`** — `.Seq_Cst` loads of `handler_active` and
   `queued_handoffs` become `.Acquire` and the default.
3. **`on_connection_assigned`** — the `.Seq_Cst` load of `pending_waiting`
   becomes `.Acquire`.
4. **`handler_lane_enter` / `handler_lane_leave`** — the `.Seq_Cst` stores of
   `handler_active` become `.Release`, and the `.Seq_Cst` load of
   `pending_waiting` becomes `.Acquire`.
5. **`_server_accept_loop`** — the bounded safety-net tick becomes the original
   unbounded park:
   ```odin
   err := nbio.tick()
   ```
   This one is essential to the control. Leaving it in would mask the stall the
   control is trying to see, and a control that cannot fail is worthless.

## Result so far

Attempted on the audit container (4 cores, shared) for **3,123 cycles** at
dwell 3 ms / quiet 30 ms / wave 16 — the most aggressive configuration the box
sustained — and the stall **did not reproduce**. Worst canary was 31 ms against
a 2 s budget.

That is recorded rather than omitted. The window is nanoseconds wide; x86-TSO
permits the store→load reordering the fix addresses but does not make it
frequent, and a 4-core shared container is not where it is most likely to
appear. Re-run on the campaign host with real cores before drawing a conclusion,
and if the control still refuses to fail, report that the harness bounds nothing.
