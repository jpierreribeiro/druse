"""R2-WP06 — replay the framing corpus at Druse directly and through the proxy.

Reads the cases out of `tests/support/transport_conformance/corpus.odin` rather
than restating them: a second copy of the corpus would drift, and the point of
this comparison is that both legs see the SAME bytes.

Speaks raw sockets on both legs. `curl` normalises framing, which is the thing
under test.
"""
import os, re, socket, ssl, sys

CORPUS = os.environ["DRUSE_CORPUS"]
CA = os.environ["DRUSE_CA"]
ORIGIN_PORT = int(os.environ["DRUSE_ORIGIN_PORT"])
PROXY_PORT = int(os.environ["DRUSE_PROXY_PORT"])

# Odin string literals: "..." possibly concatenated with `+`. Escapes are the
# ones the corpus actually uses.
def unescape(s):
    return (s.replace('\\r', '\r').replace('\\n', '\n')
             .replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\'))

def load_cases(path):
    text = open(path).read()
    cases = []
    for block in re.findall(r'\{\s*\n(.*?)\n\t*\},', text, re.S):
        nm = re.search(r'name\s*=\s*"((?:[^"\\]|\\.)*)"', block)
        by = re.findall(r'bytes\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)', block)
        if not nm or not by:
            continue
        raw = "".join(unescape(p) for p in re.findall(r'"((?:[^"\\]|\\.)*)"', by[0]))
        if not raw:
            continue
        out = re.search(r'outcome\s*=\s*\.(\w+)', block)
        cases.append((nm.group(1), raw, out.group(1) if out else "?"))
    return cases

def speak(host, port, payload, tls, timeout=6.0):
    """Send bytes, read whatever comes back, report the first status line."""
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        if tls:
            ctx = ssl.create_default_context(cafile=CA)
            sock = ctx.wrap_socket(sock, server_hostname="proxy.test")
        sock.settimeout(timeout)
        sock.sendall(payload.encode("latin-1"))
        buf = b""
        while len(buf) < 65536:
            try:
                chunk = sock.recv(4096)
            except (socket.timeout, ssl.SSLError):
                break
            if not chunk:
                break
            buf += chunk
        sock.close()
    except Exception as exc:                      # noqa: BLE001 — reported, not raised
        return f"ERROR:{type(exc).__name__}"
    if not buf:
        return "CLOSED-NO-RESPONSE"
    first = buf.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    m = re.match(r"HTTP/\d\.\d (\d{3})", first)
    return m.group(1) if m else f"NON-HTTP:{first[:40]}"

cases = load_cases(CORPUS)
print(f"# cases parsed from the corpus: {len(cases)}")
print(f"# {'direct':<20} {'proxied':<20} case")
diverged = 0
for name, raw, outcome in cases:
    # The proxy leg must carry a Host the proxy will route on. Cases that set
    # their own Host are left untouched; the corpus writes `Host: localhost`,
    # which Caddy's site block does not match, so it is rewritten for the
    # proxied leg ONLY and the substitution is reported.
    proxied_raw = raw.replace("Host: localhost", "Host: proxy.test")
    d = speak("127.0.0.1", ORIGIN_PORT, raw, tls=False)
    p = speak("127.0.0.1", PROXY_PORT, proxied_raw, tls=True)
    flag = ""
    if d != p:
        diverged += 1
        flag = "  <-- DIVERGES"
    print(f"  {d:<20} {p:<20} {name}{flag}")
print(f"# diverged: {diverged} of {len(cases)}")
