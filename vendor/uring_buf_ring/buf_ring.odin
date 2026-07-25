// Package uring_buf_ring — a provided-buffer ring for io_uring, built from
// scratch. Odin's `core:sys/linux/uring` ships `provide_buffers` and
// `read_multishot` as `unimplemented()` stubs and has no buffer-ring type at all,
// so Phase 9 (WP115) implements the ABI here, as a vendored package the Uruquim
// tree owns. It is the base that multishot recv (WP116) stands on.
//
// WHAT A PROVIDED-BUFFER RING IS. Instead of naming a buffer per recv SQE, the
// application registers a pool of buffers once (a "buffer group", `bgid`). A recv
// with `IOSQE_BUFFER_SELECT` then lets the KERNEL pick a free buffer from that
// group for each completion, reporting which one it used in the CQE's flags
// (`IORING_CQE_F_BUFFER` set, buffer id in `flags >> IORING_CQE_BUFFER_SHIFT`).
// The application consumes the data and RECYCLES the buffer back to the ring. A
// single multishot recv can then serve many arrivals with zero per-recv buffer
// setup and one fewer copy — the CPU lever Phase 9 needs.
//
// This file is the low-level ring; it does no recv itself. WP116 wires it into
// nbio's recv path.

package uring_buf_ring

import "core:sync"
import "core:sys/linux"

// IORING_CQE_BUFFER_SHIFT — the CQE flags field carries the selected buffer id in
// its upper 16 bits (`flags >> 16`) when IORING_CQE_F_BUFFER is set. The kernel's
// value; `core:sys/linux` does not export it.
CQE_BUFFER_SHIFT :: 16

// Buf is one entry of the shared ring — the kernel ABI `struct io_uring_buf`.
// The application fills these to hand buffers to the kernel; the kernel reads
// them to pick a buffer for a buffer-select operation.
Buf :: struct {
	addr: u64, // userspace address of this buffer
	len:  u32, // its length in bytes
	bid:  u16, // buffer id — echoed back in the CQE so we know which one was used
	resv: u16,
}
#assert(size_of(Buf) == 16)

// Buf_Reg is the argument to io_uring_register(IORING_REGISTER_PBUF_RING) — the
// kernel ABI `struct io_uring_buf_reg`.
Buf_Reg :: struct {
	ring_addr:    u64, // mmap'd address of the ring
	ring_entries: u32, // number of entries (power of two)
	bgid:         u16, // buffer group id this ring serves
	flags:        u16,
	resv:         [3]u64,
}
#assert(size_of(Buf_Reg) == 40)

// Ring is our handle to a registered buffer group. The shared memory is an array
// of `entries` Bufs; the FIRST Buf's storage is aliased by the kernel as the ring
// header, whose only field we touch is `tail` at byte offset 14. We keep a
// private `local_tail` and publish it to the shared tail with a release store on
// `advance`, exactly as liburing's io_uring_buf_ring_add/advance do.
Ring :: struct {
	ring_fd:    linux.Fd,
	bgid:       u16,
	entries:    u32,
	mask:       u32, // entries - 1
	mmap:       []u8,
	bufs:       [^]Buf, // == &mmap[0]; entries-long
	tail:       ^u16,   // == &mmap[14]; the shared tail the kernel reads
	local_tail: u16,
}

// setup registers a new provided-buffer ring for `bgid` with `entries` slots
// (must be a power of two). It mmaps the shared ring and asks the kernel to
// register it. On success the ring is empty — the caller adds buffers with
// `add`+`advance` before issuing a buffer-select recv against `bgid`.
setup :: proc(ring: ^Ring, ring_fd: linux.Fd, bgid: u16, entries: u32) -> (err: linux.Errno) {
	if entries == 0 || (entries & (entries - 1)) != 0 {
		return .EINVAL // power of two, non-zero
	}

	size := uint(entries) * size_of(Buf)
	// APP-ALLOCATED ring (the portable path, no IOU_PBUF_RING_MMAP): we allocate
	// the ring memory ourselves — a page-aligned anonymous mmap — and hand its
	// address to the kernel via `ring_addr` in the register call. (The alternative,
	// kernel-allocated ring mmap'd at IORING_OFF_PBUF_RING, needs 6.4+ and the MMAP
	// flag; app-allocated works on every provided-buffer-ring kernel, 5.19+.)
	addr, merr := linux.mmap(0, size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, linux.Fd(-1), 0)
	if merr != nil {
		return merr
	}

	reg := Buf_Reg {
		ring_addr    = u64(uintptr(addr)),
		ring_entries = entries,
		bgid         = bgid,
	}
	if rerr := linux.io_uring_register(ring_fd, .REGISTER_PBUF_RING, &reg, 1); rerr != nil {
		linux.munmap(addr, size)
		return rerr
	}

	base := ([^]u8)(addr)
	ring.ring_fd = ring_fd
	ring.bgid = bgid
	ring.entries = entries
	ring.mask = entries - 1
	ring.mmap = base[:size]
	ring.bufs = ([^]Buf)(addr)
	ring.tail = (^u16)(&base[14]) // io_uring_buf_ring header: tail at offset 14
	ring.local_tail = 0
	// The kernel expects the tail zeroed at registration (fresh mmap+POPULATE is
	// already zero, but be explicit — a stale tail hands out garbage buffers).
	sync.atomic_store_explicit(ring.tail, 0, .Release)
	return
}

// add stages one buffer into the ring at the slot `mask & (tail + offset)`.
// `offset` lets a caller stage several buffers (0,1,2,…) before a single
// `advance` publishes them all. It does NOT publish — the buffer is invisible to
// the kernel until `advance`.
add :: proc(ring: ^Ring, buffer: []u8, bid: u16, offset: u16) {
	slot := &ring.bufs[(ring.local_tail + offset) & u16(ring.mask)]
	slot.addr = u64(uintptr(raw_data(buffer)))
	slot.len = u32(len(buffer))
	slot.bid = bid
	slot.resv = 0
}

// advance publishes `count` staged buffers to the kernel with a single release
// store on the shared tail — the kernel may consume them the instant it sees the
// new tail, so every field of every staged Buf must already be written (the
// release store orders those writes before the tail update).
advance :: proc(ring: ^Ring, count: u16) {
	ring.local_tail += count
	sync.atomic_store_explicit(ring.tail, ring.local_tail, .Release)
}

// recycle is the common case: hand ONE consumed buffer back and publish it. Use
// after a buffer-select completion, once the bytes have been copied out.
recycle :: proc(ring: ^Ring, buffer: []u8, bid: u16) {
	add(ring, buffer, bid, 0)
	advance(ring, 1)
}

// buffer_id extracts the selected buffer id from a completion's flags. Valid only
// when `has_buffer(flags)` is true.
buffer_id :: proc "contextless" (cqe_flags: linux.IO_Uring_CQE_Flags) -> u16 {
	return u16(transmute(u32)cqe_flags >> CQE_BUFFER_SHIFT)
}

// has_buffer reports whether the kernel selected a provided buffer for this
// completion (IORING_CQE_F_BUFFER).
has_buffer :: proc "contextless" (cqe_flags: linux.IO_Uring_CQE_Flags) -> bool {
	return .BUFFER in cqe_flags
}

// has_more reports whether the parent (multishot) SQE will generate more CQEs
// (IORING_CQE_F_MORE). When false, a multishot op has terminated and must be
// re-armed.
has_more :: proc "contextless" (cqe_flags: linux.IO_Uring_CQE_Flags) -> bool {
	return .MORE in cqe_flags
}

// release unregisters the buffer group and unmaps the ring. Idempotent-safe only
// once; the caller must ensure no buffer-select op is still outstanding.
release :: proc(ring: ^Ring) {
	if ring.ring_fd < 0 || ring.mmap == nil {
		return
	}
	reg := Buf_Reg{bgid = ring.bgid}
	_ = linux.io_uring_register(ring.ring_fd, .UNREGISTER_PBUF_RING, &reg, 1)
	linux.munmap(raw_data(ring.mmap), len(ring.mmap))
	ring^ = Ring{ring_fd = -1}
}
