#!/usr/bin/env python3
"""Raw TLS/TCP probes for R1-WP03. Output is aggregate JSON only."""

import json
import socket
import ssl
import sys
import time


def tls_socket(host: str, port: int, cafile: str, servername: str):
    ctx = ssl.create_default_context(cafile=cafile)
    raw = socket.create_connection((host, port), timeout=4)
    wrapped = ctx.wrap_socket(raw, server_hostname=servername)
    wrapped.settimeout(7)
    return wrapped


def status_of(raw: bytes) -> int:
    line = raw.split(b"\r\n", 1)[0]
    try:
        return int(line.split()[1])
    except (IndexError, ValueError):
        return 0


def stream(host, port, cafile, servername, path, expect_buffered=False):
    started = time.monotonic()
    first = None
    data = bytearray()
    with tls_socket(host, port, cafile, servername) as sock:
        if expect_buffered:
            sock.settimeout(1.2)
        request = f"GET {path} HTTP/1.1\r\nHost: {servername}\r\nConnection: close\r\n\r\n"
        sock.sendall(request.encode("ascii"))
        while True:
            try:
                chunk = sock.recv(4096)
            except TimeoutError:
                break
            if not chunk:
                break
            data.extend(chunk)
            if first is None and b"data: event-1" in data:
                first = time.monotonic()
    ended = time.monotonic()
    result = {
        "status": status_of(data),
        "first_body_ms": None if first is None else round((first - started) * 1000, 1),
        "total_ms": round((ended - started) * 1000, 1),
        "events": data.count(b"data: event-"),
    }
    print(json.dumps(result, sort_keys=True))
    if expect_buffered:
        if first is not None or result["events"] != 0:
            raise SystemExit(1)
    elif result["status"] != 200 or result["events"] != 10 or first is None:
        raise SystemExit(1)


def slow_body(host, port, cafile, servername):
    payload = b"x" * 32
    started = time.monotonic()
    raw_response = bytearray()
    with tls_socket(host, port, cafile, servername) as sock:
        head = (
            f"POST /body HTTP/1.1\r\nHost: {servername}\r\n"
            f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n"
        )
        sock.sendall(head.encode("ascii"))
        for byte in payload:
            try:
                sock.sendall(bytes([byte]))
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                break
            time.sleep(0.15)
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                raw_response.extend(chunk)
        except (ConnectionResetError, socket.timeout, ssl.SSLError):
            pass
    result = {
        "status": status_of(raw_response),
        "elapsed_ms": round((time.monotonic() - started) * 1000, 1),
    }
    print(json.dumps(result, sort_keys=True))


def header(host, port, cafile, servername, size):
    with tls_socket(host, port, cafile, servername) as sock:
        request = (
            f"GET /ok HTTP/1.1\r\nHost: {servername}\r\n"
            f"X-R1-Large: {'x' * size}\r\nConnection: close\r\n\r\n"
        )
        sock.sendall(request.encode("ascii"))
        response = bytearray()
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
        except (ConnectionResetError, socket.timeout, ssl.SSLError):
            pass
    result = {"status": status_of(response), "header_bytes": size}
    print(json.dumps(result, sort_keys=True))


def hold(port, count, ready):
    sockets = []
    try:
        for _ in range(count):
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            sock.sendall(b"GET /ok HTTP/1.1\r\nHost: hold\r\nX-Hold: ")
            sockets.append(sock)
        with open(ready, "w", encoding="ascii") as marker:
            marker.write(f"{len(sockets)}\n")
        time.sleep(8)
    finally:
        for sock in sockets:
            sock.close()


def main():
    mode = sys.argv[1]
    if mode == "stream":
        stream(
            sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6],
            len(sys.argv) > 7 and sys.argv[7] == "buffered",
        )
    elif mode == "slow-body":
        slow_body(sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5])
    elif mode == "header":
        header(sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], int(sys.argv[6]))
    elif mode == "hold":
        hold(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
