# The Druse guide

This teaches you to build an application with Druse and Crystals. It is not the
reference. The reference is `docs/canonical-patterns.md`, `docs/ai-context.md`
and `druse-crystals/docs/crystals.md`, and this guide links into them instead
of repeating them.

**Assumes:** you can program. It does not assume you know Odin, HTTP servers or
manual memory management.

## The collection flag

Druse is used through an Odin collection. Every command that builds your
program carries one flag:

```text
-collection:druse=/path/to/druse
```

That flag makes `import web "druse:web"` resolve.

> **If your checkout still builds with `-collection:uruquim=`, use that name in
> the flag and in every `import`.** The collection is renamed to `druse` with
> the repository. Nothing else in this guide changes.

This note appears once, here. No other page repeats it.

## Which page answers which question

### 01-concepts — what this is, before you build

| Page | Answers |
|---|---|
| [`what-this-is.md`](01-concepts/what-this-is.md) | What does Druse do, and what shape of program does it produce? |
| [`what-it-refuses.md`](01-concepts/what-it-refuses.md) | Why is there no ORM, no dependency injection, no panic recovery? What does the refusal cost me? |
| [`core-and-crystals.md`](01-concepts/core-and-crystals.md) | Where is the boundary between Druse and Crystals, and how do I vendor them? |
| [`shape-of-an-application.md`](01-concepts/shape-of-an-application.md) | Where do services live? What does `main` look like? |

### 04-rules — the rules no single package can teach

Read `ownership-and-lifetime.md` before you write a handler that returns a
string. It is the largest single source of recorded defects.

| Page | Answers |
|---|---|
| [`ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | Who owns these bytes, and how long do they stay valid? |
| [`result-vocabularies.md`](04-rules/result-vocabularies.md) | Five packages report success five different ways. Which is which? |
| [`configuration.md`](04-rules/configuration.md) | How do I configure a package without listing every field? |
| [`bytes-and-encoding.md`](04-rules/bytes-and-encoding.md) | Who allocates a decoded string, and who frees it? |
| [`composition-and-cost.md`](04-rules/composition-and-cost.md) | What does `mount` copy, and what does a middleware cost per request? |

### Also here

| Page | Answers |
|---|---|
| [`FIXES-WANTED.md`](FIXES-WANTED.md) | Which hazards in this guide should be an API change instead of a warning? |

## Reading order

The number prefixes are the order. For a framework with no precedent, reading
order is part of the teaching.

If you have 20 minutes, read `01-concepts/what-this-is.md`, then
`04-rules/ownership-and-lifetime.md`. Those two prevent more defects than
everything else here.

## What this guide does not yet teach

Read this list before you conclude a feature does not exist. It does. This
guide has not reached it yet.

**Druse features with no page here.** Go to `docs/canonical-patterns.md` and
`docs/ai-context.md`:

| Subject | Where it is |
|---|---|
| Streaming and server-sent events | `web.stream`, `web.stream_send`, `web.stream_live`, `crystals:web/sse` |
| File uploads | `web.upload`, `web.enable_upload`, `web.form_file` |
| Static files | `web.static`, `web.Static_Options` |
| CORS | `web.cors`, `web.Cors_Options` |
| Security headers | `web.secure_headers` |
| Client IP behind a proxy | `web.client_ip`, `web.trust_proxies` |
| Observability and metrics | `web.observe`, `web.Framework_Event`, `crystals:web/metrics` |
| The full error envelope | `docs/errors.md` |
| Operations and shutdown | `docs/operations.md` |

The guide names 25 of the 82 core symbols. The other 57 are real, and
`docs/ai-context.md` is the complete list. If a symbol is not there, it does
not exist — do not guess a name.

**Crystals packages with no page here.** Go to
`druse-crystals/docs/crystals.md`:

`rate_limit` and its three backends, `storage_s3`, `storage_filesystem`,
`web/html`, `web/redirect`, `web/cookie`, `web/rate_limit`, `mail_memory`,
`auth/session_memory`, the four `*_postgres` backends, `apitest` and
`preflight`.

That is 17 of 44 packages, and 156 public symbols.

**Sections planned and not written**, per `planning/documentation-program.md`:

- `02-build-notes/` — the server-rendered stack, taught as one build-along.
- `03-build-intake/` — the asynchronous, worker-shaped stack.
- `05-recipes/` — one problem per file, for a reader who already knows Druse.
- `friction-map.md` — blocked. It is built from `druse-miniature/FRICTION.md`,
  which is not reachable from this repository.

Until they exist, `docs/quick-start.md` is the build-along and
`docs/canonical-patterns.md` is the recipe list.
