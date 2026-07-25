// Micro-benchmark: an HTTP echo server using MULTISHOT recv
// (nbio.recv_multishot_poly over a provided-buffer ring). Identical to
// echo_oneshot except the recv is armed ONCE per connection and the kernel
// selects a buffer per arrival — no per-request recv syscall. Comparing the two
// under wrk isolates the multishot recv gain.
package main

import "core:net"
import "core:sys/linux"
import nbio "uruquim:vendor/nbio"
import br "uruquim:vendor/uring_buf_ring"

RESP := transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: keep-alive\r\n\r\npong")

NBUF  :: 256
BUFSZ :: 4096

Conn :: struct {
	socket:   net.TCP_Socket,
	bgid:     u16,
}

server:    net.TCP_Socket
buf_ring:  br.Ring
storage:   [NBUF][BUFSZ]u8
next_bgid: u16 = 1

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil { return }
	defer nbio.release_thread_event_loop()

	ep := net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = 8080}
	sock, lerr := nbio.listen_tcp(ep)
	if lerr != nil { return }
	server = sock

	// One shared provided-buffer ring (bgid 1) for all connections in this single
	// thread. Register it against nbio's own io_uring.
	if err := br.setup(&buf_ring, linux.Fd(nbio.ring_fd()), 1, NBUF); err != nil { return }
	for i in 0 ..< NBUF {
		br.add(&buf_ring, storage[i][:], u16(i), u16(i))
	}
	br.advance(&buf_ring, NBUF)

	nbio.accept_poly(server, 0, on_accept)
	for {
		if err := nbio.tick(); err != nil { return }
	}
}

on_accept :: proc(op: ^nbio.Operation, _: int) {
	if op.accept.err != nil { return }
	client := op.accept.client
	nbio.accept_poly(server, 0, on_accept) // re-arm accept

	c := new(Conn)
	c.socket = client
	c.bgid = 1
	// Arm multishot recv ONCE: it stays armed across all this connection's
	// requests (F_MORE), the kernel selecting a buffer per arrival.
	nbio.recv_multishot_poly(c.socket, c.bgid, c, on_recv)
}

on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	m := &op.recv_multishot
	if m.err != nil || (m.received == 0 && !m.more) {
		net.close(c.socket)
		free(c)
		return
	}
	if m.received > 0 {
		// Recycle the buffer the kernel used, then respond. No recv re-arm — the
		// multishot op is still armed.
		br.recycle(&buf_ring, storage[m.buffer_id][:], m.buffer_id)
		nbio.send_poly(c.socket, {RESP}, c, on_send)
	}
}

on_send :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.send.err != nil {
		net.close(c.socket)
		free(c)
	}
	// No recv re-arm needed: multishot stays armed.
}
