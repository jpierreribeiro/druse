// WP119 prototype — multi-thread HTTP echo with SO_REUSEPORT per thread. Each
// thread owns its OWN listen socket (REUSEPORT lets N sockets share the address);
// the kernel shards incoming connections across them. A thread accepts and serves
// its own connections on its own event loop — NO shared listen socket, NO
// accept-cancel dance, NO cross-thread handoff. This isolates the CPU/throughput
// effect of the dedicated-accept (thread-per-core) model the flamegraph pointed
// to (context switches + the p28 accept dance were the top CPU costs).
//
// Compare against the framework (shared listen socket + p28 accept dance) under
// perf: if context switches and io_uring_enter overhead drop, WP119 is validated.
package main

import "core:net"
import "core:sys/linux"
import "core:thread"
import nbio "uruquim:vendor/nbio"

RESP := transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: keep-alive\r\n\r\npong")
PORT :: 8080
THREADS :: 8

Conn :: struct {
	socket: net.TCP_Socket,
	rbuf:   [4096]u8,
}

Lane :: struct {
	listen: net.TCP_Socket,
}

main :: proc() {
	lanes: [THREADS]Lane
	for i in 1 ..< THREADS {
		thread.create_and_start_with_poly_data(&lanes[i], lane_run, context)
	}
	lane_run(&lanes[0]) // this thread is lane 0; blocks forever
}

lane_run :: proc(lane: ^Lane) {
	if err := nbio.acquire_thread_event_loop(); err != nil { return }

	// Own listen socket with SO_REUSEPORT so N threads can bind the same port and
	// the kernel shards connections across them.
	sock := open_reuseport_listener()
	if sock == 0 { return }
	lane.listen = sock

	nbio.accept_poly(sock, lane, on_accept)
	for {
		if err := nbio.tick(); err != nil { return }
	}
}

// open_reuseport_listener creates a TCP socket, sets SO_REUSEADDR + SO_REUSEPORT
// (via raw setsockopt — core:net on Linux does not expose REUSEPORT), binds
// 0.0.0.0:PORT and listens. Returns the socket as an nbio TCP_Socket, or 0 on error.
open_reuseport_listener :: proc() -> net.TCP_Socket {
	fd, serr := linux.socket(.INET, .STREAM, {.NONBLOCK}, .TCP)
	if serr != nil { return 0 }

	one: i32 = 1
	// SOL_SOCKET = 1; SO_REUSEADDR = 2; SO_REUSEPORT = 15 (linux bits).
	linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEPORT, &one)

	addr := linux.Sock_Addr_In{sin_family = .INET, sin_port = u16be(PORT), sin_addr = {0, 0, 0, 0}}
	if berr := linux.bind(fd, &addr); berr != nil { linux.close(fd); return 0 }
	if lerr := linux.listen(fd, 1024); lerr != nil { linux.close(fd); return 0 }

	return net.TCP_Socket(fd)
}

on_accept :: proc(op: ^nbio.Operation, lane: ^Lane) {
	if op.accept.err != nil { return }
	client := op.accept.client
	// Re-arm accept on THIS lane's own socket. No cancel dance. TRADE-OFF vs WP71:
	// the kernel hashes each connection to ONE socket, so a connection hashed to a
	// lane blocked in a synchronous handler waits in that lane's backlog — it does
	// NOT migrate to a free lane the way the shared-socket + accept-cancel model
	// forced it to. This prototype measures the CPU/throughput GAIN of the model;
	// whether the WP71 health-check guarantee must be preserved (dedicated health
	// listener, eBPF reuseport steering, or accepting partial degradation) is a
	// separate decision, made only if the gain justifies the work.
	nbio.accept_poly(lane.listen, lane, on_accept)

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
	nbio.send_poly(c.socket, {RESP}, c, on_send)
}

on_send :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.send.err != nil {
		net.close(c.socket)
		free(c)
		return
	}
	arm_recv(c)
}
