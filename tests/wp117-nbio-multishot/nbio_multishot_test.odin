// WP117 — proves the nbio multishot integration: nbio.recv_multishot_poly arms
// ONE op, and the callback fires once per arrival (buffer-selected from a ring
// registered against nbio's own loop), the SAME Operation reused while F_MORE is
// set. This is the recv path the scanner will use — the CPU lever, integrated
// into the event loop rather than driven by a raw uring.
package test_wp117

import "core:testing"
import "core:sys/linux"
import nbio "uruquim:vendor/nbio"
import br "uruquim:vendor/uring_buf_ring"

Ctx :: struct {
	buf_ring:  ^br.Ring,
	storage:   ^[8][64]u8,
	arrivals:  ^int,
	total:     ^int,
	last:      ^[64]u8,
	last_len:  ^int,
}

@(test)
nbio_multishot_recv_integration :: proc(t: ^testing.T) {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		testing.fail_now(t, "acquire loop failed")
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	pair: [2]linux.Fd
	if err := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair); err != nil {
		testing.fail_now(t, "socketpair failed")
	}
	defer linux.close(pair[0])
	defer linux.close(pair[1])

	// Register a provided-buffer ring against nbio's OWN io_uring.
	NBUF :: 8
	BGID :: 3
	storage: [NBUF][64]u8
	buf_ring: br.Ring
	if err := br.setup(&buf_ring, linux.Fd(nbio.ring_fd(loop)), BGID, NBUF); err != nil {
		testing.fail_now(t, "buf_ring setup failed")
	}
	defer br.release(&buf_ring)
	for i in 0 ..< NBUF {
		br.add(&buf_ring, storage[i][:], u16(i), u16(i))
	}
	br.advance(&buf_ring, NBUF)

	arrivals, total, last_len: int
	last: [64]u8
	ctx := Ctx{&buf_ring, &storage, &arrivals, &total, &last, &last_len}
	pctx := &ctx

	nbio.recv_multishot_poly(nbio.TCP_Socket(pair[0]), BGID, pctx, proc(op: ^nbio.Operation, c: ^Ctx) {
		m := &op.recv_multishot
		if m.received > 0 {
			c.arrivals^ += 1
			c.total^ += m.received
			n := m.received
			copy(c.last[:], c.storage[m.buffer_id][:n])
			c.last_len^ = n
			// Recycle the consumed buffer back to the ring.
			br.recycle(c.buf_ring, c.storage[m.buffer_id][:], m.buffer_id)
		}
	})

	// Drive three messages through, ticking the loop after each.
	msgs := [?]string{"alpha", "beta", "gamma"}
	for want in msgs {
		linux.write(pair[1], transmute([]u8)want)
		if err := nbio.tick(); err != nil {
			testing.fail_now(t, "tick failed")
		}
	}

	testing.expect_value(t, arrivals, 3)
	testing.expect_value(t, total, 5 + 4 + 5) // alpha+beta+gamma
	testing.expect_value(t, string(last[:last_len]), "gamma")
}
