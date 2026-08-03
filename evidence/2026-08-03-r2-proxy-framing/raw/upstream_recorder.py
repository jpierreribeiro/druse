"""Record the exact bytes the proxy forwards upstream.

Answers the only question that decides whether the CL+TE hit is a smuggling
defect or a pipelined request: did Caddy send ONE request or TWO, and with what
framing? Nothing here parses cleverly -- it logs the raw bytes and answers a
minimal 200 per request so the proxy keeps going.
"""
import socket, sys, threading, time

PORT = int(sys.argv[1])
OUT = sys.argv[2]
lock = threading.Lock()


def log(text):
    with lock:
        with open(OUT, "a") as fh:
            fh.write(text)


def handle(conn, addr):
    conn.settimeout(3.0)
    seen = b""
    served = 0
    log(f"=== CONNECTION from {addr} ===\n")
    while True:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        seen += chunk
        log(f"--- RECV {len(chunk)} bytes ---\n{chunk!r}\n")
        # Answer once per complete header block observed in this chunk.
        n = chunk.count(b"\r\n\r\n")
        for _ in range(max(1, n)):
            try:
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                served += 1
            except OSError:
                break
    log(f"=== CLOSED, replies sent={served}, total bytes={len(seen)} ===\n")
    conn.close()


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(16)
open(OUT, "w").close()
deadline = time.time() + float(sys.argv[3] if len(sys.argv) > 3 else 20)
srv.settimeout(1.0)
while time.time() < deadline:
    try:
        c, a = srv.accept()
    except socket.timeout:
        continue
    threading.Thread(target=handle, args=(c, a), daemon=True).start()
