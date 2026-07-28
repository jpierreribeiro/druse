# Installation

**Assumes:** nothing.

There is no package manager, no registry, no generator and no runtime plugin
mechanism. You point the compiler at two directories.

## What you need

The pinned Odin compiler. The exact build is in `odin-version.txt`, and
`druse-crystals/COMPATIBILITY.md` names the commit each side was verified
against.

For Crystals' PostgreSQL packages: system `libpq`, version 16 or newer.

## Two collections, two flags

```sh
odin build ./cmd/api \
  -collection:druse=./vendor/druse \
  -collection:crystals=./vendor/druse-crystals
```

That is what makes `import web "druse:web"` and `import pg
"crystals:db/postgres"` resolve.

Druse alone needs only the first flag.

## Vendoring, the way that works

The obvious command is wrong, and it fails quietly:

```sh
git clone https://.../druse vendor/druse    # WRONG — embedded repository
```

Git records a gitlink rather than content. Your commit captures a pointer your
colleagues cannot resolve, and a fresh clone of your application produces an
empty `vendor/druse`.

Copy the tree without its `.git`, and record the commit:

```sh
git clone https://.../druse /tmp/druse
git -C /tmp/druse checkout <commit-from-COMPATIBILITY.md>
git -C /tmp/druse rev-parse HEAD > vendor/druse.commit
rm -rf /tmp/druse/.git
cp -a /tmp/druse vendor/druse
git add vendor/druse vendor/druse.commit
```

Or use a submodule deliberately, and tell your team it is one.

## The second vendoring trap

A vendored tree carries its own `migrations/` directory at its root. A
migration runner resolving `MIGRATE_DIR` relatively can find **that** one
instead of yours.

**Set `MIGRATE_DIR` to an absolute path.**

## Pin commits, not branches

Compatibility is measured against commits (ADR-C005).
`druse-crystals/COMPATIBILITY.md` names the exact Druse commit, the Odin
release and commit, the platform, and the libpq ABI it was verified against.

`Verified` there means the full build check passed against that exact tree. A
floating branch is not a compatibility declaration.

## Check it works

```sh
odin run examples/01-hello-world -collection:druse=.
```

```sh
$ curl http://localhost:8080/ping
pong
```

## Next

[`../00-quickstart.md`](../00-quickstart.md) — write your own, in five minutes.
