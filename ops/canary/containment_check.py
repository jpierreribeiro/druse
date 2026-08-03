"""R2-WP07 K3 — reconcile what the edge served against what the shadow sent.

    usage: containment_check.py DRIVER_JSON PROXY_ACCESS_JSON

K1b and K2 are a fence, and anybody can build a different fence. This is the
claim that survives being moved to another topology: **every request the edge
served is one the shadow sent.** A response that reached a user is a served
request nobody in this harness sent, and it appears here as an unaccounted
remainder rather than as an absence somebody has to notice.

It lives in its own file rather than inside `run-shadow.sh` so that
`build/check_shadow_containment.sh` can drive it with fixtures. A containment
check that has only ever run on real input is a check nobody has seen fail.

Exit 0 and `containment=proven`, or non-zero with the remainder named.
"""
import collections
import json
import sys

# Caddy's active health checks for the `/guarded` upstream hit `/ready` on a
# 200 ms interval. They are the proxy talking to the candidate, not a user.
# DECLARED here and counted separately rather than subtracted quietly: an
# unexplained remainder is the entire signal this reconciliation produces, so
# the exemptions have to be a short list a reader can audit.
PROXY_INTERNAL = {"GET /ready"}


def load_served(path):
    served = collections.Counter()
    malformed = 0
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            req = entry.get("request") or {}
            method, uri = req.get("method"), req.get("uri")
            if method and uri:
                served[f"{method} {uri.split('?')[0]}"] += 1
            else:
                malformed += 1
    return served, malformed


def main(driver_path, access_path):
    driver = json.load(open(driver_path))
    sent = collections.Counter(driver["requests_by_route"])
    try:
        served, malformed = load_served(access_path)
    except FileNotFoundError:
        print("proxy_access_log=MISSING")
        print("containment=unproven")
        return 1

    probes = sum(served[r] for r in PROXY_INTERNAL)
    remainder = collections.Counter()
    for route, count in served.items():
        if route in PROXY_INTERNAL:
            continue
        delta = count - sent.get(route, 0)
        if delta:
            remainder[route] = delta

    print(f"driver_requests_sent={sum(sent.values())}")
    print(f"proxy_requests_served={sum(served.values())}")
    print(f"proxy_internal_health_probes={probes}")
    print(f"accounted={sum(served.values()) - probes}")
    print(f"malformed_access_log_lines={malformed}")
    for route in sorted(set(sent) | set(served)):
        print(f"route {route} sent={sent.get(route, 0)} served={served.get(route, 0)}")

    # An empty log is not a clean run. A shadow that sent requests and whose edge
    # logged none of them has an unreadable instrument, and "no remainder" would
    # be true of a file nobody wrote.
    if sum(sent.values()) > 0 and sum(served.values()) == 0:
        print("containment=unproven")
        print("problem=the driver sent requests and the proxy logged none; the "
              "reconciliation has nothing to reconcile against")
        return 1
    if malformed:
        print("containment=unproven")
        print(f"problem={malformed} access-log line(s) could not be read; a "
              "request this check cannot parse is a request it cannot account for")
        return 1
    if remainder:
        for route, delta in sorted(remainder.items()):
            print(f"UNACCOUNTED {route} delta={delta}")
        print("containment=broken")
        return 1

    print("responses_delivered_to_a_user=0")
    print("containment=proven")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
