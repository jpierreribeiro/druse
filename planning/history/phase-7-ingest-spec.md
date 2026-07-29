# Phase-7 inbound large-body contract — the opt-in spool and streaming multipart

**Status:** SPEC, 2026-07-23, WP93. Formalizes the opt-in large-body path whose
capacity numbers are pre-registered in `phase-7-spec.md` §4.2 (OQ-20
Amendment 1). The buffered path (`web.body`, `form_field`, `form_file`) is
unchanged and is the **compatibility oracle** for every answer here.

This document is normative for WP94's implementation. The RED corpus that
precedes the code is `tests/wp87-body-lifecycle` (the spool ownership
substrate, committed RED in WP87) plus `tests/wp94-multipart` (the streaming
parser, committed with the implementation because its every assertion is a
fragmentation-invariance property that only a real parser can satisfy — a
sentinel would pass none and prove nothing).

---

## 1. The two answers, pre-registered

Every OQ-20-Amendment-1 question is answered before spool code exists; the
implementation is held to these, not free to choose them after a result.

| Question | Answer |
|---|---|
| memory ownership and chunk validity | one chunk buffer at a time; a body of any size costs one chunk, never its length (G7-9). The application receives an explicitly owned spool, not a view into transport memory |
| temporary directory | application-designated, **required** to opt in; the core never writes to a silent `/tmp` |
| filename generation | a generated `druse-spool-<mixed-hex>` name, `0600`; the client filename is metadata handed to the application, **never** a path the parser opens |
| symlink policy | the spool file is created `O_CREATE\|O_TRUNC\|O_WRONLY` at a generated name inside the designated dir; a client filename with `../` is recorded verbatim and reaches no filesystem call |
| per-upload / concurrent / process quota | `per_upload_quota` (default 1 GiB), `max_concurrent` admission (default 1, sized below lane capacity), `process_quota` (default 8 GiB), all checked mid-body |
| maximum fields / parts / header bytes | field values and header blocks are bounded by `memory_prefix_max` (default 64 KiB) and a hard `MP_FIELD_MAX` ceiling; exceeding refuses the body |
| persistence transfer vs deletion | `persist` (an explicit rename out of the spool namespace) is the ONLY path that leaves a file; every other terminal path deletes exactly once |
| disk-full / filesystem error | a write error is the typed `Disk_Full` terminal; the partial file is deleted and the process-quota reservation returned |
| request deadline / client disconnect | a disconnect mid-body is the typed `Disconnected` terminal (cleanup); the request deadline is `max_request_time`, unchanged |
| early refusal / unread-body connection | admission refuses BEFORE any byte is read (`Refused_Admission`); the connection policy is the adapter's existing one |
| shutdown / crash leftovers | drain cancels active spools (`Cancelled_By_Drain`); the `druse-spool-` prefix is the documented operator sweep target, because the core never scans directories at boot |
| direct-to-object-store consumer | out of scope for WP94's Productive arm; the Advanced incremental consumer (WP86 arm H) is refused unless it meets its full bar, and refusing it does not refuse safe uploads |

## 2. The streaming multipart parser

- **Consumes `[]u8`, never a socket** (ADR-033). The adapter feeds it whatever
  arrived; the parser's boundary matching is what makes fragmentation
  irrelevant.
- **Boundary-correct across every fragmentation point.** It carries at most
  `len(delimiter)+2` unconfirmed bytes between feeds, so a delimiter split
  across two chunks is matched. The WP94 corpus proves this by feeding the same
  body at step sizes 1, 2, 3, 5, 7, 13 and 64 and asserting identical parts.
- **A part is a file because it carries `filename`** — the HTML form rule the
  buffered oracle enforces — never because of its content type, which is
  recorded and never acted on.
- **Fields bounded in memory; files streamed to spool.** A field value lives in
  the bounded accumulator; a file part's bytes go straight to the spool, so the
  RAM cost is independent of the file size.
- **Trusts neither filename nor part Content-Type.** The filename is recorded
  verbatim as metadata; the spool file always has a generated name.
- **The buffered in-memory parser remains the compatibility oracle** for bodies
  within both perimeters: the streaming parser's grammar (opening delimiter,
  `CRLF`/`--` after each delimiter, `CRLFCRLF` header terminator, `CRLF` +
  delimiter content terminator, name-required parts) mirrors it line for line.

## 3. What WP94 delivers vs defers

- **Delivered:** the spool ownership substrate (`web/internal/ingest`, the
  WP87 body corpus green) and the streaming multipart parser
  (`tests/wp94-multipart` green).
- **Deferred to WP94's adapter wiring / WP95:** the inbound half of the WP90
  hooks — pause/resume of socket reads by spool capacity, early-refusal
  retirement — lands where its only consumer (this spool) is wired into the
  request path, so no dead hook sits in the transport. WP95 joins active spools
  to the drain proof.

## 4. Rollback

MEDIUM-HIGH — a new security/lifecycle surface. The spool package is removable
with its (future) adapter wiring; the buffered path is untouched throughout, so
a rollback leaves Phase 6 uploads exactly as they were.
