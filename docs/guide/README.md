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

1. **[Odin in ten minutes](00-odin-in-ten-minutes.md)** — the eight language
   constructs this guide uses. Skip it if you know Odin.
2. **[Quickstart](00-quickstart.md)** — a running server in five minutes. You
   type it; you do not read about it.
3. **[Installation](03-subjects/installation.md)** — the two flags, and
   vendoring that survives a fresh clone.

You do not need to know Odin to start. You need about eight things, and page 1
is all of them.

## Guide — by subject

The page you want when you arrive with a question.

| Page | |
|---|---|
| [Routing](03-subjects/routing.md) | The five verbs, parameters, static over parametric, groups |
| [Request](03-subjects/request.md) | Every way to read input, and the lifetime rule over all of it |
| [Response](03-subjects/response.md) | Sending output, the status enum, headers, the two things with no limit |
| [Binding](03-subjects/binding.md) | Body into a typed value, strict decoding, then validation |
| [Context and state](03-subjects/context-and-state.md) | The two typed slots: application-wide and per-request |
| [Templates](03-subjects/templates.md) | Position-aware escaping, partials, layouts |
| [Forms and redirects](03-subjects/forms-and-redirects.md) | Reading a form post, and why the answer is always a 303 |
| [Cookies](03-subjects/cookies.md) | Reading, setting, and the one constructor for a session cookie |
| [Limits and shutdown](03-subjects/limits-and-shutdown.md) | What bounds the server, what is off by default, how it stops |
| [Project layout](03-subjects/project-layout.md) | How to arrange files once a service outgrows one screen — an indication, not a rule |
| [Static files](05-recipes/serve-a-browser-app.md) | Serving a directory, CORS, security headers, real client IP |
| [Testing](05-recipes/test-a-handler.md) | Running a request through real routing, without a socket |

## Cookbook — complete programs

A whole program you can copy, run and curl. Every line is extracted from an
example the build check compiles — `build/gen_cookbook.py` inlines it, and the
gate fails if a page drifts from its source.

| Page | |
|---|---|
| [Hello World](06-cookbook/hello-world.md) | The smallest complete server |
| [CRUD](06-cookbook/crud.md) | Six routes: list, read, create, replace, update, delete |
| [Custom middleware](06-cookbook/custom-middleware.md) | Running code around a handler, and a guard that short-circuits |
| [Application state](06-cookbook/app-state.md) | One typed value, created once, read anywhere |
| [Graceful shutdown](06-cookbook/graceful-shutdown.md) | A signal handler, drain, and the readiness probe |
| [Config and health](06-cookbook/config-and-health.md) | Environment configuration, liveness and readiness |
| [Path and query parameters](06-cookbook/path-and-query-params.md) | Static beating parametric, and why `?limit=abc` is a 400 |
| [Route groups](06-cookbook/route-groups.md) | A group as a value, and the one-route guard |
| [Authentication](06-cookbook/authentication.md) | A bearer gate and a typed lookup, both application code |
| [CORS, static and uploads](06-cookbook/cors-static-and-uploads.md) | What a browser-facing service needs, in one program |
| [A layered service](06-cookbook/clean-layers.md) | A URL shortener with one file per layer, and dependencies pointing one way |

## Recipes — by task

One problem, one answer. These show the calls that matter, not a whole program
— for a program to copy, use the cookbook above.

| Page | |
|---|---|
| [Error responses](05-recipes/error-responses.md) | Which responder, and which errors you get free |
| [Query parameters](05-recipes/read-a-query-parameter.md) | Four extractors, and what missing means to each |
| [Who is the user](05-recipes/who-is-the-user.md) | The `who` helper, without corrupting the subject |
| [Write a middleware](05-recipes/write-a-middleware.md) | Running code around a handler, and guarding a route |
| [CSRF on a form](05-recipes/protect-a-form-with-csrf.md) | Issue, bind to the session, reject before anything changes |
| [Rate limiting](05-recipes/rate-limit.md) | Which key to limit by, and why memory fails behind a balancer |
| [API keys](05-recipes/api-keys.md) | Issue once, verify, scopes, revoke |
| [Idempotent requests](05-recipes/idempotent-requests.md) | A POST a client may safely retry |
| [Background jobs](05-recipes/run-background-jobs.md) | A worker, three outcomes, and at-least-once |
| [Send email](05-recipes/send-email.md) | Share the application's HTTP client, and send from a job |
| [Store a file](05-recipes/store-a-file.md) | Four operations, two backends, and the key you must validate |
| [File uploads](05-recipes/accept-a-file-upload.md) | In memory or spooled, and who owns the spool file |
| [Streaming](05-recipes/stream-a-response.md) | A response you cannot buffer whole |
| [Server-sent events](05-recipes/server-sent-events.md) | Pushing to a browser, and resuming after a reconnect |
| [Observability](05-recipes/observe-the-framework.md) | What failed, how often, and am I draining |
| [Serve a browser app](05-recipes/serve-a-browser-app.md) | CORS, static files, security headers, client IP |

## Build something real

Both narrate programs the build check compiles: `druse-crystals/examples/notes`
against a real PostgreSQL, and `examples/session`.

| Page | |
|---|---|
| [1 — Nothing to hello](02-build-notes/01-nothing-to-hello.md) | The running process, and four behaviours that surprise people |
| [2 — Database and migrations](02-build-notes/02-database-and-migrations.md) | A schema and a pool, and why the server never migrates itself |
| [3 — Handlers and validation](02-build-notes/03-handlers-and-validation.md) | The shape every handler repeats |
| [4 — Listing, PATCH, failure](02-build-notes/04-listing-patch-and-failure.md) | Paging, three-state PATCH, one place for database failure |
| [5 — Sessions and login](02-build-notes/05-sessions-and-login.md) | Signing a user in, and the borrowed subject used correctly |

## The rules no single package can teach

The half a reference cannot give you. Manual memory management makes these
load-bearing.

| Page | |
|---|---|
| [Ownership and lifetime](04-rules/ownership-and-lifetime.md) | **Read this one.** Who owns these bytes, and how long do they stay valid |
| [Result vocabularies](04-rules/result-vocabularies.md) | Five packages report success five ways. Which is which |
| [Configuration](04-rules/configuration.md) | Configuring a package without listing every field |
| [Bytes and encoding](04-rules/bytes-and-encoding.md) | Who allocates a decoded string, and who frees it |
| [Composition and cost](04-rules/composition-and-cost.md) | What `mount` copies, what a middleware costs per request |

## Why it is like this

Read for the reasoning, not the instruction.

| Page | |
|---|---|
| [What this is](01-concepts/what-this-is.md) | What Druse does, and what shape of program it produces |
| [What it refuses](01-concepts/what-it-refuses.md) | No ORM, no DI, no panic recovery — and what each costs |
| [Druse and Crystals](01-concepts/core-and-crystals.md) | The boundary between the two repositories |
| [Shape of an application](01-concepts/shape-of-an-application.md) | Where services live, and what `main` looks like |
| [Fixes wanted](FIXES-WANTED.md) | Which hazards here should be an API change instead of a warning |

## What this guide does not yet teach

Read this list before you conclude a feature does not exist. It does. This
guide has not reached it yet.

**Every one of the 82 core symbols is taught on a page of this guide**, not
merely listed here. `build/check_docs_coverage.py` enforces that, and it
ignores this file so a mention in the map cannot count as coverage.

The reference remains the place to look up a signature. `docs/ai-context.md`
is the complete list, and if a symbol is not there it does not exist — do not
guess a name.

**Crystals packages with no page.** 40 of 44 are covered. The four that are
not: `apitest` and `preflight` (both test and deploy tooling, not application
API), and `auth/api_key_postgres` and `idempotency_postgres` (storage backends
behind a `Store` contract the guide does teach). Go to
`druse-crystals/docs/crystals.md`.

**Sections planned and not written**, per `planning/documentation-program.md`:

- `02-build-notes/` server-rendered chapters — first page, forms and CSRF in a
  form, authorization, Docker. Blocked on a reference program.
- `03-build-intake/` — the asynchronous, worker-shaped stack: jobs, mail,
  storage, idempotency, SSE, API keys.
- `friction-map.md` — blocked. It is built from `druse-miniature/FRICTION.md`,
  which is not reachable from this repository.

**Still missing:** a server-rendered build-along that ties templates, forms,
cookies and CSRF into one program. The subject pages above cover each part;
what does not exist is the narrative that puts them together, and the example
program it would narrate. See [`FIXES-WANTED.md`](FIXES-WANTED.md).
