# Experiment 17 — large-body ingest arms (WP86, second arm)

**Question** (evidence backlog §3): *are large requests better served by spool
or direct streaming?* The observable decision is the WP93/WP94 ownership
model. Baseline: the buffered path refuses bodies above `Limits.max_body` and
supports no claim about larger ones.

**The four arms**, all carrying the same 8 MiB body in 64 KiB chunks:

- **E — Handler pulls chunks synchronously.** Runs, is bounded in memory — and
  records the veto: the lane is occupied for every chunk, so upload
  concurrency equals lane concurrency, recreating the head-of-line failure on
  slow clients. Losing-arm number: lane occupied 128/128 chunks.
- **F — adapter spools before invoking the Handler.** Lane occupied 0 chunks;
  peak tracked memory = one 64 KiB chunk buffer; the Handler receives a
  complete owned spool or is never scheduled.
- **G — bounded admission + workers spool.** Admission refuses the third
  concurrent ingest (capacity 2, the spec's `lanes − 1` shape) with a typed
  result before any byte is read. The spool loop itself is arm F's append —
  there is no CPU work in it to justify a worker tier.
- **H — application incremental consumer.** Works arithmetically, and records
  the shape finding: state must outlive every callback, giving the
  application a framework-driven lifetime — a second Handler model, which the
  frozen pre-decisions refuse for the Productive path.

**Controls** (per phase-7-spec.md §4.2, outcomes pre-registered): quota breach
mid-body cancels and deletes (`Quota_Exceeded`, no file remains); mid-body
disconnect cancels and deletes (`Disconnected`, Handler never scheduled);
spool files are `0600` under a generated `druse-spool-` name; success-path
content is verified byte-exact then removed.

**Decision recorded.** The productive arm is **bounded spool = F's loop under
G's admission**: chunks are appended where they arrive (the event/connection
side), admission is capped below lane capacity, and the ordinary synchronous
Handler runs only when the body is Ready — no second Handler model, no worker
tier without evidence of CPU-bound work. H remains an Advanced candidate
under the plan's own bar (recognizably Odin ownership, no hidden callback
lifetime) and is not part of the Productive contract. This matches the
plan's recommendation (F/G) and gives WP93/WP94 their shape.

Disposable prototypes; never imported by `web`; the multipart boundary parser
is deliberately absent (WP93's question, not this one).
