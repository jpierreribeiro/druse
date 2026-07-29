# Browser and proxy

CORS, static files, security headers, and the real client address.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `cors`

```odin
cors :: proc(a: ^App, o: Cors_Options)
```

cors installs the cross-origin policy. Call it BEFORE the first request, like `limits`:

Taught in [`05-recipes/serve-a-browser-app.md`](../guide/05-recipes/serve-a-browser-app.md).

## `Cors_Options`

```odin
Cors_Options :: struct {origins: []string, methods: string, headers: string, credentials: bool, max_age: int}
```

Cors_Options is the policy, by value.

## `static`

```odin
static :: proc(a: ^App, prefix: string, dir: string, o: Static_Options = {...})
```

static mounts `dir` at `prefix`. Call it before the first request:

## `Static_Options`

```odin
Static_Options :: struct {max_file_size: int, index: string}
```

Static_Options is the per-mount policy, by value.

## `secure_headers`

```odin
secure_headers :: proc(ctx: ^Context)
```

secure_headers adds the three unconditional security headers to every response this application produces.

## `client_ip`

```odin
client_ip :: proc(ctx: ^Context) -> string
```

client_ip returns the address this request should be attributed to.

Taught in [`05-recipes/serve-a-browser-app.md`](../guide/05-recipes/serve-a-browser-app.md).

## `trust_proxies`

```odin
trust_proxies :: proc(a: ^App, prefixes: []string)
```

trust_proxies declares which peers are allowed to speak for their clients.
