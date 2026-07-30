# Build baseline

WP0 pins the Phase-1 compiler in `odin-version.txt` and exposes one local/CI
entry point:

```bash
env DRUSE_ODIN_BIN=/tmp/druse-toolchain/odin bash build/check.sh
```

`build/check.sh` is verification-only. It checks commit `819fdc7`, confirms
the required standard-library packages, syntax-checks the shell runners, and
runs all nine disposable prototypes with the repository collection mapping.
It does not download a compiler or modify sources.

`build/check_test.sh` verifies both the accepted compiler path and rejection
of a divergent compiler. `.githooks/pre-push` runs the same gate before every
push. `ops/ci/` repeats it from a clean archive on the project VPS; no GitHub
Actions access is required.

WP1 extended this entry point, as planned. After the disposable suite,
`build/check.sh` now also:

1. runs `odin check web -no-entry-point` (the public package is a library, so
   without that flag the pinned compiler reports
   `Undefined entry point procedure 'main'`);
2. runs `odin test tests/wp1-public-api`, the compile contract — an external
   consumer package that references every Phase-1 symbol by exact public name,
   proving both existence and export;
3. runs `build/check_public_api.sh`, the anti-accretion contract of
   `planning/public-api-guardrails.md`: exact `web/` file
   set, exact exported-symbol inventory, later-phase symbol rejection,
   dynamic/untyped storage rejection, canonical handler shape, transport-leak
   scan, and dependency policy.

`build/check_public_api.sh` reads only `web/` and `examples/`, and reads code
rather than comments. Architecture and planning documents are never scanned:
backend names are legitimate there, and flagging them would be a false
positive under guardrail G-06.

The disposable prototype baseline is unchanged at `PASS=10 FAIL=0 SKIP=0`; the
WP1 checks report separately and do not alter that count.
