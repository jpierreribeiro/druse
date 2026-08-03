"""R2-WP07 step 1 — the shadow driver.

Replays a production-SHAPED request mix at the candidate through the pinned
Caddy, over TLS, with keep-alive connection reuse and varied bodies, and
discards every response.

WHAT THIS IS AND IS NOT. `R2-restricted-production.md` §8 lists the canary
progression and its first step is "shadow ou replay sanitizado, sem resposta ao
usuário" — traffic in the shape of production, no user on the other end. That
step does not need real users, which is the reading that had R2-WP07 recorded as
blocked. Steps 2 through 6 (1%, 5%, 25%, 50%, 100% of real traffic) do, and this
file does not pretend otherwise.

This is a REPLAY, not a mirror. There is no live traffic to mirror, so the shape
is declared in `shadow-profile.md` with an origin per number rather than
sampled. A declared shape is weaker evidence than a mirrored one and the profile
says so in its own words.

THE CONTAINMENT CLAIM IS THE POINT. A shadow is safe because the topology cannot
deliver a response to a user, not because the driver intends to drop it. The
driver's part of that claim is the accounting it prints: every request it sent,
by route, so the proxy's access log can be reconciled against it with no
remainder. `run-shadow.sh` owns the rest — loopback-only binds, and the
reconciliation itself.
"""
import http.client
import json
import os
import random
import socket
import ssl
import sys
import time

CA = os.environ["DRUSE_SHADOW_CA"]
PORT = int(os.environ["DRUSE_SHADOW_PROXY_PORT"])
SECONDS = float(os.environ.get("DRUSE_SHADOW_SECONDS", "60"))
RATE = float(os.environ.get("DRUSE_SHADOW_RATE", "40"))
SEED = int(os.environ.get("DRUSE_SHADOW_SEED", "20260803"))

# The mix. Weights and body sizes are the profile's, and the profile carries the
# origin of each one. Changing a number here without changing the profile makes
# the evidence describe a shape no document declares.
MIX = [
    # (weight, method, path, body-bytes or None)
    (55, "GET", "/ok", None),
    (12, "GET", "/headers", None),
    (10, "POST", "/body", "small"),
    (8, "POST", "/body", "medium"),
    (5, "GET", "/whoami", None),
    (5, "GET", "/stream", None),
    (3, "POST", "/proxy-limit", "large"),
    (2, "GET", "/health", None),
]
BODY_BYTES = {"small": 240, "medium": 8 * 1024, "large": 200 * 1024}

# Requests per connection. Real clients do not open one connection per request
# and they do not hold one forever; the profile records where this came from.
REQUESTS_PER_CONNECTION = [1, 2, 4, 8, 16, 32]
REQUESTS_PER_CONNECTION_WEIGHTS = [10, 20, 30, 20, 15, 5]

rng = random.Random(SEED)
ctx = ssl.create_default_context(cafile=CA)

sent = {}
statuses = {}
errors = {}
response_bytes_discarded = 0
requests_total = 0


def body_for(kind):
    if kind is None:
        return None
    # JSON, because the supported profile's shape is an API rather than a file
    # server. The content is synthetic and carries nothing to sanitise, which is
    # the "sanitizado" half of §8 step 1 held by construction rather than by a
    # scrubber nobody can audit.
    #
    # The field is `data` because that is what the candidate's `/body` handler
    # binds (`Body_Input :: struct { data: string }`). The first shape sent here
    # used `name`, so `web.body` refused it and 79 of 359 requests — every single
    # POST — answered 400. The accounting still closed, because a 400 is a served
    # request; what it was not is production-shaped traffic. A shadow whose writes
    # all bounce off the binder exercises the transport and nothing above it.
    filler = "x" * max(0, BODY_BYTES[kind] - 32)
    return json.dumps({"data": filler}).encode()


def one_connection(deadline, interval):
    global response_bytes_discarded, requests_total
    # The edge is addressed as `proxy.test` — that is the name on its
    # certificate and the name its site block routes on — but it is listening on
    # loopback and no resolver knows it. So the HOST NAME drives SNI and the
    # `Host` header while the SOCKET goes to 127.0.0.1.
    #
    # Overriding `_create_connection` rather than editing /etc/hosts: a harness
    # that needs a system file changed to run is a harness that runs on one
    # machine.
    conn = http.client.HTTPSConnection("proxy.test", PORT, context=ctx, timeout=10)
    conn._create_connection = lambda _addr, *a, **k: socket.create_connection(
        ("127.0.0.1", PORT), timeout=10)
    n = rng.choices(REQUESTS_PER_CONNECTION, REQUESTS_PER_CONNECTION_WEIGHTS)[0]
    for _ in range(n):
        if time.monotonic() >= deadline:
            break
        weights = [m[0] for m in MIX]
        _, method, path, kind = rng.choices(MIX, weights)[0]
        payload = body_for(kind)
        headers = {"Host": "proxy.test", "Connection": "keep-alive"}
        if payload is not None:
            headers["Content-Type"] = "application/json"
        key = f"{method} {path}"
        try:
            conn.request(method, path, body=payload, headers=headers)
            resp = conn.getresponse()
            # READ AND DROP. The bytes are counted so the evidence can state how
            # much response data the shadow produced and destroyed, and are
            # never written anywhere.
            data = resp.read()
            response_bytes_discarded += len(data)
            statuses[str(resp.status)] = statuses.get(str(resp.status), 0) + 1
            sent[key] = sent.get(key, 0) + 1
            requests_total += 1
            if resp.getheader("Connection", "").lower() == "close":
                break
        except Exception as exc:                      # noqa: BLE001 — counted, not raised
            cls = type(exc).__name__
            errors[cls] = errors.get(cls, 0) + 1
            sent[key] = sent.get(key, 0) + 1
            requests_total += 1
            break
        time.sleep(interval)
    try:
        conn.close()
    except Exception:                                 # noqa: BLE001
        pass


def main():
    interval = 1.0 / RATE if RATE > 0 else 0.0
    deadline = time.monotonic() + SECONDS
    started = time.time()
    while time.monotonic() < deadline:
        one_connection(deadline, interval)
    finished = time.time()

    out = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(finished)),
        "seed": SEED,
        "target_rate_per_second": RATE,
        "requests_total": requests_total,
        "requests_by_route": sent,
        "statuses": statuses,
        "transport_errors": errors,
        "response_bytes_discarded": response_bytes_discarded,
        "responses_delivered_to_a_user": 0,
    }
    print(json.dumps(out, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
