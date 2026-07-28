# Store a file

Package `crystals:storage`, with `storage_filesystem` and `storage_s3`.

One contract, two backends. The application chooses which, in `main`.

## The four operations

```odin
	r := storage.put(store, storage.Put_Request{...})
	obj, gr := storage.get(store, key)
	meta, sr := storage.stat(store, key)
	rr := storage.remove(store, key)
```

`stat` reads metadata without transferring the bytes. Use it when you only need
the size or the content type.

## Validate the key first

```odin
	if !storage.key_ok(key) {
		web.bad_request(ctx, "invalid key")
		return
	}
```

**A key derived from user input is a path traversal waiting to happen.**
`key_ok` and `content_type_ok` are the guards; `storage.validate` checks a whole
request.

`MAX_KEY_BYTES`, `MAX_CONTENT_TYPE_BYTES` and `MAX_OBJECT_BYTES` bound the
rest. Over any of them the operation is refused.

## Choosing a backend

| Backend | Use when |
|---|---|
| `storage_filesystem` | One process, one disk, development |
| `storage_s3` | More than one replica, or durability you do not run yourself |

**A filesystem store behind a load balancer is a bug.** The replica that
answers the download is usually not the one that took the upload.

Swapping is one line, at the `store` call in `main`. That is the whole point of
the contract.

## With uploads

The spooled upload path gives you a file on disk. `upload_persist` transfers
ownership, then you `put` it and remove your copy. See
[`accept-a-file-upload.md`](accept-a-file-upload.md).

Do not hold `Uploaded_File.bytes` past the handler — it is a view into the
request buffer.

## Uploading is slow

An S3 put takes as long as the network takes. Inside a handler, that is your
response time.

For anything large, spool it, enqueue a job, and upload from the worker. See
[`run-background-jobs.md`](run-background-jobs.md).
