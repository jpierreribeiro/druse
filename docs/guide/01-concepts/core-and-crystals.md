# Druse and Crystals

**Assumes:** [`what-this-is.md`](what-this-is.md).

Two repositories, two collections, one direction of dependency.

## The boundary

```text
your application  →  crystals  →  public druse packages
druse             ↛  crystals
```

Read the second line carefully. Druse never imports, discovers, registers or
initializes a Crystal. There is no plugin protocol, no ABI and no import side
effect (ADR-C001).

A change to Druse requested by a Crystal is a failed Crystal design, not an
exception. That rule is what keeps the core's 82-symbol ledger from growing
every time somebody writes a package.

To remove a Crystal, remove its import and its composition calls. Nothing else
knows it was there.

## What each side holds

**Druse** holds one thing: HTTP. Routing, extractors, bodies, responses,
middleware, the error envelope, streaming, uploads, static files, CORS,
observation and graceful stop.

**Crystals** holds everything a service needs that is not HTTP. Each package
declares which of five kinds it is:

| Kind | What it owns | Example |
|---|---|---|
| **Library** | Nothing app-lived. Pure computation. | `validate` |
| **Service** | An app-lived resource, held by your struct. | `db/postgres`, `http_client` |
| **Request** | Nothing beyond one request. | `web/validate`, `web/csrf` |
| **Route** | A detached router for you to mount. | `web/health`, `web/metrics` |
| **Tool** | A separate executable. Absent from the server. | `db/migrate`, `db/sqlcheck` |

A package that fits two kinds is split.

## One vocabulary across packages

A reader who learns one package can guess the next. The names are fixed:

| Name | Meaning |
|---|---|
| `open` / `close` | Acquire and release something the package owns. |
| `stats` | A snapshot of a live resource, for observation only. |
| `routes` | A detached `web.Router` for you to mount. |
| `install` | Attach to an application's observation surface. |
| `run` | Execute a Tool's whole job once. |
| `store` | Build a contract struct over a backend. |
| `destroy` | Free a *value* that accumulated memory, not a resource. |

A package that owns nothing has no `close`. That is deliberate: a `close` that
releases nothing teaches a reader the pair is decoration.

`open`/`close`, never `init`/`destroy`, for resources. `destroy` is reserved
for a value, and `validate.destroy` is the one case.

## Two collections, two flags

Both are passed explicitly. There is no package manager, registry or generator:

```sh
odin build ./cmd/api \
  -collection:druse=./vendor/druse \
  -collection:crystals=./vendor/druse-crystals
```

## Vendoring, the way that works

The obvious command is wrong, and it fails quietly.

**Do not do this.** A plain clone into `vendor/` leaves a `.git` directory
inside your tree. Git records it as an embedded repository, not as content.
Your commit captures a gitlink your colleagues cannot resolve, and a fresh
clone of your application produces an empty `vendor/druse`:

```sh
git clone https://.../druse vendor/druse    # wrong: embedded repository
```

**Do this instead.** Clone to a scratch path, copy the tree without its `.git`,
and record the commit you copied:

```sh
git clone https://.../druse /tmp/druse
git -C /tmp/druse checkout <commit-from-COMPATIBILITY.md>
git -C /tmp/druse rev-parse HEAD > vendor/druse.commit
rm -rf /tmp/druse/.git
cp -a /tmp/druse vendor/druse
git add vendor/druse vendor/druse.commit
```

Or use a submodule, deliberately, and tell your team it is one.

**Then check for a second trap.** A vendored tree carries its own
`migrations/` directory at its root. A migration runner that resolves
`MIGRATE_DIR` relatively can find that one instead of yours. Set `MIGRATE_DIR`
to an absolute path.

## Which commit goes with which

Compatibility is measured against commits, not against `latest` (ADR-C005).
`druse-crystals/COMPATIBILITY.md` names the exact Druse commit, the Odin
release and commit, the platform, and the libpq ABI it was verified against.

`Verified` there means the full build check passed against that exact tree. A
floating branch is not a compatibility declaration.

## Next

- [`shape-of-an-application.md`](shape-of-an-application.md) — where services
  live, and what `main` looks like.
