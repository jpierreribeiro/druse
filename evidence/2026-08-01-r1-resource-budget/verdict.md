# R1-WP02 resource-budget verdict

Result: PASS for the measured controlled-pilot profile.

- Canonical idle process: 22 FDs, 9 threads, 9 io_uring/eventfd pairs.
- Derived LimitNOFILE: 1213 required; 2048 configured.
- Concurrent slow-reader peak in this run: 316908 KiB; 1 GiB remains above peak plus 200% headroom.
- Connection saturation refused all eight over-budget probes and recovered to HTTP 200.
- Process spool quota returned 503, cleaned the partial, then recovered to 201.
- systemd arms: passed (16 KiB memlock preflight refusal, OOM restart, crash-loop backstop, clean stop without restart).

Scope: one Linux process, one listener, eight handlers, 1024 max connections, 8 MiB response cap.
Changing any measured capacity invalidates this profile and requires a new run.
