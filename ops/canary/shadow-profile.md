# Shadow profile — R2-WP07 step 1

The shape the shadow replays, and where every number in it comes from.

**This file is the declaration; `shadow_replay.py` is the implementation.**
Changing a weight in one without the other makes the evidence describe a shape
no document declares, which is the failure mode `R2-WP02` §6.1 was written
against.

## 1. What step 1 is

`R2-restricted-production.md` §8 lists the canary progression and its first step
is *"shadow ou replay sanitizado, sem resposta ao usuário"*. That step is defined
by the absence of a user, so it needs no real traffic — the reading that had
R2-WP07 recorded as blocked was wrong. Steps 2 through 6 (1%, 5%, 25%, 50%,
100%) do need real traffic and this profile does not pretend to reach them.

**This is a replay, not a mirror.** There is no live traffic to mirror, so the
shape below is *declared* rather than sampled. A declared shape is weaker
evidence than a mirrored one, and the difference is not cosmetic: a mirror
carries the real distribution of paths, body sizes, header sets, client
concurrency and think time, and every one of those is a guess here.

## 2. Origin of every number

The three origins are `R2-WP02` §6.1's: `measured` (this repository measured it,
artefact cited), `inherited` (already committed as a criterion, file cited),
`declared` (a choice, with the reasoning; an invented number wearing a label).

| Parameter | Value | Origin |
|---|---|---|
| candidate | `tests/r1-real-proxy/server` | `inherited` — it is the fixture the pinned `ops/proxy/caddy/Caddyfile` is written against (`/stream`, `/proxy-limit`, `/proxy-timeout`, `/guarded`→`/ready`). Another app would be a different topology wearing the same proxy config |
| edge | pinned Caddy, `ops/proxy/caddy/image.env` | `inherited` — `docs/supported-profile.md` makes the reviewed reverse proxy the supported edge and names this one as the R1 reference |
| route mix | 55% `/ok`, 12% `/headers`, 10+8% `/body`, 5% `/whoami`, 5% `/stream`, 3% `/proxy-limit`, 2% `/health` | **`declared`.** No traffic exists to sample. The shape is "mostly cheap reads, a minority of writes, a little streaming, a trickle of health" because that is the shape `docs/supported-profile.md` describes as the supported workload. It is a guess with a stated reason, and it is the weakest number in this file |
| body sizes | 240 B / 8 KiB / 200 KiB | **`declared`**, bounded by things that are not: `limits.max_body` is 2 MiB in the fixture and the proxy's `/proxy-limit` route caps at 1 MB, so 200 KiB exercises a large body without touching either refusal path. Refusals belong to R2-WP06, not to a shadow |
| requests per connection | 1,2,4,8,16,32 weighted 10,20,30,20,15,5 | **`declared`.** Real clients neither open one connection per request nor hold one forever. The distribution's mode is 4 because the Caddyfile pins `keepalive_idle_conns_per_host 4` upstream, so it is at least anchored to a number the topology contains |
| offered rate | 40 req/s default | **`declared`**, and deliberately low. A shadow answers "does the composition work", not "how fast" — capacity is R2-WP05 and this must not be cited for it |
| duration | 60 s default | **`declared`.** Long enough for connection reuse and stream completion, short enough to run in a gate. Not a stability claim: R2-WP04 owns those |
| seed | 20260803, fixed | `decision`. A shadow whose mix differs run to run cannot have two runs compared |

**Nothing in the payloads is real data.** The bodies are synthetic JSON with a
padding field, so the "sanitizado" half of §8 step 1 holds by construction rather
than by a scrubber whose coverage nobody can audit.

## 3. Containment — what "no response to a user" is made of

Four properties, in `run-shadow.sh`. Three are asserted; one is a finding.

| # | Property | How it is obtained |
|---|---|---|
| K1 | the candidate's listen address | **recorded, not asserted** — see below |
| K1b | every peer that talked to the candidate was the proxy | observed by sampling established connections for the whole window |
| K2 | the pinned proxy publishes only to `127.0.0.1` | `docker inspect`, every `HostIp` must be loopback |
| K3 | the request accounting closes with no remainder | the proxy's access log reconciled against the driver's own count, with Caddy's `/ready` health probes declared and counted separately |

### K1 is a finding: Druse cannot bind to loopback

`web.serve(&app, port)` takes a port and no address, and the transport binds
dual-stack Any — `::`, falling back to `0.0.0.0`
(`web/internal/transport/odin_http_adapter.odin`). **There is no way to ask a
Druse application to listen on loopback only.**

For a shadow this removes the natural containment. For any deployment it means
the process is reachable on every interface the host has, and confining it is the
host's firewall's job rather than the application's — which is a real operational
constraint that `docs/supported-profile.md` does not currently state.

No API is invented here. Readiness rule G5: a plan may name a public need, it may
not invent a signature. The need is named in `R2-restricted-production.md` §8.1.

K1b is the substitute, and it is **weaker in kind**: a property holds always, an
observation holds over the window it observed. It is labelled that way in the
manifest so nobody reads `k1b_peer_observation=pass` as "the port was closed".

### K3 is the evidence

K1b and K2 are a fence; anyone can build a different fence. K3 is the claim that
survives being moved to another topology: *every request the edge served is one
the shadow sent*. A response that reached a user is a served request nobody in
this harness sent, and that shows up here as an unaccounted remainder rather than
as an absence somebody has to notice.

## 4. What a shadow run does NOT establish

- **Not capacity.** 40 req/s is offered load chosen so composition is the only
  variable. R2-WP05 owns the envelope.
- **Not stability.** Sixty seconds. R2-WP04 owns twelve hours.
- **Not a real-traffic result.** Declared shape, one client, one host, no client
  diversity, no CDN, no think-time distribution taken from anything real.
- **Not steps 2–6 of §8.** Those need real users and this reaches none of them.
- **Not a security result.** R2-WP06 owns the corpus, the proxy framing
  comparison and the endpoint review.
