# Application

Creating, configuring, serving and stopping.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `App`

```odin
App :: struct {private: App_Internal}
```

App owns the application's resources.

## `app`

```odin
app :: proc() -> App
```

app creates an application with the progressive Phase-1 defaults.

## `bare`

```odin
bare :: proc() -> App
```

bare creates an application with none of the default middleware or policies, for callers that want full control.

## `app_with_state`

```odin
app_with_state :: proc(state: ^$T) -> App
```

app_with_state creates an application with the same defaults as `app()` and one typed value every handler can reach.

Taught in [`03-subjects/context-and-state.md`](../guide/03-subjects/context-and-state.md).

## `destroy`

```odin
destroy :: proc(a: ^App)
```

destroy releases everything the application owns.

## `serve`

```odin
serve :: proc(a: ^App, port: int)
```

serve runs the application's HTTP server on the given port and blocks until the server stops.

## `stop`

```odin
stop :: proc(a: ^App)
```

stop asks the running server to stop serving.

Taught in [`03-subjects/limits-and-shutdown.md`](../guide/03-subjects/limits-and-shutdown.md).

## `is_draining`

```odin
is_draining :: proc(a: ^App) -> bool
```

is_draining reports whether `stop` has been requested on this application.

## `limits`

```odin
limits :: proc(a: ^App, l: Limits)
```

limits sets the application's byte budget.

Taught in [`03-subjects/limits-and-shutdown.md`](../guide/03-subjects/limits-and-shutdown.md).

## `Limits`

```odin
Limits :: struct {max_body: int, max_request_line: int, max_headers: int, max_request_time: i64, max_write_time: i64, max_response_bytes: int, max_idle_time: i64, max_connections: int, reserved_conns: int, max_drain_time: i64, max_handlers: int, max_json_nodes: int}
```

Limits is the application's byte budget for one request.

## `DEFAULT_LIMITS`

```odin
DEFAULT_LIMITS :: Limits{max_body = BODY_LIMIT, max_request_line = REQUEST_LINE_LIMIT, max_headers = HEADER_BLOCK_LIMIT, max_request_time = REQUEST_TIME_LIMIT, max_write_time = 0, max_response_bytes = 0, max_idle_time = 0, max_connections = CONNECTION_LIMIT, reserved_conns = RESERVED_CONNECTION_LIMIT, max_drain_time = DRAIN_TIME_LIMIT, max_handlers = 0, max_json_nodes = JSON_NODE_LIMIT}
```

DEFAULT_LIMITS is what every application gets without asking.

## `state`

```odin
state :: proc(ctx: ^Context, $T: typeid) -> (value: ^T, ok: bool)
```

state returns the application's state as a `^T`, and whether it was there.

Taught in [`03-subjects/context-and-state.md`](../guide/03-subjects/context-and-state.md).

## `request_state`

```odin
request_state :: proc(ctx: ^Context, $R: typeid) -> ^R
```

request_state returns a pointer to the request's ONE typed, request-scoped value — corrective WP C7 (friction F8-3), the narrow ADR-028 reopening.

Taught in [`03-subjects/context-and-state.md`](../guide/03-subjects/context-and-state.md).
