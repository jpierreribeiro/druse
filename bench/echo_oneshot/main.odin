// Micro-benchmark: an HTTP echo server using ONE-SHOT recv (nbio.recv_poly),
// re-armed per request. Answers a fixed HTTP response to any request. This is the
// baseline recv model; echo_multishot is identical except it uses multishot recv.
// Comparing the two under wrk isolates the recv-path cost the multishot work
// targets, without rewriting the whole HTTP scanner first.
package main

import "core:net"
import nbio "uruquim:vendor/nbio"

RESP := transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: keep-alive\r\n\r\npong")

Conn :: struct {
	socket: net.TCP_Socket,
	rbuf:   [4096]u8,
}

server: net.TCP_Socket

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil { return }
	defer nbio.release_thread_event_loop()

	ep := net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = 8080}
	sock, lerr := nbio.listen_tcp(ep)
	if lerr != nil { return }
	server = sock

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
	arm_recv(c)
}

arm_recv :: proc(c: ^Conn) {
	nbio.recv_poly(c.socket, {c.rbuf[:]}, c, on_recv)
}

on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.recv.err != nil || op.recv.received == 0 {
		net.close(c.socket)
		free(c)
		return
	}
	// Respond and re-arm the (one-shot) recv for the next request.
	nbio.send_poly(c.socket, {RESP}, c, on_send)
}

on_send :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.send.err != nil {
		net.close(c.socket)
		free(c)
		return
	}
	arm_recv(c) // one-shot: must re-arm per request
}
