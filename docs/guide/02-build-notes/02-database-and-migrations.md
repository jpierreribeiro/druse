# 2 — A database, and a schema that migrates itself never

**Assumes:** [`01-nothing-to-hello.md`](01-nothing-to-hello.md).

The program from here on is `druse-crystals/examples/notes`. It is a real CRUD
service the build check compiles and runs against a real PostgreSQL.

Two ideas in this chapter. The schema is a separate deploy step. The pool is a
service your application owns.

## The schema

One migration, two files, in `migrations/`:

```sql
-- 0001_notes.up.sql
CREATE TABLE notes (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug       text NOT NULL UNIQUE,
    title      text NOT NULL,
    body       text,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

```sql
-- 0001_notes.down.sql
DROP TABLE notes;
```

`body` is nullable and the others are not. That difference is load-bearing all
the way out to the JSON, and chapter 3 shows where.

## Apply it with the runner, not the server

`web.serve` has no migration step. It cannot reach one (ADR-C008). Migration is
a separate executable:

```sh
env MIGRATE_DIR=examples/notes/migrations \
    MIGRATE_HOST=127.0.0.1 MIGRATE_PORT=5432 \
    MIGRATE_USER=... MIGRATE_PASSWORD=... MIGRATE_DB=... \
    ./migrate up
```

The commands are:

| Command | What it does |
|---|---|
| `new <name>` | Scaffold a timestamped up/down pair |
| `status` | What is applied, pending, dirty |
| `dry-run` | What `up` would apply, applying nothing |
| `up [--step N]` | Apply pending migrations |
| `down` | Revert the most recently applied |
| `inspect` | Everything not cleanly applied, with next steps |
| `repair <id> --applied\|--reverted` | Resolve one dirty row, after you look at the schema |

**Start at `inspect` when something is wrong.** It is the command written for
the moment you are in an incident and nothing has told you what to type.

**Set `MIGRATE_DIR` to an absolute path.** A vendored tree carries its own
`migrations/` at its root, and a relatively resolved `MIGRATE_DIR` can find that
one instead of yours. See
[`../01-concepts/core-and-crystals.md`](../01-concepts/core-and-crystals.md).

## Why the deploy has two steps

A server that migrates at boot migrates once per replica, at the same moment,
under load. The failure mode is a half-applied schema during a rolling deploy.

What you get in exchange is a fail-closed contract:

- Migration ids are immutable and ordered.
- An applied migration whose file content changed is **refused by checksum**
  before any new DDL runs.
- A PostgreSQL advisory lock means one runner applies at a time.
- Each migration runs in its own transaction unless it opts out with
  `no_transaction`.
- A failed or uncertain migration is recorded **dirty**, and the database is
  never reported clean until an operator resolves it.

`down` exists. It is never presented as guaranteed data recovery.

## The pool is yours

The application owns the pool. The framework never opens, migrates or closes a
database:

```odin
package notes

import pg "crystals:db/postgres"

App_State :: struct {
	db: pg.Pool,
}

Config :: struct {
	database: pg.Config,
	pool:     pg.Pool_Config,
}

application_init :: proc(cfg: Config) -> (App_State, bool) {
	pc := cfg.pool
	pc.conn = cfg.database
	pool, err := pg.pool_open(pc)
	if pg.is_err(err) {
		return App_State{}, false
	}
	return App_State{db = pool}, true
}

application_destroy :: proc(st: ^App_State) {
	pg.pool_close(&st.db)
}
```

That is `examples/notes/app.odin`, complete.

`application_init` returns **before any listener opens**. A bad database
configuration is a clean startup failure — log it and exit. It is never a
surprise mid-request.

## Wiring it in `main`

```odin
	st, ok := notes.application_init(cfg)
	if !ok {
		fmt.eprintln("notes: could not open the database pool; check the configuration")
		os.exit(1)
	}
	defer notes.application_destroy(&st)

	app := web.app_with_state(&st)
	defer web.destroy(&app)

	liveness := health.routes()
	web.mount(&app, "/health", &liveness)
	web.destroy(&liveness)

	notes.register(&app)

	web.serve(&app, serve_port)
```

Read the `defer` order. The pool opens before the application and closes after
it, because deferred calls run last-registered-first. A handler must not reach a
closed pool while the server drains.

`health.routes()` returns a detached router. You mount it and then destroy your
copy — [`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md)
explains why both lines are there.

## Size the pool below the handler capacity

```odin
	pool = pg.Pool_Config{min_conns = 1, max_conns = 8, acquire_timeout_ms = 2_000},
```

`max_conns` stays **below** the framework's handler-lane capacity. That is
deliberate, and it is the most easily missed line in the whole program.

If the pool could consume every lane, a saturated database would take health
checks and graceful shutdown down with it. Sized below, a saturated pool fails
fast for database work while `/health` and shutdown stay live.

## Connections are secure by default

```odin
		database = pg.Config {
			host                 = env("NOTES_DB_HOST", "127.0.0.1"),
			port                 = u16(db_port),
			user                 = env("NOTES_DB_USER"),
			password             = env("NOTES_DB_PASSWORD"),
			database             = env("NOTES_DB_NAME"),
			ssl_mode             = ssl,
			allow_plaintext      = env("NOTES_ALLOW_PLAINTEXT") == "1",
			statement_timeout_ms = 30_000,
		},
```

`ssl_mode` defaults to `.Verify_Full`, with SCRAM. Plaintext requires two
opt-ins at once: `allow_plaintext` and `ssl_mode = .Disable`. Use that only for
a local test database.

`statement_timeout_ms` bounds a query server-side. Set it. A query with no
deadline is a connection you cannot get back.

## Run it

```sh
# 1. migrate
env MIGRATE_DIR=examples/notes/migrations ... ./migrate up

# 2. serve
env NOTES_PORT=8080 NOTES_DB_HOST=127.0.0.1 ... ./notes-server
```

Two commands, in that order, every deploy.

## Next

[`03-handlers-and-validation.md`](03-handlers-and-validation.md) — the five
handlers, strict input, and SQL `NULL` that survives to the JSON.
