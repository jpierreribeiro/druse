# Make a request idempotent

Package `crystals:idempotency`, HTTP adapter `crystals:web/idempotency`.

For a POST a client may retry — a payment, an order — where running twice is
worse than failing.

## The handler

```odin
	key, ok := idem.key(ctx)
	if !ok {
		web.bad_request(ctx, "Idempotency-Key header required")
		return
	}

	switch idem.begin(ctx, &state.idem, key) {
	case .Proceed:
		// first time: do the work
	case .Replay:
		return          // the stored response was already sent
	case .In_Progress:
		return          // 409; a concurrent attempt holds the key
	case .Conflict:
		return          // same key, different request body
	case .Failed:
		return
	}
```

`Outcome` puts **`Failed` at zero**, so a caller that forgets to switch does
not run the operation.

## Complete it

```odin
	idem.complete(ctx, &state.idem, key, status, payload)
```

Store the outcome so the retry can replay it. Until you do, the key is
*reserved*, not finished.

`idem.release` drops a reservation when you decided not to proceed after all —
without it the key stays locked until it expires.

## Why `Conflict` exists

The same key with a **different body** means the client reused a key for a new
request. Answering with the stored response would silently drop the new one.

The adapter answers `STATUS_CONFLICT` with `CODE_CONFLICT`. Do not paper over
it.

## What the record holds

`Record` is `{status, payload, completed_unix}` — your own small summary of what
happened, **not an HTTP response**. The adapter gives it wire meaning. Keep it
small; it is stored per key. `completed_unix` is `0` while still reserved.

## The client must send the key

`idem.key` reads `idem.HEADER`. A client that omits it gets no protection, so
decide whether the header is required and say so in your API documentation.

Generate it **per logical operation**, not per attempt — a client that makes a
new key on each retry has an ordinary POST.

## With jobs

Job delivery is at-least-once, so a handler runs twice sometimes. Wrapping the
external call in an idempotency key is how you make that harmless. See
[`run-background-jobs.md`](run-background-jobs.md).
