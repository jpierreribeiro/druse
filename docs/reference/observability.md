# Observability

What failed, how often, and what the server is doing.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `observe`

```odin
observe :: proc(a: ^App, observer: proc(event: Framework_Event))
```

observe registers the application's framework-error observer.

Taught in [`05-recipes/observe-the-framework.md`](../guide/05-recipes/observe-the-framework.md).

## `Framework_Event`

```odin
Framework_Event :: struct {kind: Framework_Error, method: Method, route: string, status: Status, payload_type: typeid}
```

Framework_Event is the one closed event a framework-detected failure produces. It is passed to the observer BY VALUE.

## `Framework_Error`

```odin
Framework_Error :: enum {None, Response_Marshal_Failed, Body_Decode_Failed, Body_Consumed_Twice, No_Response_Committed, Invalid_Serve_Port, Serve_Listen_Failed, Use_After_Route, Response_Too_Large}
```

Framework_Error is the closed set of framework-detected failures the framework reports. It grows only when a work package ratifies a new one.

## `logger`

```odin
logger :: proc(ctx: ^Context)
```

logger writes one line per request to `context.logger`, at `.Info` level, after the rest of the chain has run.

## `request_id`

```odin
request_id :: proc(ctx: ^Context)
```

request_id assigns every request an ID, honours a well-formed client value, and puts the result on the response.

## `stats`

```odin
stats :: proc() -> Server_Stats
```

stats returns the running server's write-side counters, or the zero value when no server is running. It allocates nothing and reads nine integers under one lock, so the snapshot is coherent.

Taught in [`05-recipes/observe-the-framework.md`](../guide/05-recipes/observe-the-framework.md).

## `Server_Stats`

```odin
Server_Stats :: struct {refused_connections: int, responses_sent: int, response_bytes: i64, send_errors: int, write_deadline_aborts: int, handler_dwell_ns: i64, stream_refused_full: int, stream_refused_budget: int, stream_aborted_slow: int}
```

Server_Stats is the write-side accounting `web.stats` returns (Closure H-3).

## `refused_connections`

```odin
refused_connections :: proc() -> int
```

refused_connections reports how many connections this process has refused for admission (WP47's `Limits.max_connections`) since the server started.
