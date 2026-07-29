# Uploads

Bodies spooled to disk instead of held in memory.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `enable_upload`

```odin
enable_upload :: proc(a: ^App, cfg: Upload_Config, loc := #caller_location)
```

enable_upload turns on spooled large-body ingestion for this App. It must be called before `serve` and before any route registration or dispatch, like every other App-level setting (WP17 fail-closed ordering); a call after that is refused, not silently raced.

## `upload`

```odin
upload :: proc(ctx: ^Context) -> (up: Upload, ok: bool)
```

upload returns this request's spooled upload, or ok=false when the body was not spooled: it was within `max_body` (use `web.body`/`web.form_file`), the App did not `enable_upload`, or the request ran on the in-memory test transport.

Taught in [`05-recipes/accept-a-file-upload.md`](../guide/05-recipes/accept-a-file-upload.md).

## `upload_persist`

```odin
upload_persist :: proc(ctx: ^Context, destination: string) -> bool
```

upload_persist transfers THIS REQUEST's spooled body to `destination` (an explicit rename out of the spool namespace) and hands ownership to the application: after it succeeds, request teardown will NOT delete the file. Persist is keyed on the Context, not on the `Upload` value, because the upload belongs to the request (and so the public surface carries no framework pointer). Returns false if the body was not spooled, is already terminal, or the rename failed (e.g. a cross-filesystem destination) — in which case teardown still cleans up.

Taught in [`05-recipes/accept-a-file-upload.md`](../guide/05-recipes/accept-a-file-upload.md).

## `Upload`

```odin
Upload :: struct {path: string, size: i64}
```

Upload describes a request body that was spooled to disk. `path` is the on-disk location (a generated name under the configured directory) and `size` its byte length; both are valid for the duration of the Handler. The upload is owned by the REQUEST, not by this value — it is a plain description, carrying no framework pointer (G-03). The file is deleted exactly once at request teardown UNLESS `upload_persist` transfers ownership out of the spool namespace.

## `Upload_Config`

```odin
Upload_Config :: struct {dir: string, per_upload_quota: i64, process_quota: i64, max_concurrent: int, memory_prefix_max: int}
```

Upload_Config is the opt-in. `dir` is REQUIRED — the core never writes to a silent /tmp an operator did not choose. Zero quota/limit fields select the §4.2 registered defaults (1 GiB per upload, 8 GiB per process, 64 KiB memory prefix, and handler-lanes − 1 concurrent spools).
