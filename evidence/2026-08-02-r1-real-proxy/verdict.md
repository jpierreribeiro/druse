# R1-WP03 real proxy verdict

**Result: PASS for the controlled-pilot reference topology.**

- Caddy 2.11.4 was executed from the pinned linux/amd64 image digest.
- Valid CA/hostname negotiated HTTP/2 to Caddy; wrong CA and hostname were refused.
- Caddy-to-Druse was fixed to HTTP/1.1 with a bounded four-connection pool.
- The unbuffered stream delivered its first event before 800 ms; the buffered control delivered none in 1.2 s.
- Proxy and Druse body/header/time limits each won when configured as the stricter layer.
- Direct and edge XFF spoofing failed closed; the declared multi-hop chain resolved from the right.
- Saturation returned one bounded 502/503 with zero configured retries and recovered to 200.
- Readiness-aware shutdown admitted zero guarded handlers after draining became observable.
- HSTS belongs to Caddy; CSP/cookie attributes and unconditional secure headers belong to the app.
- Access logs retained the validated request ID and discarded request/response header maps.

This closes R1-WP03 for Caddy only. Another production proxy requires its own campaign.
