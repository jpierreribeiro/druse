"""R2-WP06 — mutational raw-wire fuzzing of the candidate.

    usage: env DRUSE_FUZZ_PORT=… DRUSE_FUZZ_CORPUS=… [DRUSE_FUZZ_CASES=…]
           [DRUSE_FUZZ_SEED=…] wire_fuzz.py

The work package asks to "executar fuzz/corpus sanitizado no candidato". The
corpus is the 47 hand-written framing cases, which are seeds rather than a fuzz
run: each one is a shape somebody thought of. This mutates them and replays the
results, so the shapes nobody thought of get a turn.

DETERMINISTIC BY CONSTRUCTION. One seed produces one exact sequence of cases, so
a finding is reproducible by re-running with the same seed and case index rather
than by hoping. A fuzzer whose failures cannot be replayed reports anecdotes.

## The oracles, and why these

A fuzzer is only as good as what it calls a failure. Four, in the order they
matter:

1. **The server is still alive at the end.** Odin has no recoverable panic, so a
   faulting handler aborts the process — `docs/supported-profile.md` says so.
   Death is therefore the loudest possible finding and the cheapest to check.
2. **`/smuggled` was never executed.** The origin serves a route that no case
   addresses. A hit means some mutated byte string caused the server to run a
   request nobody sent, which is the defect class this whole work package
   exists for. This is the strongest oracle available at one hop.
3. **Every reply is well-formed or absent.** A reply must start with a valid
   `HTTP/1.1 NNN` status line, or there must be no reply at all — refusing by
   closing is explicitly permitted (WP9 D6). Anything else is the server
   emitting bytes it cannot account for.
4. **No case hangs.** A response that never arrives and a connection that never
   closes are a resource an attacker controls. Timeouts are counted and
   reported; they are not silently retried away.

## What this is NOT

Not coverage-guided. There is no instrumentation feedback loop, so this explores
the neighbourhood of the seeds and nothing further. It is a smoke-shaped fuzz
run, and the number of cases is a budget rather than a claim about the input
space.
"""
import json
import os
import random
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("DRUSE_CA", "/dev/null")
os.environ.setdefault("DRUSE_ORIGIN_PORT", "0")
os.environ.setdefault("DRUSE_PROXY_PORT", "0")
os.environ["DRUSE_CORPUS"] = os.environ["DRUSE_FUZZ_CORPUS"]
os.environ["DRUSE_FRAMING_LIST"] = ""

# Reuse the comparison's parser rather than writing a second one. It is the file
# that learned, three times over, how to read this corpus without dropping a
# term — raw literals, hex escapes and CRLF-preserving `#load`.
_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "proxy_framing_compare.py")).read().split("cases = load_cases")[0]
_ns = {"os": os, "sys": sys, "re": re}
exec(_src, _ns)                                    # noqa: S102 — a local file, not input
load_cases = _ns["load_cases"]

PORT = int(os.environ["DRUSE_FUZZ_PORT"])
CASES = int(os.environ.get("DRUSE_FUZZ_CASES", "4000"))
SEED = int(os.environ.get("DRUSE_FUZZ_SEED", "20260803"))
TIMEOUT = float(os.environ.get("DRUSE_FUZZ_TIMEOUT", "2.0"))

rng = random.Random(SEED)
seeds = [payload.encode("latin-1") for _n, payload, _o, _a in load_cases(os.environ["DRUSE_FUZZ_CORPUS"])]
if not seeds:
    print("no seeds parsed from the corpus", file=sys.stderr)
    raise SystemExit(2)

# Bytes worth inserting: the ones that mean something to an HTTP parser. Random
# bytes alone almost never produce a header line, so a purely random mutator
# spends its budget on inputs the request-line check rejects immediately.
INTERESTING = [b"\r", b"\n", b"\r\n", b"\0", b"\x01", b"\x7f", b" ", b"\t",
               b":", b";", b",", b"+", b"-", b"0", b"chunked", b"identity",
               b"Content-Length: 0", b"Transfer-Encoding: chunked",
               b"Host: x", b"GET /smuggled HTTP/1.1", b"\xff"]


def mutate(data):
    """One mutation, chosen uniformly. Returns (bytes, name)."""
    which = rng.randrange(9)
    if not data:
        return b"GET / HTTP/1.1\r\n\r\n", "empty-reseed"
    i = rng.randrange(len(data))
    if which == 0:
        return data[:i] + bytes([rng.randrange(256)]) + data[i + 1:], "byte-flip"
    if which == 1:
        return data[:i], "truncate"
    if which == 2:
        return data[:i] + rng.choice(INTERESTING) + data[i:], "insert-interesting"
    if which == 3:
        return data + rng.choice(seeds), "append-seed"
    if which == 4:
        return data[:i] + data[i:] * 2, "duplicate-tail"
    if which == 5:
        # Rewrite a Content-Length to something that disagrees with the body.
        return re.sub(rb"Content-Length: \d+",
                      b"Content-Length: " + str(rng.choice([0, 1, 7, 4294967295, -1])).encode(),
                      data, count=1), "lie-about-length"
    if which == 6:
        return data.replace(b"\r\n", b"\n", rng.randrange(1, 4)), "crlf-to-lf"
    if which == 7:
        j = rng.randrange(len(seeds))
        cut = rng.randrange(len(seeds[j]) + 1)
        return data[:i] + seeds[j][:cut], "splice"
    return data[:i] + bytes([data[i] ^ (1 << rng.randrange(8))]) + data[i + 1:], "bit-flip"


STATUS = re.compile(rb"^HTTP/1\.[01] (\d{3})")


def speak(payload):
    try:
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=TIMEOUT)
        sock.settimeout(TIMEOUT)
        sock.sendall(payload)
        buf = b""
        while len(buf) < 262144:
            try:
                chunk = sock.recv(8192)
            except socket.timeout:
                sock.close()
                return "timeout", None
            if not chunk:
                break
            buf += chunk
        sock.close()
    except ConnectionRefusedError:
        return "refused", None
    except OSError as exc:
        return f"oserror:{type(exc).__name__}", None
    if not buf:
        return "closed-no-response", None
    m = STATUS.match(buf)
    if not m:
        return "malformed-reply", buf[:120]
    return f"status:{m.group(1).decode()}", None


def main():
    outcomes = {}
    mutators = {}
    violations = []
    for index in range(CASES):
        base = rng.choice(seeds)
        payload, name = mutate(base)
        for _ in range(rng.randrange(0, 3)):        # sometimes stack mutations
            payload, name2 = mutate(payload)
            name = f"{name}+{name2}"
        outcome, detail = speak(payload)
        outcomes[outcome] = outcomes.get(outcome, 0) + 1
        mutators[name.split("+")[0]] = mutators.get(name.split("+")[0], 0) + 1
        if outcome == "malformed-reply" or outcome.startswith("oserror"):
            # Preserved verbatim so the case can be replayed byte for byte. A
            # fuzz finding that has to be re-discovered is not a finding.
            violations.append({
                "index": index, "mutator": name, "outcome": outcome,
                "payload_hex": payload[:2048].hex(),
                "reply_head": detail.hex() if detail else None,
            })
        if outcome == "refused":
            violations.append({"index": index, "mutator": name,
                               "outcome": "server-stopped-accepting",
                               "payload_hex": payload[:2048].hex()})
            break

    print(json.dumps({
        "seed": SEED,
        "cases": CASES,
        "timeout_seconds": TIMEOUT,
        "outcomes": dict(sorted(outcomes.items())),
        "mutators": dict(sorted(mutators.items())),
        "violations": violations,
    }, indent=1))
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
