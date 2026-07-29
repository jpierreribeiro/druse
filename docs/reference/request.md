# Request

Reading input. Every string here is a view into the request buffer.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `Context`

```odin
Context :: struct {request: Request, private: Context_Internal}
```

Context is the canonical, non-parametric request context.

## `Request`

```odin
Request :: struct {method: Method, path: string, query: string, headers: Header_View, body: []u8}
```

Request is the framework-owned view of one in-flight HTTP request.

## `Method`

```odin
Method :: enum u8 {UNKNOWN, GET, POST, PUT, PATCH, DELETE}
```

Method is the closed set of HTTP methods Phase 1 gives a public meaning to.

## `Header_View`

```odin
Header_View :: struct {private: Header_View_Internal}
```

Header_View is the framework-owned view of the request headers.

## `path`

```odin
path :: proc(ctx: ^Context, name: string) -> string
```

path returns the value of a path parameter.

## `path_int`

```odin
path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)
```

path_int returns a path parameter parsed as an integer.

## `query`

```odin
query :: proc(ctx: ^Context, name: string) -> (value: string, found: bool)
```

query returns a query-string parameter as text.

## `query_int`

```odin
query_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)
```

query_int returns a required query parameter parsed as an integer.

Taught in [`05-recipes/read-a-query-parameter.md`](../guide/05-recipes/read-a-query-parameter.md).

## `query_int_opt`

```odin
query_int_opt :: proc(ctx: ^Context, name: string) -> (value: int, present: bool, ok: bool)
```

query_int_opt reads an OPTIONAL typed query parameter and reports its PRESENCE distinctly (corrective WP C3, friction F8-6). It is the reader an optional typed filter needs, which neither of the others is:

Taught in [`05-recipes/read-a-query-parameter.md`](../guide/05-recipes/read-a-query-parameter.md).

## `query_int_or`

```odin
query_int_or :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool)
```

query_int_or returns an optional query parameter parsed as an integer.

Taught in [`05-recipes/read-a-query-parameter.md`](../guide/05-recipes/read-a-query-parameter.md).

## `header`

```odin
header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool)
```

header returns the EFFECTIVE request header named `name`.

## `bearer_token`

```odin
bearer_token :: proc(ctx: ^Context) -> (value: string, ok: bool)
```

bearer_token returns the bearer token from the `Authorization` header, parsed against RFC 6750 STRICTLY:

## `body`

```odin
body :: proc(ctx: ^Context, dst: ^$T) -> bool
```

body decodes the JSON request body into a caller-owned destination.

Taught in [`03-subjects/binding.md`](../guide/03-subjects/binding.md).

## `form_field`

```odin
form_field :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool)
```

form_field returns a text field's value.

## `form_file`

```odin
form_file :: proc(ctx: ^Context, name: string) -> (file: Uploaded_File, ok: bool)
```

form_file returns a file part.

## `Uploaded_File`

```odin
Uploaded_File :: struct {field: string, filename: string, content_type: string, bytes: []u8}
```

Uploaded_File is one file part, by value.
