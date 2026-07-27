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

## Start here

**[Quickstart](00-quickstart.md)** — a running server in five minutes. You type
it; you do not read about it.

## By subject

The page you want when you arrive with a question.

| Page | Answers |
|---|---|
| [`routing.md`](03-subjects/routing.md) | The five verbs, parameters, why static beats parametric, and groups, without a `group` helper |
| [`request.md`](03-subjects/request.md) | Every way to read input, which extractors answer for you, and the lifetime rule over all of it |
| [`response.md`](03-subjects/response.md) | Sending output, the status enum, headers, and the two things with no limit |

## By task — recipes

One problem, one answer. For a reader who wants the answer, not the teaching.

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

## Build something real

A service with a database, then one with users signed in. Both narrate programs
the build check compiles: `druse-crystals/examples/notes` against a real
PostgreSQL, and `examples/session`.

| Page | Answers |
|---|---|
| [`01-nothing-to-hello.md`](02-build-notes/01-nothing-to-hello.md) | The running process, and the four behaviours that surprise people |
| [`02-database-and-migrations.md`](02-build-notes/02-database-and-migrations.md) | A schema and a pool, and why the server never migrates itself |
| [`03-handlers-and-validation.md`](02-build-notes/03-handlers-and-validation.md) | The shape every handler repeats |
| [`04-listing-patch-and-failure.md`](02-build-notes/04-listing-patch-and-failure.md) | Paging, a three-state PATCH, and one place for database failure |
| [`05-sessions-and-login.md`](02-build-notes/05-sessions-and-login.md) | Signing a user in, knowing who they are, stopping a forged request |

**These are JSON-shaped, not server-rendered.** No reference program exists for
the server-rendered stack yet, and writing those chapters would mean typing
untested code — see [`FIXES-WANTED.md`](FIXES-WANTED.md).

## The rules no single package can teach

This is the half a reference cannot give you. Manual memory management makes
these load-bearing.

| Page | Answers |
|---|---|
| [`ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | **Read this one.** Who owns these bytes, and how long do they stay valid? |
| [`result-vocabularies.md`](04-rules/result-vocabularies.md) | Five packages report success five different ways. Which is which? |
| [`configuration.md`](04-rules/configuration.md) | How do I configure a package without listing every field? |
| [`bytes-and-encoding.md`](04-rules/bytes-and-encoding.md) | Who allocates a decoded string, and who frees it? |
| [`composition-and-cost.md`](04-rules/composition-and-cost.md) | What does `mount` copy, and what does a middleware cost per request? |

## Why it is like this

Read when you want the reasoning, not the instruction.

| Page | Answers |
|---|---|
| [`what-this-is.md`](01-concepts/what-this-is.md) | What does Druse do, and what shape of program does it produce? |
| [`what-it-refuses.md`](01-concepts/what-it-refuses.md) | No ORM, no DI, no panic recovery — and what each refusal costs me |
| [`core-and-crystals.md`](01-concepts/core-and-crystals.md) | The boundary between the two repositories, and vendoring that works |
| [`shape-of-an-application.md`](01-concepts/shape-of-an-application.md) | Where services live, and what `main` looks like |
| [`FIXES-WANTED.md`](FIXES-WANTED.md) | Which hazards here should be an API change instead of a warning? |

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

**Subjects with no page yet**, where Echo-style guides would have one:
templates, cookies, and sessions as a subject rather than a build chapter.
Templates and cookies are blocked on the same missing example program.
