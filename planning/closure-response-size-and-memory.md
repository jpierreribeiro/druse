# C-04 — Response size and memory: corrected attribution

**Status: LIVE (Closure C-04 + ADR-045).** The socket soak remains useful, but
its original ownership conclusion is withdrawn. RSS is a process observation,
not an allocation ledger.

---

## 1. What the socket soak proves

`tests/c04-response-size` serves one 4 MiB buffered response on each of eight
keep-alive connections, then 200 small responses on each of the same
connections. The client scratch buffer is touched before the baseline so its
pages are not charged to the server.

A current representative run reported:

| point | RSS |
|---|---:|
| baseline | 8.5 MiB |
| after 8 × 4 MiB responses | 48.8 MiB |
| after 1,600 small responses | 36.8 MiB |
| after closing the clients | 36.8 MiB |

The phase-1 RSS delta was 40.3 MiB (1.26× the 32 MiB of response bodies); phase
2 reduced RSS by 12.0 MiB. This proves that RSS does not continue growing under
this short sequential workload. It does **not** identify which allocations
remain live, and it is not an hours-long leak proof.

---

## 2. The attribution the old record was missing

The old C-04 record said `virtual.Arena.free_all` reset an offset while keeping
all reserved blocks, then inferred that every keep-alive connection retained
about one response body for its lifetime. The pinned Odin implementation does
the opposite for a growing arena: it deallocates every block except the initial
1 MiB reservation and resets usage to zero.

Instrumentation around the real `clean_request_loop` measured all eight large
responses identically:

| connection arena | before `free_all` | after `free_all` |
|---|---:|---:|
| blocks | 7 | 1 |
| reserved | 28,319,757 bytes | 1,048,576 bytes |
| committed | 27,275,208 bytes | 4,040 bytes |
| used | 25,167,567 bytes | 0 |

The negative control removed the production `free_all`. It retained all seven
blocks and 25,167,567 used bytes, and the attribution assertion failed for the
intended reason. The raw baseline and mutant logs are preserved under
`PRIORIDADE/entrega/evidencias/2026-07-28-validacao-local/`.

**F-C04-1, corrected — completed large responses do not leave body-sized live
blocks in the connection arena.** The ~28 MiB RSS remaining above baseline is
allocator/process high-water, not live per-connection arena ownership.

**F-C04-2, narrowed — the 1,600-request small phase shows no continuing RSS
accumulation in that workload.** It cannot prove the absence of every
per-request leak or slow fragmentation mode.

**F-C04-3 — response construction has material transient amplification.** This
handler used about 25.2 MiB of arena space while producing one 4 MiB response.
That includes the handler's temporary body and framework copies/buffer growth.
The multiplier is workload- and allocator-dependent; it must not be promoted
to a universal constant.

The suite now separately gates the pinned growing-arena semantic. Its control
removes `arena_free_all` in a copied mutant and requires the assertion to turn
red, while the source gate requires the real response cleanup to call
`free_all(context.temp_allocator)`.

---

## 3. Current controls and the honest sizing rule

ADR-045 subsequently shipped `Limits.max_response_bytes` (default 0 = off). A
strictly larger committed body is replaced with a typed 500 before transport
copy-out. This is useful, but it bounds the response body, not every temporary
allocation a handler may make and not pages retained by the process allocator.

There is therefore no honest universal formula of
`max_connections × response size`. Production memory must be established by a
representative concurrent campaign with the application's response
distribution, handler allocation behaviour, `max_handlers`,
`max_connections`, write deadline and streaming choices. Then:

- set `max_response_bytes` to the largest legitimate buffered body;
- stream large output so memory scales with the stream window, not total body;
- enable `max_write_time` so slow readers cannot retain an in-flight buffered
  response indefinitely;
- cap concurrency with `max_handlers` and `max_connections`;
- set the cgroup above the measured concurrent peak plus explicit headroom, and
  verify that an intentional over-budget campaign fails in the expected way.

The cgroup remains the aggregate guard because the framework has no
process-wide allocator budget.

---

## 4. What is still owed

The short suite answers reclamation semantics and short-run RSS stability. It
does not replace:

- a concurrent buffered-response matrix (body sizes, handler counts and slow
  readers), which is part of the VPS campaign;
- an hours-long mixed-size soak for slow RSS growth and fragmentation;
- the separately recorded 3,000-real-socket SSE round.

Those runs need quiet machines and raw time-series evidence. They are not
approximated by extrapolating the eight-connection local result.
