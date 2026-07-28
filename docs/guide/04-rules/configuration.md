# Configuration

**Assumes:** [`../01-concepts/shape-of-an-application.md`](../01-concepts/shape-of-an-application.md).

Every configurable package follows the same two-part shape. Learn it once.

## The idiom

**Start from the package's `DEFAULT_CONFIG`. Change the fields you care about.
Pass the whole struct.**

```odin
	c := session.DEFAULT_CONFIG
	c.idle_ttl_seconds = 3600
	c.max_sessions_per_subject = 5

	mgr, err := session.manager(c, store)
	if err != .None {
		os.exit(1)
	}
```

Three lines, and the other two fields keep their defaults.

Do not build the struct literally. This compiles, and it silently sets
`absolute_ttl_seconds` and `token_bytes` to zero:

```odin
	mgr, err := session.manager(session.Config{idle_ttl_seconds = 3600}, store)  // WRONG
```

A zeroed field is not "unset". Odin has no unset. It is zero, and a zero TTL is
a different policy from the default one.

**A constructor validates and refuses.** `session.manager` returns
`.Bad_Config` for a non-positive `absolute_ttl_seconds`. Check the error. It is
the second return value, and it is the reason the mistake above is caught at
start rather than at the first login.

## Which packages have one

`DEFAULT_CONFIG`, or a named equivalent:

| Package | Constant |
|---|---|
| `auth/session` | `DEFAULT_CONFIG` |
| `auth/api_key` | `DEFAULT_CONFIG` |
| `auth/password` | `DEFAULT_POLICY` |
| `db/postgres` | `DEFAULT_CONNECT_TIMEOUT_MS`, `DEFAULT_ACQUIRE_TIMEOUT_MS` |
| `jobs` | `DEFAULT_LEASE_SECONDS`, `DEFAULT_MAX_ATTEMPTS` |
| `mail_http` | `DEFAULT_TIMEOUT_MS` |
| `validate` | `DEFAULT_MAX_ERRORS` |
| Druse core | `web.DEFAULT_LIMITS` |

The core uses the same idiom:

```odin
	l := web.DEFAULT_LIMITS
	l.max_write_time = 30 * time.Second
	web.limits(&app, l)
```

## Read the default before you override it

A default is a decision, and some of them are deliberate refusals to guess.

`session.Config.max_sessions_per_subject` defaults to `0`, meaning unlimited.
The reason is written in the source: a cap that surprises an application is
worse than none.

When you do set it, know what it does. Over the cap, `create` **refuses** with
`Too_Many_Sessions`. It never evicts. That is what stops an attacker from using
repeated logins to push a real session out.

## Configuration from the environment

`config` reads the environment through a `Loader` that collects every error
before it reports:

```odin
	ld := config.loader("APP_")
	defer config.destroy(&ld)

	port  := config.var_int(&ld, "PORT", default = 8080, min = 1, max = 65535)
	dsn   := config.var_secret(&ld, "DATABASE_URL")
	debug := config.var_bool(&ld, "DEBUG", default = false)

	if config.failed(&ld) {
		for e in config.errors(&ld) {
			fmt.eprintf("%s: %s\n", e.name, config.kind_string(e.kind))
		}
		os.exit(1)
	}
```

Read that shape. Every `var_*` call runs, then you check once. A misconfigured
deployment reports every missing variable in one run, not the first one, then
the next one after a restart.

`config.errors` returns every failure, and `config.truncated` tells you whether
the bound was reached. The loader stops collecting at `DEFAULT_MAX_ERRORS`.

**The loader owns every string it hands out.** `dsn` above is valid while `ld`
is. Do not destroy the loader and keep the values: destroy it at the end of
`main`, after `web.serve` returns, or clone what you need. This is the rule from
[`ownership-and-lifetime.md`](ownership-and-lifetime.md), in the one place that
looks least like it.

A `Secret` is not a string. Read it with `config.reveal(&ld, dsn)` at the point
of use.

The readers are:

| Reader | Reads |
|---|---|
| `var_string` | A string |
| `var_secret` | A `Secret` — a string that will not print |
| `var_int` | An integer, with bounds |
| `var_bool` | A boolean |
| `var_duration_ms` | A duration, in milliseconds |
| `var_size_bytes` | A byte size |
| `var_enum` | One of an allowed set |

**Use `var_secret` for anything you would not put in a log.** It exists so that
a `Secret` cannot be printed by accident. A DSN read with `var_string` reaches
your log the first time somebody adds a debug line.

There is no `var_u16`. For a port, use `var_int` with bounds and convert. This
is recorded in [`../FIXES-WANTED.md`](../FIXES-WANTED.md).

## Fail at start, not at the first request

Every rule on this page has the same purpose. A configuration mistake must stop
the process before it binds a port.

Check the constructor's error. Check `config.failed`. Exit non-zero.

A service that starts with a zero TTL and answers requests is worse than a
service that did not start, because your supervisor cannot see the difference
between it and a healthy one.
