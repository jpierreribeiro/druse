# CORS, static files and uploads

The things a service answering a browser needs, in one program.
`examples/08-table-stakes`, complete.

## Server

<!-- druse:begin examples/08-table-stakes/main.odin -->
```odin
package main

import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	// CORS is CONFIGURATION, not middleware, because the headers have to reach
	// the automatic 404 and the driver's 500 as well — a browser that cannot
	// read your error shows the user a blank page.
	//
	// The unsafe combinations are refused HERE, at boot: `*` with credentials,
	// `*` beside named origins, `*` in the header list with credentials. The
	// application will not start rather than share one origin's authenticated
	// data with another.
	web.cors(
		&app,
		web.Cors_Options {
			origins = {"https://app.example.com"},
			headers = "Content-Type, Authorization",
			credentials = true,
			max_age = 600,
		},
	)

	// A static mount OWNS its prefix: everything under /assets is answered from
	// the directory or answered 404, never falling through to a route. Traversal,
	// percent encoding, dotfiles and symlinks are all refused.
	//
	// Responses are buffered whole, so a file costs its size in memory. That is
	// what `max_file_size` is for, and why it has a default rather than being
	// optional.
	web.static(&app, "/assets", "public", web.Static_Options{index = "index.html"})

	web.post(&app, "/upload", upload)

	web.serve(&app, 8080)
}

upload :: proc(ctx: ^web.Context) {
	title, has_title := web.form_field(ctx, "title")
	if !has_title {
		web.bad_request(ctx, "title is required")
		return
	}

	file, has_file := web.form_file(ctx, "doc")
	if !has_file {
		web.bad_request(ctx, "doc is required")
		return
	}

	// `file.filename` is the CLIENT'S CLAIM. Never use it as a path: it may
	// contain separators, and the framework does not sanitise it because it
	// never uses it. Generate your own storage name.
	//
	// `file.bytes` is a view over the request body and does not outlive this
	// call. Copy what you keep.
	_ = file.bytes

	web.text(ctx, .OK, title)
}
```
<!-- druse:end -->

## Run

```text
odin run examples/08-table-stakes -collection:druse=.
```

## What to notice

**CORS covers every response**, including the automatic 404 and the driver's
500. A browser that cannot read your error shows the user a blank page.

**Unsafe CORS combinations are refused at boot**, not at request time: `*` with
credentials, `*` beside named origins, `*` in the header list with credentials.
The application will not start rather than share one origin's authenticated
data with another.

**A static mount owns its prefix.** Everything under `/assets` is answered from
the directory or answered `404` — it never falls through to a route. Traversal,
percent encoding, dotfiles and symlinks are all refused.

**Static responses are buffered whole**, so a file costs its size in memory.
That is what `Static_Options.max_file_size` is for, and why it has a default
rather than being optional.

**In a multipart handler every part is a view over the request body.** Copy
what must outlive the handler.

## Next

[`../05-recipes/serve-a-browser-app.md`](../05-recipes/serve-a-browser-app.md)
— the same subjects, plus the real client IP behind a proxy.
