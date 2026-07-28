# Templates

**Assumes:** [`response.md`](response.md). Package `crystals:web/template`.

A template engine whose whole reason to exist is **position-aware escaping**. A
single escape function applied everywhere is correct in one position and
exploitable in the others.

## Compile a set, then render

```odin
	s := tpl.set_make(context.temp_allocator)
	defer tpl.set_destroy(&s)

	if e := tpl.add(&s, "page", source); tpl.is_err(e) {
		return
	}

	out, re := tpl.render(&s, "page", data, allocator = context.temp_allocator)
```

`add` compiles and names one template. `render` runs it. `set_destroy` frees the
set.

**Call `tpl.verify(&s)` after you add everything.** It checks that every partial
resolves, at startup, rather than at the first request that needs one:

```odin
	if e := tpl.verify(&s); tpl.is_err(e) {
		os.exit(1)
	}
```

## Building the data

Values are constructed, not reflected:

```odin
tpl.text(s)     // a string
tpl.num(n)      // a number
tpl.flag(b)     // a boolean
tpl.list(vs)    // a sequence
tpl.object({{"title", tpl.text("hi")}})
```

```odin
	data := tpl.object({{"title", tpl.text("hi")}})
```

There is no struct-tag mapping. You say what goes in, so nothing leaks by
accident.

## Escaping follows position

```odin
	evil := tpl.object({{"v", tpl.text(`" onmouseover="alert(1)`)}})
```

The same value in `<p>{{ v }}</p>`, in `<a href="{{ v }}">` and inside a
`<script>` is escaped by three different rules. The engine picks the rule from
where the placeholder sits.

This is why you do not build HTML with string concatenation here.

## Partials and layouts

```odin
	tpl.add(&s, "layout", "<html><body>{{> body }}</body></html>")
	tpl.add(&s, "body",   "<h1>{{ title }}</h1>")
	tpl.verify(&s)

	out, e := tpl.render(&s, "layout", tpl.object({{"title", tpl.text("hi")}}))
	// <html><body><h1>hi</h1></body></html>
```

`{{> name }}` includes another template.

**A partial may not appear inside a tag.** `<a href="{{> frag }}">` is refused
at compile time with `Unsafe_Context`: a partial is HTML pasted in, escaped by
rules chosen when *it* was compiled, in a context it could not see.

**A cycle terminates.** A partial that includes itself fails rendering with
`Partial_Too_Deep`, not with the stack.

## Everything is bounded

`MAX_TEMPLATE_BYTES`, `MAX_NODES`, `MAX_BLOCK_DEPTH`, `MAX_NAME_BYTES`,
`MAX_PARTIAL_DEPTH`, `MAX_OUTPUT_BYTES`, `MAX_EACH_ITEMS`, `MAX_SLOTS`.

A template is input. Bounds are what keep a large one from becoming a denial of
service.

## Sending it

```odin
	html.respond(ctx, .OK, out)
```

`crystals:web/html` also exposes the escapers directly — `escape`,
`escape_attribute`, `escape_url`, `escape_url_component`, `escape_script`,
`escape_css` — for the cases where you assemble markup yourself. Pick the one
that matches the position, the same way the engine does.

`html.url_scheme_is_safe` rejects `javascript:` and friends before you put a
user value in an `href`.
