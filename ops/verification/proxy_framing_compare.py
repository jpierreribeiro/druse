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

# Odin string literals: "..." possibly concatenated with `+`.
#
# ONE PASS, NOT A CHAIN OF `.replace()`. The first version of this chained five
# replaces and silently dropped `\xNN`, which the corpus uses in exactly three
# cases — the NUL in a field value, the C0 control in a field value, and the
# control byte in a field NAME. Those three went on the wire as the literal
# four characters `\`, `x`, `0`, `0`, which is a perfectly well-formed header,
# and Druse answered 200. Read as a result that said "Druse accepts a NUL in a
# header value"; it said nothing of the sort, and the corpus's own suite has
# always passed them.
#
# Readiness rule G2: an instrument failure reproves the campaign, not the
# product. A chain of replaces also double-unescapes — `\\r` becomes a real CR
# instead of backslash-r — so the single pass fixes a second latent fault that
# the corpus has not happened to exercise yet.
_ESCAPES = {'r': '\r', 'n': '\n', 't': '\t', '"': '"', '\\': '\\',
            'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0', 'e': '\x1b'}


def unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != '\\' or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        nxt = s[i + 1]
        if nxt == 'x' and i + 3 < len(s):
            out.append(chr(int(s[i + 2:i + 4], 16)))
            i += 4
        elif nxt in _ESCAPES:
            out.append(_ESCAPES[nxt])
            i += 2
        else:
            # An escape this parser does not know must not be guessed at: a
            # wrong byte on the wire is a wrong answer about framing.
            raise SystemExit(f"corpus escape not handled: \\{nxt!r}")
    return "".join(out)

# Odin has TWO string literal forms and the corpus uses both: interpreted
# `"..."`, and RAW `` `...` `` where nothing is an escape. The bodies are raw
# literals — ``{"name":"grace"}`` — precisely so the JSON's own quotes need no
# escaping.
#
# The first version of this parser only knew the double-quoted form, so every
# case whose payload ended in a raw-literal body was TRUNCATED at the header
# terminator. Druse then waited for sixteen body bytes that never arrived and
# closed on its read deadline, and the table recorded `CLOSED-NO-RESPONSE` for
# "valid Content-Length body" — a valid request the suite has always passed. The
# proxied leg answered 504 for the same reason. Eight of forty-seven rows were
# fiction, and all eight looked like findings.
#
# Readiness rule G2 again: a failure of the instrument reproves the campaign, not
# the product. The `agrees()` check further down exists so this class of fault
# announces itself instead of being read as a result.
_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"' r'|`([^`]*)`', re.S)


def _bytes_expression(block):
    """The whole right-hand side of `bytes = ...`, up to the next field."""
    m = re.search(r'bytes\s*=\s*', block)
    if not m:
        return None
    rest = block[m.end():]
    # The expression ends at the comma that closes it — the one followed by a
    # newline and the next `field =`. Literals may contain commas, so cut on the
    # field boundary rather than on the first comma.
    end = re.search(r',\s*\n\s*\w+\s*=', rest)
    return rest[:end.start()] if end else rest


# Two cases build their payload from a CONSTANT rather than a literal:
# `OVERSIZED_HEADER_VALUE` and `MANY_HEADER_LINES`, each `#load`ed from a file
# next to the corpus. A literal-only parser drops the term and sends
# `X-Big: \r\n` — a small, perfectly valid request that answers 200, which is
# how the two F-005 cases came back "the direct leg disagrees with the corpus"
# when the direct leg had done nothing wrong.
#
# Both halves matter: resolve the ones that CAN be resolved, and refuse to
# replay any case whose expression still holds a term this parser cannot
# evaluate. Sending a silently shortened payload is how a framing harness
# reports fiction, and this file has now done it twice.
_LOAD = re.compile(r'(\w+)\s*::\s*#load\("([^"]+)"')


def _constants(text, corpus_path):
    out = {}
    for name, filename in _LOAD.findall(text):
        try:
            # BINARY, decoded byte-for-byte. Text mode applies universal-newline
            # translation, which rewrites every CRLF in the file as a bare LF —
            # and this is a FRAMING harness, where CRLF versus LF is the thing
            # under test. That translation silently turned the many-header-lines
            # payload into bare-LF headers, Druse rejected it exactly as the
            # corpus's own "bare LF line termination is rejected" case requires,
            # and the table reported that F-005's fix had a hole in it.
            #
            # Third instrument defect in this file, and all three read as product
            # findings: dropped `\xNN` escapes, dropped raw literals, and now
            # rewritten line endings. G2 exists for this.
            with open(os.path.join(os.path.dirname(corpus_path), filename), "rb") as fh:
                out[name] = fh.read().decode("latin-1")
        except OSError:
            pass
    return out


def _terms(expr, constants):
    """Walk a `"a" + CONST + `b`` expression left to right.

    Sequential rather than clever: a regex that splits on `+` has to know which
    plus signs are inside a literal, and getting that subtly wrong is how a
    payload loses a term without anybody noticing. This scans, so order is
    preserved and anything it cannot read is REPORTED instead of dropped.
    """
    parts, unresolved = [], []
    i = 0
    while i < len(expr):
        c = expr[i]
        if c in ' \t\r\n+':
            i += 1
        elif c == '"':
            m = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S).match(expr, i)
            if not m:
                unresolved.append("unterminated-quoted-literal")
                break
            parts.append(unescape(m.group(1)))
            i = m.end()
        elif c == '`':
            end = expr.find('`', i + 1)
            if end < 0:
                unresolved.append("unterminated-raw-literal")
                break
            parts.append(expr[i + 1:end])
            i = end + 1
        elif c == '/' and expr[i:i + 2] == '//':
            i = expr.find('\n', i)
            if i < 0:
                break
        else:
            m = re.compile(r'\w+').match(expr, i)
            if not m:
                unresolved.append(f"unparsable:{expr[i:i+20]!r}")
                break
            name = m.group(0)
            if name in constants:
                parts.append(constants[name])
            else:
                unresolved.append(name)
            i = m.end()
    return parts, unresolved


def load_cases(path):
    text = open(path).read()
    constants = _constants(text, path)
    cases = []
    skipped = []
    for block in re.findall(r'\{\s*\n(.*?)\n\t*\},', text, re.S):
        nm = re.search(r'name\s*=\s*"((?:[^"\\]|\\.)*)"', block)
        expr = _bytes_expression(block)
        if not nm or expr is None:
            continue
        parts, unresolved = _terms(expr, constants)
        payload = "".join(parts)
        if unresolved:
            skipped.append((nm.group(1), unresolved))
            continue
        if not payload:
            continue
        out = re.search(r'outcome\s*=\s*\.(\w+)', block)
        allowed = re.search(r'allowed_status\s*=\s*\{([^}]*)\}', block)
        statuses = [s.strip() for s in allowed.group(1).split(",") if s.strip()] if allowed else []
        cases.append((nm.group(1), payload, out.group(1) if out else "?", statuses))
    if skipped:
        for name, terms in skipped:
            print(f"# SKIPPED (unresolvable payload term {terms}): {name}")
        print(f"# {len(skipped)} case(s) NOT replayed; they are not passes",
              file=sys.stderr)
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

# ISOLATION MODE. The combined pass below sends all 47 cases through one
# long-lived pair, so a `/smuggled` hit at the origin belongs to the RUN and to
# no case in particular — which is exactly the state R2-WP06 was left in. These
# two switches let the runner replay one case at a time against a freshly
# started origin, which makes the hit attributable by construction.
#
# `DRUSE_FRAMING_LEG` matters as much as `ONLY`: an isolation pass that also
# speaks the direct leg would let the direct leg's request be the one that hits
# `/smuggled`, and the whole question is which HOP delivered it.
ONLY = os.environ.get("DRUSE_FRAMING_ONLY", "")
LEG = os.environ.get("DRUSE_FRAMING_LEG", "both")

# The runner drives the isolation pass one case at a time and needs the list of
# names. It reads them from HERE rather than parsing the corpus a second time,
# so the isolation pass cannot iterate a different set of cases than the
# comparison it is explaining.
if os.environ.get("DRUSE_FRAMING_LIST"):
    for _name, _raw, _outcome, _allowed in cases:
        print(_name)
    sys.exit(0)
if ONLY:
    cases = [c for c in cases if c[0] == ONLY]
    if not cases:
        print(f"# no case named {ONLY!r} in the corpus", file=sys.stderr)
        sys.exit(2)

print(f"# cases parsed from the corpus: {len(cases)}")
print(f"# {'direct':<20} {'proxied':<20} {'declared':<22} case")


def agrees(status, outcome, allowed):
    """Does the DIRECT leg match what the corpus declares for this case?

    Printed because a divergence table read on its own invites the wrong
    question. The interesting column is not "do the two legs differ" — a proxy
    that rejects malformed framing before Druse sees it differs by design and is
    the common case. It is "does Druse alone still do what the corpus says",
    because if it does not, the harness is broken or the product regressed and
    neither is a proxy finding.
    """
    # `allowed_status` is the corpus's own answer and it wins whenever the case
    # states one. Deriving the expectation from `outcome` alone read `.Ok` as
    # "answers 2xx", which failed the case whose whole point is that an unknown
    # method reaches the core and is answered 405 BY the core rather than 501 by
    # a backend. The corpus already said `allowed_status = {405}`; the check was
    # simply not reading it.
    if allowed:
        return status in allowed
    if outcome == "Ok":
        return status.isdigit() and status.startswith("2")
    if outcome == "Rejected_With_Status":
        return status.isdigit() and int(status) >= 400
    if outcome == "Rejected":
        return status == "CLOSED-NO-RESPONSE" or (status.isdigit() and int(status) >= 400)
    return True


diverged = 0
direct_disagrees = []
for name, raw, outcome, allowed in cases:
    # The proxy leg must carry a Host the proxy will route on. Cases that set
    # their own Host are left untouched; the corpus writes `Host: localhost`,
    # which Caddy's site block does not match, so it is rewritten for the
    # proxied leg ONLY and the substitution is reported.
    proxied_raw = raw.replace("Host: localhost", "Host: proxy.test")
    d = speak("127.0.0.1", ORIGIN_PORT, raw, tls=False) if LEG in ("both", "direct") else "-"
    p = speak("127.0.0.1", PROXY_PORT, proxied_raw, tls=True) if LEG in ("both", "proxy") else "-"
    flag = ""
    if LEG != "both":
        print(f"  {d:<20} {p:<20} {name}")
        continue
    if d != p:
        diverged += 1
        flag = "  <-- DIVERGES"
    if not agrees(d, outcome, allowed):
        direct_disagrees.append(name)
        flag += "  <-- DIRECT DISAGREES WITH THE CORPUS"
    print(f"  {d:<20} {p:<20} {outcome:<22} {name}{flag}")
print(f"# diverged: {diverged} of {len(cases)}")
print(f"# direct leg disagreeing with the corpus: {len(direct_disagrees)}")
for name in direct_disagrees:
    print(f"#   {name}")
if direct_disagrees:
    # Loud, because it invalidates the comparison rather than adding to it: the
    # proxy column is only readable next to a direct column that still behaves
    # the way the corpus says Druse behaves.
    print("# THE DIRECT LEG DISAGREES WITH THE CORPUS. Fix the harness or the "
          "product before reading the proxy column.", file=sys.stderr)
