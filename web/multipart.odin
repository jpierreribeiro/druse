// WP63 — MULTIPART FORMS: `Uploaded_File`, `form_field`, `form_file`.
//
// THREE SYMBOLS, and a narrower feature than the name suggests. WP62 answered
// OQ-20's seven questions and found the premise underneath four of them false:
// this framework has no spool. The body arrives WHOLE, bounded by
// `Limits.max_body` and refused with 413 before any handler runs if it is
// larger. So there is no temporary file, nothing to clean up, no disk to fill,
// and no persistence to transfer — the questions dissolve rather than being
// answered.
//
// What remains is a parser over bytes that are already in memory. Every part is
// a VIEW over `ctx.request.body`, valid for the request and not one instruction
// longer, which is the same lifetime rule every other request-derived value
// already carries (G-05).
//
// THE HONEST LIMITATION, written here and in `docs/operations.md` §3 because a
// framework that says it is more useful than one that discovers it in
// production: **an upload larger than `max_body` cannot be accepted, at any
// setting that is not itself a memory problem.** Gin spools to disk through
// `net/http`; this does not spool at all. If you need large uploads, terminate
// them at a proxy or an object store and hand the application a reference.
//
// WHY THE BOUNDS EXIST, and they are the only new policy in this package:
// `max_body` bounds the BYTES and not the WORK. A 4 MiB body can be ten
// thousand parts, and a parser that allocates once per part turns a bounded
// body into an unbounded loop — a denial of service that passes every limit
// this framework had. So the part count and the per-part size are bounded too,
// and the parse writes into a fixed array on the Context rather than allocating.
//
// IT IS A BODY CONSUMER, on ADR-012's terms exactly. `web.body` and the form
// readers consume the same single-use capability: whichever runs first takes
// it, and the second reports that it is gone. Multipart bytes are not JSON and
// reading them twice through two different decoders is the ambiguity ADR-012
// closed.
package web
// uruquim:file application

import "core:strings"

// How many parts one request may carry. Bounded for the reason stated above,
// and thirty-two is far past what a form submits.
@(private)
MULTIPART_PART_MAX :: 32

// The largest single part, 1 MiB by default — below `max_body` on purpose, so
// one part cannot consume the whole budget by itself.
@(private)
MULTIPART_PART_LIMIT :: 1024 * 1024

@(private)
MULTIPART_CONTENT_TYPE :: "Content-Type"
@(private)
MULTIPART_PREFIX :: "multipart/form-data"
@(private)
MULTIPART_DISPOSITION :: "Content-Disposition"

// Uploaded_File is one file part, by value.
//
// `bytes` is a VIEW over the request body. It is valid until the request ends
// and must be COPIED by anything that keeps it — the same contract `web.header`
// and `web.path` carry, and the reason the doc comment says so rather than
// leaving it to be discovered.
Uploaded_File :: struct {
	// The form field this part was submitted under.
	field:        string,
	// The client-supplied file name. **Never trust it as a path.** It is the
	// browser's word for what the user called a file, it may contain
	// separators, and the framework does not sanitise it because it never uses
	// it. Generate your own storage name.
	filename:     string,
	// The client-supplied type. Also untrusted: it is a claim, not a check.
	content_type: string,
	// The content, a view over the request body.
	bytes:        []u8,
}

@(private)
Multipart_Part :: struct {
	field:        string,
	filename:     string,
	content_type: string,
	bytes:        []u8,
	is_file:      bool,
}

@(private)
Multipart_Form :: struct {
	part:   [MULTIPART_PART_MAX]Multipart_Part,
	count:  int,
	parsed: bool,
	ok:     bool,
}

// form_field returns a text field's value.
//
//	name, ok := web.form_field(ctx, "title")
//
// `ok` is false when the request is not a multipart form, the body was already
// consumed, the form did not parse, or no such field was submitted. Those are
// deliberately not distinguished: a handler that needs to tell them apart is
// asking about the shape of a request it did not control.
form_field :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	form := multipart_form(ctx)
	if form == nil || !form.ok {
		return "", false
	}
	for i in 0 ..< form.count {
		part := &form.part[i]
		if !part.is_file && part.field == name {
			return string(part.bytes), true
		}
	}
	return "", false
}

// form_file returns a file part.
//
//	file, ok := web.form_file(ctx, "avatar")
//
// `file.bytes` is a VIEW over the request body and does not outlive the
// request. Copy what you keep.
form_file :: proc(ctx: ^Context, name: string) -> (file: Uploaded_File, ok: bool) {
	form := multipart_form(ctx)
	if form == nil || !form.ok {
		return {}, false
	}
	for i in 0 ..< form.count {
		part := &form.part[i]
		if part.is_file && part.field == name {
			return Uploaded_File {
					field = part.field,
					filename = part.filename,
					content_type = part.content_type,
					bytes = part.bytes,
				},
				true
		}
	}
	return {}, false
}

// multipart_form parses on first use and caches, or reports that it cannot.
//
// The ADR-012 capability is taken HERE, once, by whichever reader runs first —
// so `web.body` after a form reader fails exactly as a second `web.body` does,
// and the ambiguity of decoding one body twice never arises.
@(private)
multipart_form :: proc(ctx: ^Context) -> ^Multipart_Form {
	form := &ctx.private.multipart
	if form.parsed {
		return form
	}
	form.parsed = true
	form.ok = false

	if ctx.private.body_state == .Consumed {
		return form
	}
	ctx.private.body_state = .Consumed

	content_type, has_type := multipart_arrived_header(ctx, MULTIPART_CONTENT_TYPE)
	if !has_type || !strings.has_prefix(content_type, MULTIPART_PREFIX) {
		return form
	}
	boundary, has_boundary := multipart_boundary(content_type)
	if !has_boundary {
		return form
	}
	if len(ctx.request.body) == 0 {
		return form
	}

	form.ok = multipart_parse(form, ctx.request.body, boundary)
	return form
}

// multipart_boundary extracts `boundary=` from the content type.
//
// A quoted value is accepted because the grammar allows it; an empty one is
// refused, because an empty boundary matches everywhere and would split the
// body into as many parts as it has bytes.
@(private)
multipart_boundary :: proc(content_type: string) -> (boundary: string, ok: bool) {
	// Read `boundary` only as a real MIME parameter, never as a substring that
	// happens to appear inside another parameter's quoted value. A bare
	// `strings.index(content_type, "boundary=")` lets a crafted header like
	//   multipart/form-data; name="x; boundary=evil"; boundary=good
	// make this framework split on `evil` while an RFC-strict intermediary
	// (a WAF or scanning proxy) splits on `good`, so the two disagree on where
	// parts begin — a content-inspection bypass. Walk the header as a media
	// type followed by `; parameter=value` pairs, honouring quoted-strings, and
	// take the value of the first `boundary` parameter at a true parameter
	// position.
	rest := content_type

	// Skip the media type: everything up to the first top-level `;`.
	if semi := strings.index_byte(rest, ';'); semi >= 0 {
		rest = rest[semi + 1:]
	} else {
		return "", false
	}

	for len(rest) > 0 {
		// One parameter: trim leading whitespace, read the name up to `=`.
		rest = strings.trim_left_space(rest)
		eq := strings.index_byte(rest, '=')
		if eq < 0 {
			return "", false
		}
		name := strings.trim_right_space(rest[:eq])
		rest = rest[eq + 1:]

		// Read this parameter's value, then advance past it, so a `;` or a
		// `boundary=` inside a quoted value is never mistaken for structure.
		value: string
		if len(rest) > 0 && rest[0] == '"' {
			rest = rest[1:]
			close := strings.index_byte(rest, '"')
			if close < 0 {
				return "", false
			}
			value = rest[:close]
			rest = rest[close + 1:]
			// Discard up to and including the next parameter separator.
			if semi := strings.index_byte(rest, ';'); semi >= 0 {
				rest = rest[semi + 1:]
			} else {
				rest = ""
			}
		} else {
			end := strings.index_byte(rest, ';')
			if end < 0 {
				value = rest
				rest = ""
			} else {
				value = rest[:end]
				rest = rest[end + 1:]
			}
			value = strings.trim_space(value)
		}

		if equal_ascii_fold(name, "boundary") {
			if len(value) == 0 {
				return "", false
			}
			return value, true
		}
	}

	return "", false
}

// equal_ascii_fold compares two strings case-insensitively over ASCII, for the
// MIME parameter NAME, which is case-insensitive; the boundary VALUE itself
// stays byte-exact.
@(private)
equal_ascii_fold :: proc(a: string, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}

// multipart_parse walks the body. It allocates NOTHING: every field it produces
// is a view, and the parts land in the Context's fixed array.
//
// It returns false on anything malformed rather than salvaging what it can. A
// half-parsed form is a form whose missing field looks like a field the user
// did not fill in, and that difference matters to whoever wrote the handler.
@(private)
multipart_parse :: proc(form: ^Multipart_Form, body: []u8, boundary: string) -> bool {
	delimiter := strings.concatenate({"--", boundary}, context.temp_allocator)
	text := string(body)

	// The body must open with the delimiter.
	if !strings.has_prefix(text, delimiter) {
		return false
	}
	cursor := len(delimiter)

	for {
		if cursor + 2 > len(text) {
			return false
		}
		// `--` here marks the closing delimiter; anything else must be CRLF.
		if text[cursor:cursor + 2] == "--" {
			return true
		}
		if text[cursor:cursor + 2] != "\r\n" {
			return false
		}
		cursor += 2

		header_end := strings.index(text[cursor:], "\r\n\r\n")
		if header_end < 0 {
			return false
		}
		headers := text[cursor:cursor + header_end]
		cursor += header_end + 4

		// MULTIPART AUDIT F6 — KEEP LOOKING UNTIL THE MATCH IS THE DELIMITER.
		//
		// This took the FIRST `\r\n--` in the remaining body and then required it
		// to be the boundary, returning false for the whole form otherwise. But
		// `\r\n--` is four ordinary bytes: any binary part (parts run to
		// `MULTIPART_PART_LIMIT`) can contain it by chance, and a PNG or zip that
		// did made `form_file`/`form_field` fail for the entire form — an upload
		// that failed intermittently and non-deterministically, on content rather
		// than on anything the user did.
		//
		// The delimiter is only a delimiter when the boundary follows it, so scan
		// forward past occurrences that do not qualify. Fail-closed either way:
		// a truncated body still ends with no match and is still refused.
		search := cursor
		content_end := -1
		for {
			hit := strings.index(text[search:], "\r\n" + "--")
			if hit < 0 {
				break
			}
			abs := search + hit
			if strings.has_prefix(text[abs + 2:], delimiter) {
				content_end = abs
				break
			}
			// Not our boundary — a content byte sequence that merely looks like
			// one. Step past this `\r\n` and keep scanning the same part.
			search = abs + 2
		}
		// A part with no following delimiter is a truncated body.
		if content_end < 0 {
			return false
		}
		content := text[cursor:content_end]
		cursor = content_end + 2 + len(delimiter)

		if len(content) > MULTIPART_PART_LIMIT {
			return false
		}
		if form.count >= MULTIPART_PART_MAX {
			// REFUSED, not truncated. A form that silently dropped its
			// thirty-third part would hand the handler a field the user filled
			// in and the framework discarded.
			return false
		}

		part: Multipart_Part
		part.bytes = transmute([]u8)content
		if !multipart_read_headers(&part, headers) {
			return false
		}
		if len(part.field) == 0 {
			return false
		}
		form.part[form.count] = part
		form.count += 1
	}
}

// multipart_read_headers reads a part's headers, which in practice means
// `Content-Disposition` and optionally `Content-Type`.
@(private)
multipart_read_headers :: proc(part: ^Multipart_Part, headers: string) -> bool {
	rest := headers
	for len(rest) > 0 {
		line := rest
		if crlf := strings.index(rest, "\r\n"); crlf >= 0 {
			line = rest[:crlf]
			rest = rest[crlf + 2:]
		} else {
			rest = ""
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			return false
		}
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])

		if ascii_fold_equal(name, MULTIPART_DISPOSITION) {
			if field, ok := multipart_parameter(value, "name"); ok {
				part.field = field
			}
			if filename, ok := multipart_parameter(value, "filename"); ok {
				part.filename = filename
				// THE PRESENCE OF `filename` IS WHAT MAKES A PART A FILE, per
				// the HTML form specification — not the content type, and not
				// whether the bytes look like anything in particular.
				part.is_file = true
			}
		} else if ascii_fold_equal(name, MULTIPART_CONTENT_TYPE) {
			part.content_type = value
		}
	}
	return true
}

// multipart_parameter reads `key="value"` out of a header value.
//
// Only the quoted form is accepted. Browsers always quote these, the grammar's
// unquoted form cannot contain the characters that make a filename interesting,
// and accepting both would mean two parsers where one will do.
@(private)
multipart_parameter :: proc(value: string, key: string) -> (out: string, ok: bool) {
	needle := strings.concatenate({key, "=\""}, context.temp_allocator)
	at := strings.index(value, needle)
	if at < 0 {
		return "", false
	}
	rest := value[at + len(needle):]
	close := strings.index_byte(rest, '"')
	if close < 0 {
		return "", false
	}
	return rest[:close], true
}

// multipart_arrived_header reads a header as it arrived, bypassing the ADR-027
// overlay for the reason `cors_arrived_header` does.
@(private)
multipart_arrived_header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false
}
