#!/usr/bin/env python3
"""Raw clients for R1-WP01. Output contains fixed lifecycle facts only."""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time


def connect(port: int) -> socket.socket:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1)
        except OSError:
            time.sleep(0.01)
    raise RuntimeError(f"port {port} did not accept")


def marker(path: str) -> None:
    with open(path, "w", encoding="ascii") as handle:
        handle.write("1\n")


def recv_to_eof(sock: socket.socket, timeout: float = 5) -> bytes:
    sock.settimeout(timeout)
    out = bytearray()
    while True:
        try:
            chunk = sock.recv(65536)
        except (ConnectionResetError, TimeoutError, socket.timeout):
            break
        if not chunk:
            break
        out.extend(chunk)
    return bytes(out)


def request(port: int, path: str, mark: str) -> int:
    with connect(port) as sock:
        sock.sendall(
            f"GET {path} HTTP/1.1\r\nHost: r1\r\nConnection: close\r\n\r\n".encode()
        )
        marker(mark)
        raw = recv_to_eof(sock)
    sys.stdout.buffer.write(raw)
    return 0


def keepalive(port: int, mark: str) -> int:
    with connect(port) as sock:
        sock.sendall(b"GET /health HTTP/1.1\r\nHost: r1\r\n\r\n")
        sock.settimeout(3)
        raw = sock.recv(4096)
        if b" 200 " not in raw:
            raise RuntimeError("keep-alive positive control did not receive 200")
        marker(mark)
        tail = recv_to_eof(sock)
    if tail:
        sys.stdout.buffer.write(tail)
    return 0


def slow_read(port: int, mark: str) -> int:
    with connect(port) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        sock.sendall(b"GET /large HTTP/1.1\r\nHost: r1\r\nConnection: close\r\n\r\n")
        marker(mark)
        # Do not read: the server must hit its write/drain bounds.
        time.sleep(4)
    return 0


def slow_upload(port: int, mark: str) -> int:
    total = 1024 * 1024
    with connect(port) as sock:
        head = (
            "POST /upload HTTP/1.1\r\nHost: r1\r\n"
            f"Content-Length: {total}\r\nConnection: close\r\n\r\n"
        ).encode()
        sock.sendall(head)
        sock.sendall(b"u" * (64 * 1024))
        marker(mark)
        recv_to_eof(sock, timeout=5)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("request", "keepalive", "slow-read", "slow-upload"))
    parser.add_argument("port", type=int)
    parser.add_argument("marker")
    parser.add_argument("path", nargs="?", default="/health")
    args = parser.parse_args()
    os.makedirs(os.path.dirname(args.marker), exist_ok=True)
    if args.kind == "request":
        return request(args.port, args.path, args.marker)
    if args.kind == "keepalive":
        return keepalive(args.port, args.marker)
    if args.kind == "slow-read":
        return slow_read(args.port, args.marker)
    return slow_upload(args.port, args.marker)


if __name__ == "__main__":
    raise SystemExit(main())
