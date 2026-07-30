# WP69 blocking-boundary result

This is a liveness experiment, not a throughput benchmark. The deterministic
latch stands in for a synchronous PostgreSQL query without involving a driver.

Run:

```sh
odin run experiments/15-blocking-boundary -collection:druse=.
```

Pre-registered interpretation:

- one lane plus one blocked handler must prevent health until release (negative
  control);
- four lanes plus three blocked handlers must let health finish before release;
- four blocked handlers may prevent health, and that is the explicit bounded
  saturation condition, not a claim of preemption;
- idle keep-alive and a partial request remain non-blocking I/O and do not
  consume the synchronous handler lane;
- the job-pool arm is not an implementation candidate because the current
  synchronous `Dispatch_Proc` returns a complete `Outbound`; returning from a
  worker later would require a continuation and a new ownership contract.

An additional WP69 observation constrains the implementation: upstream rearms
each lane's `accept` operation before invoking the synchronous Handler. With
only one or two blocked lanes, a newly connected request can therefore already
belong to a blocked lane while other lanes remain free. WP71 must suspend new
admission on a lane while its Handler is active (and rearm it afterwards), then
WP72 repeats blocker counts 1 through `lanes - 1`. Existing keep-alive
connections remain lane-owned and are honestly inside that lane's blast radius.

The record-size line is a structural lower bound, not total RSS. Phase 4's live
connection laboratory remains the authoritative measured per-connection cost;
WP72 measures the integrated multi-lane server under the full fault corpus.

The executable runs the four-lane arms before the one-lane negative control.
`odin-http` is process-oriented and mixed lane-count restarts in the same process
retain backend event-loop state; Druse starts one server with one immutable lane
count, so restart order is harness state rather than a production topology. The
test locks this ordering instead of allowing randomized test order to pollute the
result.
