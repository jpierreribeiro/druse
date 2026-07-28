# Run work in the background

Package `crystals:jobs`, with `jobs_postgres` for durable storage.

A worker is a different shape of program from a web service. It does not serve;
it leases work, runs it, and reports an outcome.

## Register handlers, then enqueue

```odin
	reg: jobs.Registry
	jobs.register(&reg, "send_welcome", send_welcome)

	q := jobs.queue(store)
	jobs.enqueue(&q, "send_welcome", payload)
```

A job is a **name plus a payload**, not a closure. That is what lets a
different process run it.

`MAX_NAME_BYTES` and `MAX_PAYLOAD_BYTES` bound both. Put an id in the payload
and load the rest from the database — never the whole record.

## The handler returns an outcome

```odin
send_welcome :: proc(job: jobs.Job) -> jobs.Result {
	if !deliver(job) {
		return jobs.retry_after(60)
	}
	return jobs.success()
}
```

Three constructors, and choosing between them is the whole design of a job:

| Return | Means |
|---|---|
| `jobs.success()` | Done. The job is removed |
| `jobs.retry_after(n)` | Transient. Try again in `n` seconds |
| `jobs.fail_final(reason)` | Permanent. Stop retrying and record why |

**`fail_final` for a bad payload.** Retrying a job that can never succeed burns
the queue until `DEFAULT_MAX_ATTEMPTS` and hides real failures.

## The worker

```odin
	w := jobs.worker(&reg, &q)
	for {
		jobs.run_once(&w)
	}
```

`run_once` leases one job, runs it and settles it. You own the loop, the
sleeping and the shutdown — the same way you own `main` in a web service.

`jobs.backoff` computes the delay between attempts.

## At-least-once, so make handlers idempotent

A lease can expire while the handler is still running — the process was paused,
the database was slow — and the job is handed to another worker.

**Your handler will sometimes run twice for one job.** Write it so that is
harmless: check whether the effect already happened, or use
`crystals:idempotency` around the external call.

`DEFAULT_LEASE_SECONDS` is 300. Size it above your slowest handler.

## Where it runs

A separate process from the web server, sharing the database. It has its own
`main`, its own pool, and no `web.serve`.

Neither the framework nor the queue starts a thread for you.
