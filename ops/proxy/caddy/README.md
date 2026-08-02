# Caddy reference perimeter for the R1 pilot

This directory is the reviewed reverse-proxy topology for Druse's controlled
pilot. It is not a generic Caddy template.

## Identity and startup

`image.env` fixes Caddy by version, `linux/amd64` platform and immutable
Docker manifest digest. Pull the readable tag once, verify that its repo digest
matches the file, then run the digest reference:

```sh
docker pull caddy:2.11.4-alpine
docker image inspect caddy:2.11.4-alpine --format '{{json .RepoDigests}}'
```

The service must provide:

| Variable/mount | Contract |
|---|---|
| `DRUSE_UPSTREAM` | one explicit Druse `host:port`; never a client-controlled value |
| `DRUSE_PROXY_PORT` | TLS listener port; default 22443 is for the campaign |
| `DRUSE_PROXY_MAX_HEADER_SIZE` | public header cap; default 16 KiB |
| `DRUSE_PROXY_TRUSTED_INGRESS` | exact CDN/LB networks before Caddy; the TEST-NET default trusts no real peer |
| `/certs/server.pem` | public chain issued for the production hostname |
| `/certs/server-key.pem` | private key supplied by secret storage, never this repository |
| `/logs` | writable access-log directory with retention/collection outside Caddy |

Replace `proxy.test` and the campaign certificate paths in the deployed copy.
Run `caddy validate` using the pinned image before reload.

## Layer ownership

| Concern | Owner in this topology |
|---|---|
| TLS, HTTP/2, HSTS | Caddy |
| upstream HTTP/1.1 and four-connection pool | Caddy configuration |
| stream flushing | the dedicated Caddy `/stream` route |
| public header/body/response timeout | Caddy |
| inner request/body/write/drain bounds | Druse `web.Limits` |
| client identity | Caddy sanitizes the external chain; Druse trusts only Caddy's observed peer |
| CSP and cookie attributes | application |
| unconditional nosniff/frame/referrer headers | `web.secure_headers` |
| process memory/restart/kill | cgroup and systemd profile under `ops/deploy/` |

The `/buffered-stream` route is a negative campaign arm, not an application
route. Remove or isolate it from any deployed public routing table.

## Retry and failure contract

Every reverse-proxy handler fixes `lb_retries 0` and
`lb_try_duration 0s`. A new refused upstream connection therefore yields one
502/503 rather than a Caddy load-balancer retry loop.

The underlying Go transport has a narrower transparent behavior for a stale
connection that was previously successful. It retries only a replay-safe
request (`GET`, `HEAD`, `OPTIONS`, `TRACE`, or an idempotency-key
request) with no body or a replayable body. Because the idle pool is four, the
derived ceiling is four stale attempts plus one fresh attempt. Never mark
non-idempotent work with an idempotency key merely to hide a transport failure.

## Logs

The access log removes request and response header maps. A request ID is copied
to the top level only when it matches Druse's `[A-Za-z0-9._-]{1,64}` policy.
Authorization, Cookie, Set-Cookie and application headers must not appear.
Paths remain in the Caddy access log, so the deployed route design must not put
secrets in URLs and retention/access controls still apply.

## Verification

```sh
bash build/check_proxy_config.sh
bash ops/verification/run-real-proxy-contract.sh
```

The fast checker validates invariants and negative mutations. The real campaign
requires Docker plus the pinned image and exercises TLS/HTTP/2, pooling,
buffering, two-layer limits, XFF trust, saturation/recovery, graceful drain and
log redaction. A different proxy product, CDN chain or materially changed
topology requires a new real campaign; this evidence does not transfer by name.
