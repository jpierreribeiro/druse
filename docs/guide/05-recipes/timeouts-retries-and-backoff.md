# Timeouts, retries and backoff

What to do when something fails for a reason that may not be true a second from
now.

## Bound everything that waits

| Bound | Where |
|---|---|
| Query | `pg.Config.statement_timeout_ms` — cancelled server-side |
| Acquiring a connection | `Pool_Config.acquire_timeout_ms` |
| Outbound HTTP | `http_client` connect and request timeouts, under one deadline budget |
| Request arrival | `web.Limits.max_request_time` — on by default |
| Response write | `web.Limits.max_write_time` — **off** by default |

**A query with no deadline is a connection you cannot get back.** Set
`statement_timeout_ms`, or the pool empties and the symptom appears in a
handler unrelated to the slow query.

## Retry only what is safe to repeat

A timeout does not tell you whether the work happened — the request may have
succeeded and the answer been lost.

**Retry a read freely. Never retry a write without an idempotency key.** See [`idempotent-requests.md`](idempotent-requests.md). `http_client` retry is
stated as **at-least-once** for exactly this reason — it does not pretend
otherwise.

## Back off, do not hammer

```odin
backoff :: proc(attempt: int) -> i64
```

`jobs.backoff` doubles from 2 seconds and caps at one hour.

The cap matters as much as the doubling. Without it, attempt 20 lands past any
date you care about; without the doubling, a hundred workers retrying every
second are a denial of service you built against your own database.

```odin
	if !deliver(job) {
		return jobs.retry_after(jobs.backoff(job.attempts))
	}
```

## Give up

`DEFAULT_MAX_ATTEMPTS` is 5. After that the job is done failing.

**Return `jobs.fail_final` for anything that cannot succeed on a retry** — a
malformed payload, a deleted record, a rejected address. Retrying it burns the
queue until the cap and hides the failures that were real.

The rule: retry a *transient* failure, fail a *permanent* one. If you cannot
tell which you have, you are missing a typed error from the layer below.

## What is not here

**No circuit breaker.** If a dependency is failing and you want to stop calling
it, you write that — a counter in `App_State` and a check before the call.

**No automatic retry.** `web.serve` never repeats a handler and never will: it
cannot know whether yours is safe to run twice.

## Fail fast where waiting cannot help

`respond_db_error` in `examples/notes` groups `Pool_Exhausted`, `Timeout`,
`Canceled` and `Connection_Lost` into one `503`.

That is the honest answer for all four: the request is fine, the service is not,
come back. A `500` says the request is broken and invites the client to change
it, which is wrong and unhelpful.

Send `Retry-After` when you know roughly when — see
[`error-responses.md`](error-responses.md).
