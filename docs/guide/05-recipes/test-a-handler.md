# Test a handler

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

No socket, no port, no fixture server. One call runs a request through the real
routing.

```odin
test_request :: proc(a: ^App, method: Method, path: string,
                     body: string = "", query: string = "",
                     headers: []string = nil) -> Recorded_Response

Recorded_Response :: struct { status: Status, body: string, headers: []string }
```

These two symbols are the **entire** test-support ledger, separate from the
80-symbol application ledger on purpose: test support cannot grow by borrowing
the application's budget.

## The shape

```odin
check_ping :: proc() -> bool {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping)

	res := web.test_request(&app, .GET, "/ping")
	return res.status == .OK && res.body == "pong"
}
```

Build the application the same way `main` does — you are testing your
composition, not a mock of it.

## With a body, a query, headers

```odin
	res := web.test_request(&app, .POST, "/notes", `{"slug":"a","title":"A"}`)

	res := web.test_request(&app, .GET, "/notes", query = "limit=5&after=10")

	res := web.test_request(&app, .GET, "/me", headers = {"Cookie", "session=abc"})
```

`headers` is a flat slice of alternating names and values.


## Test what the framework answers, not only what you wrote

```odin
	res := web.test_request(&app, .GET, "/nope")
	// .Not_Found, with the JSON envelope

	res := web.test_request(&app, .DELETE, "/ping")
	// .Method_Not_Allowed, plus an Allow header
```

These are the responses you never wrote. Pin them, so a routing change breaks a
test rather than a client.

## With application state

Build it exactly as `main` does, with `web.app_with_state(&state)`. The state
must outlive the application.

## Why this matters more than it looks

The recorded fact: **35 green negative controls did not catch four defects, and
all four were integration defects** — each package correct, the composition
wrong.

The build check proves each package does what its tests say. It does not prove
your `main` wired them together correctly. `test_request` is what does, and it
costs one procedure call.

Fault behaviour is identical here and under `web.serve`.
