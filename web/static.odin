// WP61 — STATIC FILES: `static` and `Static_Options`.
//
// TWO SYMBOLS, and like `cors` this is CONFIGURATION rather than a route: a
// mount owns a path prefix, and the framework answers `GET` and `HEAD` under it
// from a directory. It is not a `Router` for a mechanical reason — a `Handler`
// is a plain procedure with no captured state, so a handler produced by
// `static` could not know which directory it was for. The App holds the mounts;
// the request path reads them.
//
// A MOUNT OWNS ITS PREFIX ENTIRELY. A request under it is answered from the
// filesystem or answered 404; it never falls through to a route. That is the
// `location` rule every reverse proxy already uses, it is predictable, and the
// alternative — try the router, then fall back — makes the answer to "why is my
// route shadowed" depend on whether a file happens to exist.
//
// ---------------------------------------------------------------------------
// THE SECURITY SURFACE IS THE WHOLE FEATURE. Serving files is four lines; not
// serving the wrong ones is the work.
// ---------------------------------------------------------------------------
//
// Every rule below is a REJECTION, never a repair. Nothing here rewrites a
// path into a safe one, because a normaliser that gets it wrong produces a
// path the check already approved:
//
//	`..` anywhere            rejected. Not resolved, not collapsed.
//	`%` anywhere             rejected. Druse does not decode the path
//	                         (WP31a, permanent), so `%2e%2e` would sail past a
//	                         textual `..` check and be decoded by nobody-knows-
//	                         what downstream. A file whose name needs percent
//	                         encoding is not worth this risk.
//	`\` anywhere             rejected. It is a separator on Windows and a legal
//	                         filename byte elsewhere, so it means two things.
//	NUL anywhere             rejected. It truncates in every C API underneath.
//	empty interior segment   rejected (`//`), because what it collapses to
//	                         differs by platform.
//	leading `.` on a segment rejected. `.git`, `.env`, `.ssh` — the dotfiles are
//	                         exactly the files a directory should not serve.
//	not a regular file       rejected. A directory, a device, a socket or a
//	                         FIFO is not a document, and opening a FIFO parks
//	                         one synchronous Handler lane forever.
//	a symlink                rejected, whatever it points at. The stat does not
//	                         follow links, so a link reports its own type and is
//	                         refused. Resolving it and checking where it landed
//	                         would be a string comparison between paths that may
//	                         be spelled differently, and every wrong answer
//	                         serves a file it should not.
//
// ---------------------------------------------------------------------------
// WHAT IT DOES NOT DO, each with its reason.
// ---------------------------------------------------------------------------
//
// **No file larger than `max_file_size`.** Responses are buffered whole
// (ADR-014), so serving a file costs its size in memory — a 100 MB download is
// 100 MB of RSS per concurrent request. The cap is not a preference, it is the
// honest form of that constraint, and a file above it is refused with a
// diagnostic rather than served by a server that then dies. Streaming is what
// would fix this properly, and streaming is out of scope by decision.
//
// **No `Last-Modified`, and no ranges.** `Last-Modified` needs a formatted HTTP
// date, which means linking a date formatter into every application that never
// serves a file. `ETag` validates just as well, needs no formatting, and is
// what this ships. Ranges need the same partial-response machinery streaming
// does.
//
// **No directory listing.** A listing is a feature that leaks a filesystem, and
// the applications that want one can write it.
package web
// druse:file application

import "core:os"
import "core:strings"

// How many directories one application may mount. Bounded for the reason every
// capacity here is bounded, and eight is far past what a single service needs.
@(private)
STATIC_MOUNT_MAX :: 8

// The default cap on one file, 8 MiB. JUDGEMENT, recorded as such: no
// specification sets it. It is chosen to be comfortably above the assets a
// server like this actually serves — scripts, stylesheets, fonts, icons — and
// comfortably below a size that makes a buffered response a denial-of-service
// lever. Raise it deliberately if you know what you are serving.
@(private)
STATIC_FILE_LIMIT :: 8 * 1024 * 1024

@(private)
STATIC_ETAG_HEADER :: "ETag"
@(private)
STATIC_IF_NONE_MATCH :: "If-None-Match"
@(private)
STATIC_CONTENT_TYPE :: "Content-Type"

// The rendered ETag lives in request-local storage, so it needs a bound.
// `"` + 16 hex of size + `-` + 16 hex of mtime + `"` = 35.
@(private)
STATIC_ETAG_MAX :: 40

// static_if_none_match implements RFC 9110 §13.1.2's comparison for the
// `If-None-Match` field: `"*" / #entity-tag`, compared with the WEAK function.
//
// AUDIT R10 — this was `match == etag`, a single exact byte compare, which
// fails all three of the field's forms. The cost is not cosmetic: a client that
// sends a LIST — which browsers and proxies do whenever they hold more than one
// cached variant — never received a 304, so the whole file was re-sent on every
// revalidation. Measured: a list, the weak form and `*` all answered 200.
//
// THE THREE RULES, and each is one line of the loop below:
//
//	`*` matches any existing representation. The file was found, so it exists.
//	the field is a COMMA-SEPARATED list; any member matching is a match.
//	comparison is WEAK, so `W/"x"` and `"x"` are the same tag.
//
// WHAT IT MUST NOT DO, and this is the half the tests spend their assertions
// on: match too eagerly. Answering 304 to a client that does NOT hold this
// representation shows it stale content it can never refresh — a worse failure
// than the one being fixed. So members are compared WHOLE after the `W/` prefix
// and surrounding whitespace are removed; a prefix of a tag is not the tag, and
// there is no substring test anywhere in here.
//
// Allocation-free: it walks the field in place.
@(private)
static_if_none_match :: proc(field: string, etag: string) -> bool {
	rest := field
	for len(rest) > 0 {
		comma := strings.index_byte(rest, ',')
		member := rest if comma < 0 else rest[:comma]
		member = strings.trim_space(member)

		if member == "*" {
			// The caller has already established that the file exists.
			return true
		}
		// The weak marker is part of the tag's spelling, not of its identity.
		if strings.has_prefix(member, "W/") {
			member = member[2:]
		}
		if member == etag {
			return true
		}

		if comma < 0 {
			break
		}
		rest = rest[comma + 1:]
	}
	return false
}

// STATUS_NOT_MODIFIED carries HTTP 304 WITHOUT adding a public `Status` member.
// Unlike 409/413/429/503 (which corrective WP C1 promoted to named members
// because applications return them), 304 is a cache negotiation the framework
// performs on the application's behalf — a handler never returns it, so nothing
// would call a
// public name for it.
@(private)
STATUS_NOT_MODIFIED :: Status(304)

// Static_Options is the per-mount policy, by value.
Static_Options :: struct {
	// The largest file this mount will serve, in bytes. Zero means
	// `STATIC_FILE_LIMIT` (8 MiB). A file above the cap is answered 404 — not
	// 413, because 413 describes a REQUEST that was too large and this is a
	// response that would be.
	max_file_size: int,

	// The file served when the request names the mount root exactly, e.g.
	// `index.html`. Empty means a bare mount path is a 404 rather than a
	// listing.
	index:         string,
}

@(private)
Static_Mount :: struct {
	prefix: string,
	dir:    string,
	opts:   Static_Options,
}

@(private)
Static_Mounts :: struct {
	mount: [STATIC_MOUNT_MAX]Static_Mount,
	count: int,
}

// static mounts `dir` at `prefix`. Call it before the first request:
//
//	web.static(&app, "/assets", "public/assets")
//
// The prefix must be absolute and must not end in `/`; the directory must be
// non-empty. Anything else POISONS the application, on the same fail-closed
// terms as `limits` and `cors` — a static mount that silently does not work is
// a 404 nobody traces back to a typo, and one that silently works on the wrong
// directory is worse.
static :: proc(a: ^App, prefix: string, dir: string, o: Static_Options = {}) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		return
	}
	if app_has_dispatched(a) {
		static_poison(a, FRAMEWORK_MESSAGE_STATIC_AFTER_DISPATCH)
		return
	}
	if len(prefix) < 2 || prefix[0] != '/' || prefix[len(prefix) - 1] == '/' {
		static_poison(a, FRAMEWORK_MESSAGE_STATIC_INVALID)
		return
	}
	if len(dir) == 0 {
		static_poison(a, FRAMEWORK_MESSAGE_STATIC_INVALID)
		return
	}
	if o.max_file_size < 0 {
		static_poison(a, FRAMEWORK_MESSAGE_STATIC_INVALID)
		return
	}
	if a.private.static.count >= STATIC_MOUNT_MAX {
		static_poison(a, FRAMEWORK_MESSAGE_STATIC_INVALID)
		return
	}

	opts := o
	if opts.max_file_size == 0 {
		opts.max_file_size = STATIC_FILE_LIMIT
	}

	a.private.static.mount[a.private.static.count] = Static_Mount {
		prefix = prefix,
		dir    = dir,
		opts   = opts,
	}
	a.private.static.count += 1

	// THE FILE SERVER IS REACHED THROUGH A POINTER, and this assignment is the
	// only reference to it in the whole package. That is not indirection for
	// its own sake — it is guardrail 3 (`roadmap.md`): an application that does
	// not use a feature pays ZERO BYTES for it.
	//
	// Measured, which is why this exists: calling `static_serve` directly from
	// `driver_run` links `core:os` — and its stat, its file reading and its
	// path handling — into every binary. `examples/01-hello-world`, which
	// serves no files at all, grew by 20 KB. Through a pointer the only mention
	// of `static_serve` lives inside `static`, so when `static` is
	// dead-code-eliminated the file server and `core:os` go with it.
	//
	// The permitted residual is exactly this pointer field and its nil
	// initialisation, never the server itself. This is the same shape, and the
	// same reasoning, as `test_teardown` under G-11.
	a.private.static_serve = static_serve
}

// WP91 (F5/F6) — the static chain and its terminal. A static mount still OWNS
// its prefix (the routing decision is unchanged and shadowing semantics with
// it), but the response is produced through the same middleware chain as
// every route: global `use` middleware — auth, logging, `secure_headers` —
// covers a file exactly as it covers a handler. Before this, static responses
// bypassed the chain entirely, which the Phase-6-freeze scan recorded as
// F5/F6 and `phase-7-spec.md` §8.2 decided.
@(private)
static_chain_ensure :: proc(a: ^App) {
	if a.private.static_built {
		return
	}
	start, length := chain_flatten(a, static_terminal)
	a.private.static_start = start
	a.private.static_len = length
	a.private.static_built = true
}

@(private)
static_terminal :: proc(ctx: ^Context) {
	if ctx.private.static_mounts == nil {
		// Unreachable when entered through `dispatch`; an uncommitted response
		// is finalized as the standard 500 by the driver.
		return
	}
	_ = static_serve(ctx, ctx.private.static_mounts)
}

// static_match finds the mount that owns this path, if one does.
//
// The prefix must be followed by `/` or by nothing at all: `/assets` must not
// match `/assetsomething`, which is the boundary bug every prefix router has
// shipped at least once.
@(private)
static_match :: proc(mounts: ^Static_Mounts, path: string) -> (m: ^Static_Mount, rest: string, ok: bool) {
	for i in 0 ..< mounts.count {
		candidate := &mounts.mount[i]
		if !strings.has_prefix(path, candidate.prefix) {
			continue
		}
		tail := path[len(candidate.prefix):]
		if len(tail) == 0 {
			return candidate, "", true
		}
		if tail[0] == '/' {
			return candidate, tail[1:], true
		}
	}
	return nil, "", false
}

// static_path_is_safe applies every rejection rule. It REJECTS; it never
// repairs, because a repaired path is a path the check has already approved.
@(private)
static_path_is_safe :: proc(rest: string) -> bool {
	if len(rest) == 0 {
		return false
	}
	segment_start := true
	for i in 0 ..< len(rest) {
		c := rest[i]
		switch c {
		case 0:
			// Truncates in every C API underneath this.
			return false
		case '\\':
			// A separator on one platform and a filename byte on another.
			return false
		case '%':
			// The path is never decoded (WP31a), so an encoded traversal would
			// pass a textual `..` check and be decoded by something else later.
			return false
		case '/':
			if segment_start {
				// An empty interior segment collapses differently per platform.
				return false
			}
			segment_start = true
			continue
		case '.':
			if segment_start {
				// Dotfiles, and the first half of `..`. Both refused here.
				return false
			}
		}
		segment_start = false
	}
	// A trailing separator means a directory, and directories are not served.
	return rest[len(rest) - 1] != '/'
}

// static_serve answers this request from a mount, or reports that it did not.
//
// Reached ONLY through `App_Internal.static_serve`, assigned by `static`. See
// the note there: a direct call would link `core:os` into every application.
//
// It returns `true` when the request BELONGED to a mount, whatever the outcome —
// a served file, a 404 or a 304 — because a mount owns its prefix and must not
// fall through to the router.
@(private)
static_serve :: proc(ctx: ^Context, mounts: ^Static_Mounts) -> bool {
	if mounts.count == 0 {
		return false
	}
	// Only GET, and HEAD which arrives here as GET (WP32b). A POST to a static
	// mount is the router's business — it will produce the 405 that names what
	// the path does support.
	if ctx.request.method != .GET {
		return false
	}
	mount, rest, matched := static_match(mounts, ctx.request.path)
	if !matched {
		return false
	}

	relative := rest
	if len(relative) == 0 {
		if len(mount.opts.index) == 0 {
			static_not_found(ctx)
			return true
		}
		relative = mount.opts.index
	}
	if !static_path_is_safe(relative) {
		static_not_found(ctx)
		return true
	}

	full := strings.concatenate({mount.dir, "/", relative}, context.temp_allocator)

	// `lstat(full)` below only leaves the FINAL path component unfollowed; every
	// INTERMEDIATE directory component is still traversed through any symlink,
	// so a link like `mount/shared -> /etc` would serve `mount/shared/passwd`
	// while the final-component check saw only a regular file. Walk the
	// intermediate components and refuse a symlink at any of them — the same
	// per-component refusal the final check makes, extended to the whole path,
	// with no resolved-path string comparison to get wrong.
	{
		walk := mount.dir
		rel := relative
		for {
			slash := strings.index_byte(rel, '/')
			if slash < 0 {
				break
			}
			walk = strings.concatenate({walk, "/", rel[:slash]}, context.temp_allocator)
			seg_info, seg_err := os.lstat(walk, context.temp_allocator)
			if seg_err != nil || seg_info.type == .Symlink {
				static_not_found(ctx)
				return true
			}
			rel = rel[slash + 1:]
		}
	}

	// `lstat`, NOT `stat`: it does not follow symlinks, so a link reports
	// `.Symlink` below and is refused. See the comment on that check.
	info, stat_err := os.lstat(full, context.temp_allocator)
	if stat_err != nil {
		static_not_found(ctx)
		return true
	}
	// A directory, device, socket or FIFO is not a document — and opening a
	// FIFO would park one synchronous Handler lane for as long as the other end
	// cared to wait.
	//
	// THIS IS ALSO THE SYMLINK DEFENCE, and it is deliberately total: because
	// the stat above does not follow links, a symlink reports `.Symlink` and is
	// refused HERE — whatever it points at, inside the mount or outside it.
	//
	// Refusing all links rather than resolving them and checking where they
	// landed is the same choice the path rules above make: comparing a resolved
	// path against a root is a string comparison between two things that may be
	// spelled differently (relative against absolute, with or without `.`), and
	// every wrong answer to that comparison serves a file it should not. A rule
	// with no arithmetic in it has no arithmetic to get wrong.
	if info.type != .Regular {
		static_not_found(ctx)
		return true
	}
	if info.size > i64(mount.opts.max_file_size) {
		// 404 rather than 413: 413 describes a request that was too large, and
		// this is a response that would be. The distinction matters to whoever
		// reads the log.
		static_not_found(ctx)
		return true
	}

	etag := static_render_etag(ctx, info.size, info.modification_time._nsec)
	if match, has_match := static_arrived_header(ctx, STATIC_IF_NONE_MATCH); has_match {
		if static_if_none_match(match, etag) {
			n := 0
			ctx.private.response_headers[n] = Header_Pair {
				name  = STATIC_ETAG_HEADER,
				value = etag,
			}
			n += 1
			response_commit(&ctx.private.response, STATUS_NOT_MODIFIED, response_headers_finish(ctx, n), nil)
			return true
		}
	}

	data, read_err := os.read_entire_file_from_path(full, context.allocator)
	if read_err != nil {
		static_not_found(ctx)
		return true
	}

	n := 0
	ctx.private.response_headers[n] = Header_Pair {
		name  = STATIC_CONTENT_TYPE,
		value = static_content_type(relative),
	}
	n += 1
	ctx.private.response_headers[n] = Header_Pair {
		name  = STATIC_ETAG_HEADER,
		value = etag,
	}
	n += 1

	// The Response takes the allocation and releases it in `response_destroy`.
	// On a refusal it frees immediately, so there is no path where these bytes
	// have no owner.
	response_commit_owned(
		&ctx.private.response,
		.OK,
		response_headers_finish(ctx, n),
		data,
		context.allocator,
	)
	return true
}

@(private)
static_not_found :: proc(ctx: ^Context) {
	error_commit_static(ctx, .Not_Found, ERROR_BODY_NOT_FOUND_GENERIC)
}

// static_render_etag builds a strong validator from the size and modification
// time, into request-local storage on the `allow_buffer` terms: the committed
// response holds a view over it and is read after dispatch returns.
//
// Size and mtime rather than a content hash, because hashing every file on
// every request is a cost paid to detect a case — same size, same nanosecond,
// different bytes — that a build system does not produce.
@(private)
static_render_etag :: proc(ctx: ^Context, size: i64, mtime: i64) -> string {
	buf := &ctx.private.static_etag_buffer
	digits := "0123456789abcdef"
	n := 0
	buf[n] = '"'
	n += 1
	n = static_write_hex(buf[:], n, u64(size))
	buf[n] = '-'
	n += 1
	n = static_write_hex(buf[:], n, u64(mtime))
	buf[n] = '"'
	n += 1
	_ = digits
	return string(buf[:n])
}

@(private)
static_write_hex :: proc(buf: []u8, at: int, value: u64) -> int {
	digits := "0123456789abcdef"
	if value == 0 {
		buf[at] = '0'
		return at + 1
	}
	// Render into a scratch array, then copy: the value is produced
	// least-significant first and the header reads left to right.
	scratch: [16]u8
	count := 0
	v := value
	for v > 0 && count < len(scratch) {
		scratch[count] = digits[v & 0xF]
		count += 1
		v >>= 4
	}
	n := at
	for i := count - 1; i >= 0; i -= 1 {
		buf[n] = scratch[i]
		n += 1
	}
	return n
}

// static_content_type maps an extension to a type, and answers
// `application/octet-stream` for anything it does not recognise.
//
// A SHORT TABLE ON PURPOSE. A framework that ships a thousand-entry MIME
// database has taken on a maintenance job that belongs to a system; these are
// the types a server like this actually sends. `octet-stream` for the rest is
// the safe answer — a browser will download it rather than guess, and
// `secure_headers`' `nosniff` makes that guarantee real.
@(private)
static_content_type :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	if dot < 0 || dot == len(path) - 1 {
		return "application/octet-stream"
	}
	switch path[dot:] {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".ico":
		return "image/x-icon"
	case ".woff2":
		return "font/woff2"
	case ".woff":
		return "font/woff"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".xml":
		return "application/xml"
	case ".pdf":
		return "application/pdf"
	case ".wasm":
		return "application/wasm"
	}
	return "application/octet-stream"
}

// static_arrived_header reads a header as it arrived, bypassing the ADR-027
// overlay for the reason `cors_arrived_header` does.
@(private)
static_arrived_header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false
}
