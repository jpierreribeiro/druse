# Project layout

**Assumes:** [`context-and-state.md`](context-and-state.md).

**This is an indication, not a rule.** Druse imposes no layout. A three-route
service is fine in one file, and pretending otherwise is how a small program
gets a directory tree it does not need.

What follows is what tends to work once a service outgrows one screen.

## The shape

```text
backend/
  cmd/
    api/            one executable
    worker/         another, sharing the code below
  internal/
    models/         what the things ARE
    dto/            what crosses the wire
    store/          where things live
    services/       the rules
    handlers/       HTTP in, HTTP out
    routes/         the URL shape
    auth/           identity
    config/         reading the environment
  migrations/       the schema, applied by cmd/migrate
```

Anyone who has seen a Go backend recognises this. It transfers because the idea
is not Go's: **each directory answers one question, and the dependencies point
one way.**

## The one rule that makes it work

```text
handlers → services → store → models
```

**Never the other way.** A service that imports a handler, or a model that
knows a status code, has lost the property the layout exists for.

The test is simple. If `services/` mentions `web.Context`, a status code, or a
column name, something is in the wrong file.

## What each layer is for

| Layer | Holds | Must not mention |
|---|---|---|
| `models` | The domain type and its own rules | HTTP, JSON, SQL |
| `dto` | Wire structs, with `json:"..."` tags | Business rules |
| `store` | Reads and writes | Status codes |
| `services` | Every rule the application has | `web.Context` |
| `handlers` | Input, one service call, one status | Rules |
| `routes` | Registration only | Handler bodies |

**Keep `dto` separate from `models`.** A `Link` has a `hits` count the client
does not set; a `Create_Link` has no `hits` field at all, so a client cannot
invent one. One struct for both is how a caller assigns its own primary key.

## In Odin, a layer can be a file

A directory is a package in Odin, and a package is many files. For a service of
a few hundred lines, **one file per layer in one package** gives you the same
separation with none of the import ceremony:

```text
cmd/api/
  main.odin       composition
  routes.odin
  handlers.odin
  dto.odin
  service.odin
  store.odin
  models.odin
```

Split into real packages when a layer gets its own tests, its own reviewers, or
a second consumer. Not before.

`druse-crystals/examples/notes` uses this shape.

## Where Druse fits

Only two layers touch the framework. `handlers` imports `druse:web`; `routes`
imports it to register. Everything below is ordinary Odin that would compile in
a program with no server in it.

That is the payoff: **your rules are testable without a socket**, and swapping
`store` for one over `crystals:db/postgres` changes nothing above it.

## The composition root stays in `main`

There is no container and no registry, so `main` creates every service, puts it
in one `App_State`, and destroys it. See
[`context-and-state.md`](context-and-state.md).

That is not a limitation of the layout — it is what makes the layout legible.
A reader answering "what does this process own?" reads one procedure.

## See it

[`../06-cookbook/clean-layers.md`](../06-cookbook/clean-layers.md) — a URL
shortener, one file per layer, complete.
