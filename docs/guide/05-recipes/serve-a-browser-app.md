# Serve a browser, and run behind a proxy

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

Four things a service answering a browser needs. All are configured in `main`,
except `secure_headers`, which is a middleware.

## CORS

```odin
	web.cors(&app, web.Cors_Options{
		origins     = {"https://app.example.com"},
		headers     = "Content-Type, Authorization",
		credentials = true,
		max_age     = 600,
	})
```

It covers **every** response, including the automatic 404 and the 500. A
browser that cannot read your error shows the user a blank page.

**Unsafe combinations are refused at boot**, not at request time: `*` with
credentials, `*` beside named origins, `*` in the header list with credentials.
The application will not start rather than share one origin's authenticated
data with another.

## Static files

```odin
	web.static(&app, "/assets", "public", web.Static_Options{index = "index.html"})
```

A static mount **owns its prefix**. Everything under `/assets` is answered from
the directory or answered `404`. It never falls through to a route, so do not
register one under the same prefix and expect it to run.

Traversal, percent encoding, dotfiles and symlinks are all refused.

**Responses are buffered whole**, so a file costs its size in memory. That is
what `Static_Options.max_file_size` is for, and why it has a default rather
than being optional.

## Security headers

```odin
	web.use(&app, web.secure_headers)
```

A middleware, so it goes with the others, before any route.

## The client's IP behind a proxy

```odin
client_ip     :: proc(ctx: ^Context) -> string
trust_proxies :: proc(a: ^App, prefixes: []string)
```

```odin
	web.trust_proxies(&app, []string{"10.0.0.0/8"})
	// ...
	ip := web.client_ip(ctx)
```

**`client_ip` reports the socket peer unless you call `trust_proxies` first.**
That default is the safe one: `X-Forwarded-For` is a header, and any client can
send it.

Once a peer matches a trusted prefix, its `X-Forwarded-For` is believed. An
untrusted peer sending the same header is ignored and you still get the socket
address.

List **your** load balancer, and nothing else. Trusting a wide range lets
anything inside it forge an address — which matters when you rate-limit or log
by IP.

## What is not here

Server-rendered pages: `crystals:web/template`, `web/form`, `web/html` and
`web/redirect`. They are shipped and frozen, and no example program uses them
yet — see [`../FIXES-WANTED.md`](../FIXES-WANTED.md).
