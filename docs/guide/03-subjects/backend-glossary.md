# Backend vocabulary, mapped

**Assumes:** nothing.

The words a backend developer arrives with, and where each one lives here — or
whether it lives here at all.

If you learned backend on Node, Spring or Django, read the last section first.
It is the one that saves you an afternoon.

## Request handling

| Term | Here |
|---|---|
| Endpoint, route | [`routing.md`](routing.md) |
| Request, headers, body | [`request.md`](request.md) |
| Response, status code | [`response.md`](response.md) |
| Serialization, deserialization | [`binding.md`](binding.md) — `web.body` in, `web.ok` out |
| Schema, validation | `crystals:validate`, and [`binding.md`](binding.md) |
| Middleware | [`../05-recipes/write-a-middleware.md`](../05-recipes/write-a-middleware.md) |
| Context | [`context-and-state.md`](context-and-state.md) — two typed slots, not a bag |
| CRUD | [`../06-cookbook/crud.md`](../06-cookbook/crud.md) |
| Pagination, filtering, sorting, search | [`../05-recipes/paginate-a-list.md`](../05-recipes/paginate-a-list.md), [`../05-recipes/filter-sort-and-search.md`](../05-recipes/filter-sort-and-search.md) |
| Upload multipart, content type | [`../05-recipes/accept-a-file-upload.md`](../05-recipes/accept-a-file-upload.md) |

## Structure

| Term | Here |
|---|---|
| DTO | [`binding.md`](binding.md) — a wire struct, kept separate from the model |
| Entity, model | Your own type. [`project-layout.md`](project-layout.md) |
| Repository | The `Store` contract idiom — a struct of procedures over a backend |
| Service, use case, business rule | [`project-layout.md`](project-layout.md) |
| Handler, controller | The same thing here. `proc(ctx: ^web.Context)` |
| Separation of concerns, coupling, cohesion | [`../06-cookbook/clean-layers.md`](../06-cookbook/clean-layers.md) |
| Migration | [`../02-build-notes/02-database-and-migrations.md`](../02-build-notes/02-database-and-migrations.md) |
| Soft delete, timestamps, audit | [`../05-recipes/soft-delete-and-audit.md`](../05-recipes/soft-delete-and-audit.md) |

## Security

| Term | Here |
|---|---|
| Authentication, session | [`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md) |
| Authorization, RBAC, permission | [`../05-recipes/authorization-and-roles.md`](../05-recipes/authorization-and-roles.md) |
| Password hash, salt | [`../05-recipes/store-a-password.md`](../05-recipes/store-a-password.md) |
| Token, API key | [`../05-recipes/api-keys.md`](../05-recipes/api-keys.md) |
| Cookie | [`cookies.md`](cookies.md) |
| CSRF | [`../05-recipes/protect-a-form-with-csrf.md`](../05-recipes/protect-a-form-with-csrf.md) |
| CORS | [`../05-recipes/serve-a-browser-app.md`](../05-recipes/serve-a-browser-app.md) |
| XSS | [`templates.md`](templates.md) — escaping by position |
| SQL injection | [`../05-recipes/filter-sort-and-search.md`](../05-recipes/filter-sort-and-search.md) — parameters, never concatenation |
| Rate limiting, brute force | [`../05-recipes/rate-limit.md`](../05-recipes/rate-limit.md) |
| Secret, environment variable | [`../04-rules/configuration.md`](../04-rules/configuration.md) — `config.var_secret` |

## Running it

| Term | Here |
|---|---|
| Connection pool | [`../02-build-notes/02-database-and-migrations.md`](../02-build-notes/02-database-and-migrations.md) |
| Timeout, retry, backoff | [`../05-recipes/timeouts-retries-and-backoff.md`](../05-recipes/timeouts-retries-and-backoff.md) |
| Queue, worker, job, producer, consumer | [`../05-recipes/run-background-jobs.md`](../05-recipes/run-background-jobs.md) |
| Idempotency | [`../05-recipes/idempotent-requests.md`](../05-recipes/idempotent-requests.md) |
| SSE | [`../05-recipes/server-sent-events.md`](../05-recipes/server-sent-events.md) |
| Log, metric, observability | [`../05-recipes/observe-the-framework.md`](../05-recipes/observe-the-framework.md) |
| Health, readiness, liveness | [`../06-cookbook/config-and-health.md`](../06-cookbook/config-and-health.md) |
| Graceful shutdown | [`../06-cookbook/graceful-shutdown.md`](../06-cookbook/graceful-shutdown.md) |
| Deploy, container, CI | `docs/operations.md`, `druse-crystals/docs/deployment.md` |

## What this stack does not have

Not oversights. Read the reason before you look for a workaround.

| You are looking for | Instead |
|---|---|
| **JWT, access/refresh token** | `auth/session` is a **server-side** session, because revocation is the point. No package signs claims. Open question, no decision — see [`../FIXES-WANTED.md`](../FIXES-WANTED.md) |
| **Dependency injection, IoC container** | A field in your `App_State`, wired in `main` (ADR-C003). The concept applies; the container does not |
| **ORM, Active Record** | Explicit SQL, plus `db/sqlcheck` to verify it against a real schema |
| **Panic recovery middleware** | Cannot exist — Odin has no recoverable panic (ADR-020). Run under a supervisor |
| **Cache, Redis** | No package. Nothing here caches for you |
| **Circuit breaker** | No package. A counter in `App_State` and a check before the call |
| **Message broker, Kafka, dead letter queue** | No package. `jobs` is a database-backed queue |
| **Cron, scheduler** | `jobs` can delay a job. There is no cron |
| **WebSocket, gRPC, GraphQL** | No package. The transport is HTTP/1.1 |
| **OpenAPI, Swagger** | No generator. The contract is your tests |
| **Distributed tracing** | `web.request_id` and nothing else. No spans, no propagation |
| **Mocks** | Odin has no dynamic interface. Use a second `Store` — `session_memory` beside `session_postgres` |

## The pattern in that list

Most absences are one of three things: **the language cannot** (panic recovery),
**a decision refused it** (ORM, DI container), or **nobody has built it yet**
(cache, tracing).

The third kind is a Crystal somebody could write. The first two are not.
