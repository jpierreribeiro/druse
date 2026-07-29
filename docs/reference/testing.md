# Testing

The separate two-symbol ledger. It cannot grow by borrowing the application budget.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `test_request`

```odin
test_request :: proc(a: ^App, method: Method, path: string, body: string = "", query: string = "", headers: []string = nil) -> Recorded_Response
```

*Test-support ledger.*

test_request drives one in-memory request through dispatch and returns the recorded response, WITHOUT binding a socket or port.

Taught in [`05-recipes/test-a-handler.md`](../guide/05-recipes/test-a-handler.md).

## `Recorded_Response`

```odin
Recorded_Response :: struct {status: Status, body: string, headers: []string}
```

*Test-support ledger.*

Recorded_Response is the read-only result of `web.test_request`.
