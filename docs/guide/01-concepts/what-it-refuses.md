# What it refuses

**Assumes:** [`what-this-is.md`](what-this-is.md).

Five things a reader coming from another framework will look for and not find.
Each refusal is recorded, each has a reason, and each has a cost you pay. This
page states the cost too. A refusal defended only by its benefits is marketing.

## No ORM

SQL is explicit. Parameters, transactions, migrations and teardown are all
visible in your code.

```odin
r, e := pg.query_one(&c, "user_by_email", `
	SELECT id, password_hash FROM users WHERE email = $1
`, {pg.arg_text(email)})
```

**Why.** An ORM has to model your schema a second time, in a second language,
and the two copies drift. It also hides which statement runs, which is the one
thing you need when a query is slow.

**What it costs you.** You write every query by hand. There is no
`User.find_by_email`. A schema change means finding every query that touches
the column, and the compiler cannot find them for you, because they are
strings.

**What is offered instead.** `db/sqlcheck` prepares each named query against a
real migrated database and compares what PostgreSQL infers against what you
declared. It inspects. It generates nothing. A query PostgreSQL cannot prepare
statically is reported `Unchecked`, never falsely certified (ADR-C010).

## No dependency injection, and no service registry

There is no container, no registry, no package global and no import side
effect. Pools, clients and caches live in a struct you declare and hold in
`main` (ADR-C003).

**Why.** A registry answers "where did this pool come from?" with a runtime
lookup that can fail. A struct field answers it with a type.

**What it costs you.** Every service is threaded explicitly from `main` to the
handler that needs it. A handler four layers down that suddenly needs the mail
client means adding a field and passing it. There is no ambient way to reach
one.

See [`shape-of-an-application.md`](shape-of-an-application.md) for the pattern
that keeps this from becoming a long parameter list.

## No automatic migration at boot

Migration is a separate executable, `cmd/migrate`. The HTTP server cannot reach
it: `web.serve` has no migration step (ADR-C008).

**Why.** A server that migrates at boot migrates once per replica, at the same
moment, under load. The failure mode is a half-applied schema during a rolling
deploy.

**What it costs you.** Your deploy has two steps rather than one. You run the
migration, and then you start the server. A container image that starts and
serves in a single command does not work here.

The contract in exchange is fail-closed. Migration ids are immutable and
ordered. An applied migration whose file content changed is refused by checksum
before any new DDL runs. An advisory lock ensures one runner applies at a time.
A failed migration is recorded dirty, and the database is never reported clean
until an operator resolves it.

## No panic recovery, and there never will be

A fault in a handler aborts the process. A panic, a failed assertion, an
out-of-bounds index or a nil dereference takes the server down. The client sees
an empty reply.

**Why.** Odin has no recoverable panic (ADR-020). This is not a decision the
framework can reverse. There is no `web.recovery`, there is no recovery
middleware, and no amount of wrapping produces one.

**What it costs you.** One bad index in one handler stops every in-flight
request on that process. You must run under a supervisor with
`Restart=always`, and you must run more than one replica.

**What is guaranteed instead**, and it is the half that people miss: a handler
that returns *without committing a response* is finalized to the standardized
`internal_error` 500. That holds under `web.serve` and `web.test_request`
alike, and for the hundredth fault as for the first. Returning early is safe.
Faulting is not.

## No untyped request context

`ctx` is not an extension bag. There is no dynamically keyed store, and no
`context.WithValue` equivalent.

Request-scoped state is exactly one typed value, `web.request_state`. A
middleware computes it and the handler reads it back.

**Why.** An untyped bag turns a compile error into a runtime `nil`, and it
makes the set of things in flight unknowable.

**What it costs you.** Two independent middlewares cannot each stash their own
value. If you need both, you declare one struct that holds both, and that
struct is a coupling between two otherwise unrelated pieces of code.

## The pattern behind all five

Every refusal trades convenience at the moment of writing for legibility at the
moment of debugging.

That trade is right for a service you operate, and it is wrong for a script you
run once. If you are writing the second thing, this framework will annoy you,
and it is honest to say so here rather than let you find out in a week.

## Next

- [`core-and-crystals.md`](core-and-crystals.md) — the boundary, and vendoring.
