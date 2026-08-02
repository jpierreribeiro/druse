#!/usr/bin/env python3
"""Low-rate R1 pilot load; emits aggregates only, never request data."""

import json
import socket
import ssl
import statistics
import sys
import time


def request(host, port, cafile, path):
    context = ssl.create_default_context(cafile=cafile)
    started = time.monotonic()
    raw = bytearray()
    with socket.create_connection((host, port), timeout=2) as tcp:
        with context.wrap_socket(tcp, server_hostname="proxy.test") as conn:
            conn.settimeout(2)
            conn.sendall(
                f"GET {path} HTTP/1.1\r\nHost: proxy.test\r\nConnection: close\r\n\r\n".encode()
            )
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                raw.extend(chunk)
    elapsed = (time.monotonic() - started) * 1000
    head, _, body = bytes(raw).partition(b"\r\n\r\n")
    status = int(head.split(b"\r\n", 1)[0].split()[1])
    bundle = ""
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"x-r1-bundle:"):
            bundle = line.split(b":", 1)[1].strip().decode("ascii")
    return status, bundle, body, elapsed


def main():
    host, port, cafile, expected_bundle = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    total = int(sys.argv[5]) if len(sys.argv) > 5 else 50
    latencies = []
    errors = 0
    unexpected = 0
    for _ in range(total):
        try:
            status, bundle, body, elapsed = request(host, port, cafile, "/pilot/work")
            latencies.append(elapsed)
            if status != 200 or bundle != expected_bundle or b"work=ok" not in body:
                unexpected += 1
        except Exception:
            errors += 1
        time.sleep(0.1)  # maximum offered rate: 10 requests/s

    ordered = sorted(latencies)
    p99 = ordered[max(0, min(len(ordered) - 1, int(len(ordered) * 0.99)))] if ordered else None
    result = {
        "requests": total,
        "responses": len(latencies),
        "errors": errors,
        "unexpected": unexpected,
        "p50_ms": round(statistics.median(latencies), 2) if latencies else None,
        "p99_ms": round(p99, 2) if p99 is not None else None,
        "offered_rps": 10,
    }
    print(json.dumps(result, sort_keys=True))
    if errors or unexpected or len(latencies) != total or p99 is None or p99 > 500:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
