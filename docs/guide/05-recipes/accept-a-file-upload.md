# Accept a file upload

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

Two paths. A small multipart form is read in memory. A large body is spooled to
disk. You opt into the second one.

## Small: a multipart form

```odin
form_field :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool)
form_file  :: proc(ctx: ^Context, name: string) -> (file: Uploaded_File, ok: bool)
```

```odin
	title, ok := web.form_field(ctx, "title")
	if !ok {
		return                     // already answered
	}
	file, has := web.form_file(ctx, "avatar")
	if has {
		// file.filename, file.content_type, file.bytes
	}
```

`Uploaded_File.bytes` is a **view into the request buffer** and dies when the
handler returns. Write it somewhere or clone it. The whole body counts against
`Limits.max_body`.

## Large: spool to disk

Turn it on in `main`, before any route:

```odin
	web.enable_upload(&app, web.Upload_Config{dir = spool_dir, per_upload_quota = QUOTA})
```

| Field | Bounds |
|---|---|
| `dir` | Where spool files are written |
| `per_upload_quota` | One request |
| `process_quota` | Every in-flight upload together |
| `max_concurrent` | How many spool at once |
| `memory_prefix_max` | How much is kept in memory before spilling |

Set `process_quota` and `max_concurrent` too: `per_upload_quota` alone bounds
one request, not a hundred at once.

## Read it in the handler

```odin
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")   // small body took the in-memory path
		return
	}
	data, rerr := os.read_entire_file(up.path, context.temp_allocator)
```

`ok = false` is **not** an error — the body was small enough for the buffered
path. Handle both.

`Upload` is `{path, size}`. The framework owns that spool file and deletes it
when the request ends.

## Keep the file

```odin
	if web.upload_persist(ctx, dest) {
		web.text(ctx, .Created, "persisted")
	} else {
		web.internal_error(ctx)
	}
```

`upload_persist` **transfers ownership**: the file survives teardown and is
yours to delete. Without it, copy the bytes before you return.

Check the return value: a failed persist leaves the file the framework's, and
it will vanish.
