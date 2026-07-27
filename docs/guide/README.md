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

### 02-build-notes — build a real service, one step at a time

Narrates two programs the build check compiles: `druse-crystals/examples/notes`,
a CRUD service run against a real PostgreSQL, and `examples/session`, a complete
signed-in application.

**These chapters are JSON-shaped, not server-rendered.** The program specifies a
server-rendered build-along — pages, forms, redirects — and no reference program
for it exists yet. Writing those chapters means typing untested code, which
`STYLE.md` §6 forbids. The gap is recorded in
[`FIXES-WANTED.md`](FIXES-WANTED.md).

| Page | Answers |
|---|---|
| [`01-nothing-to-hello.md`](02-build-notes/01-nothing-to-hello.md) | How do I get one process listening on a port? |
| [`02-database-and-migrations.md`](02-build-notes/02-database-and-migrations.md) | How do I get a schema and a pool, and why does the server never migrate itself? |
| [`03-handlers-and-validation.md`](02-build-notes/03-handlers-and-validation.md) | What shape does every handler repeat? |
| [`04-listing-patch-and-failure.md`](02-build-notes/04-listing-patch-and-failure.md) | How do I page a list, express a three-state PATCH, and map a database failure to a status? |
| [`05-sessions-and-login.md`](02-build-notes/05-sessions-and-login.md) | How do I sign a user in, know who they are, and stop a forged request? |

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

### 05-recipes — one problem, one answer

For a reader who already knows Druse and wants the answer, not the teaching.

| Page | Answers |
|---|---|
| [`error-responses.md`](05-recipes/error-responses.md) | Which responder do I call, and which errors do I get for free? |
| [`read-a-query-parameter.md`](05-recipes/read-a-query-parameter.md) | Four extractors — which one, and what happens when the parameter is missing? |
| [`who-is-the-user.md`](05-recipes/who-is-the-user.md) | How do I write the `who` helper without corrupting the subject? |
| [`write-a-middleware.md`](05-recipes/write-a-middleware.md) | How do I run code around a handler, and guard a route? |
| [`test-a-handler.md`](05-recipes/test-a-handler.md) | How do I test without a socket? |
| [`stream-a-response.md`](05-recipes/stream-a-response.md) | How do I send a response I cannot buffer whole? |
| [`accept-a-file-upload.md`](05-recipes/accept-a-file-upload.md) | How do I take a file, in memory or spooled to disk? |
| [`observe-the-framework.md`](05-recipes/observe-the-framework.md) | What failed, how often, and am I draining? |
| [`serve-a-browser-app.md`](05-recipes/serve-a-browser-app.md) | CORS, static files, security headers, and the real client IP behind a proxy? |

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

**Every one of the 82 core symbols is taught on a page of this guide**, not
merely listed here. `build/check_docs_coverage.py` enforces that, and it
ignores this file so a mention in the map cannot count as coverage.

Named is still not the same as narrated. Streaming, uploads, CORS, static
files and the proxy surface have a recipe rather than a build-along chapter,
because no build-along reaches them yet.

The reference remains the place to look up a signature. `docs/ai-context.md`
is the complete list, and if a symbol is not there it does not exist — do not
guess a name.

**Crystals packages never named here.** Go to
`druse-crystals/docs/crystals.md`:

`auth/api_key_postgres`, `idempotency_postgres`, `jobs_postgres`,
`rate_limit_memory` and `rate_limit_postgres` — 5 of 44 packages, 18 public
symbols. All five are storage backends behind a `Store` contract the guide does
cover, so the contract is taught even where the backend is not.

Being *named* is not being *taught*. `storage_s3`, `web/html`, `web/redirect`
and `rate_limit` appear only in a table or a single sentence.

**Sections planned and not written**, per `planning/documentation-program.md`:

- `02-build-notes/` server-rendered chapters — first page, forms and CSRF in a
  form, authorization, Docker. Blocked on a reference program.
- `03-build-intake/` — the asynchronous, worker-shaped stack: jobs, mail,
  storage, idempotency, SSE, API keys.
- `friction-map.md` — blocked. It is built from `druse-miniature/FRICTION.md`,
  which is not reachable from this repository.

Until they exist, `docs/quick-start.md` is the build-along and
`docs/canonical-patterns.md` is the recipe list.
