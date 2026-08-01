#!/usr/bin/env python3
"""Bounded raw clients for the R1-WP02 resource drill."""

from __future__ import annotations

import argparse
import json
import socket
import time


def connect(port: int, timeout: float = 1.0) -> socket.socket:
    return socket.create_connection(("127.0.0.1", port), timeout=timeout)


def receive(sock: socket.socket, timeout: float = 3.0) -> bytes:
    sock.settimeout(timeout)
    data = bytearray()
    while True:
        try:
            chunk = sock.recv(65536)
        except (ConnectionResetError, TimeoutError, socket.timeout):
            break
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def status(raw: bytes) -> int:
    try:
        return int(raw.split(b"\r\n", 1)[0].split()[1])
    except (IndexError, ValueError):
        return 0


def request(port: int, path: str = "/health") -> int:
    try:
        with connect(port) as sock:
            sock.sendall(
                f"GET {path} HTTP/1.1\r\nHost: r1\r\nConnection: close\r\n\r\n".encode()
            )
            return status(receive(sock))
    except OSError:
        return 0


def saturation(port: int, budget: int, attempts: int) -> int:
    held: list[socket.socket] = []
    try:
        for _ in range(budget):
            sock = connect(port)
            # A deliberately incomplete request keeps the connection admitted
            # without executing application work or logging request data.
            sock.sendall(b"GET /health HTTP/1.1\r\nHost: r1\r\n")
            held.append(sock)
        time.sleep(0.25)
        probe_statuses = [request(port) for _ in range(attempts)]
    finally:
        for sock in held:
            sock.close()

    recovered = 0
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        recovered = request(port)
        if recovered == 200:
            break
        time.sleep(0.02)

    refused = sum(code != 200 for code in probe_statuses)
    print(
        json.dumps(
            {
                "held": len(held),
                "probes": attempts,
                "refused": refused,
                "recovery_status": recovered,
            },
            sort_keys=True,
        )
    )
    return 0 if refused > 0 and recovered == 200 else 1


def upload(port: int, size: int) -> int:
    try:
        with connect(port, timeout=2) as sock:
            sock.settimeout(5)
            sock.sendall(
                (
                    "POST /upload HTTP/1.1\r\nHost: r1\r\n"
                    f"Content-Length: {size}\r\nConnection: close\r\n\r\n"
                ).encode()
            )
            chunk = b"u" * 65536
            remaining = size
            while remaining:
                piece = chunk[: min(len(chunk), remaining)]
                try:
                    sock.sendall(piece)
                except (BrokenPipeError, ConnectionResetError):
                    break
                remaining -= len(piece)
            code = status(receive(sock, timeout=5))
    except OSError:
        code = 0
    print(json.dumps({"bytes": size, "status": code}, sort_keys=True))
    return 0


def slow_read(port: int, seconds: float) -> int:
    try:
        with connect(port) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            sock.sendall(
                b"GET /large HTTP/1.1\r\nHost: r1\r\nConnection: close\r\n\r\n"
            )
            time.sleep(seconds)
    except OSError:
        pass
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    req = sub.add_parser("request")
    req.add_argument("port", type=int)
    req.add_argument("path", nargs="?", default="/health")

    sat = sub.add_parser("saturation")
    sat.add_argument("port", type=int)
    sat.add_argument("budget", type=int)
    sat.add_argument("attempts", type=int, default=8, nargs="?")

    up = sub.add_parser("upload")
    up.add_argument("port", type=int)
    up.add_argument("size", type=int)

    slow = sub.add_parser("slow-read")
    slow.add_argument("port", type=int)
    slow.add_argument("seconds", type=float, nargs="?", default=4.0)

    args = parser.parse_args()
    if args.command == "request":
        code = request(args.port, args.path)
        print(json.dumps({"status": code}, sort_keys=True))
        return 0 if code else 1
    if args.command == "saturation":
        return saturation(args.port, args.budget, args.attempts)
    if args.command == "slow-read":
        return slow_read(args.port, args.seconds)
    return upload(args.port, args.size)


if __name__ == "__main__":
    raise SystemExit(main())
