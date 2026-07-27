# Rate limit a route

Package `crystals:rate_limit`, HTTP adapter `crystals:web/rate_limit`.

## In `main`

```odin
	c := rate_limit.Config{...}
	lim, err := rate_limit.limiter(c, store)
	if err != .None {
		os.exit(1)
	}
	state.limits = lim
```

The limiter is a service. It lives in `App_State`, and the application owns the
backend — `rate_limit_memory` for one process, `rate_limit_postgres` for many.

**Use the Postgres backend behind a load balancer.** A memory limiter gives
each replica its own budget, so N replicas means N times the limit.

## In the handler

```odin
	if rl.reject(ctx, &state.limits, key) {
		return
	}
```

`reject` consumes one unit, answers `429` itself when the budget is gone, and
returns `true`. Put it first — before anything changes.

To report the budget without refusing, use `rl.annotate`.

## The headers

`web/rate_limit` sets `HEADER_LIMIT`, `HEADER_REMAINING`, `HEADER_RESET` and
`HEADER_RETRY_AFTER`. A client that reads them can back off instead of
hammering you.

## Choosing the key

The key decides *what* is limited. Get it wrong and you limit the wrong thing:

| Key | Limits |
|---|---|
| Client IP | Everyone behind one NAT together |
| Session subject | One signed-in user |
| API key id | One integration |

**If you key by IP, call `web.trust_proxies` first.** Otherwise `client_ip` is
your load balancer's address and every user shares one bucket. See
[`serve-a-browser-app.md`](serve-a-browser-app.md).

`MAX_NAMESPACE_BYTES` and `MAX_SUBJECT_BYTES` bound the key. A long key is
refused, not truncated.

## The direct API

`consume` takes budget, `peek` reads without taking, `reset` clears one key,
`purge` drops expired state, `settle` returns unused budget after work you
decided not to do.

`Result` and `Store_Result` both put the safe value at zero — an unassigned
result refuses.
