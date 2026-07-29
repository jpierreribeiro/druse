# Framework `/ping` throughput harness

This is the smallest real Druse application used by the dedicated-accept
validation. The optional first argument sets `web.Limits.max_handlers`.

The measured four-core server build:

    odin build bench/framework_ping \
      -collection:druse=. \
      -o:speed \
      -out:/tmp/druse-framework-ping

Run the server on four cores:

    taskset -c 0-3 /tmp/druse-framework-ping 4

Run the load generator on the other four cores:

    taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      http://127.0.0.1:8080/ping

For the saturation point, repeat with `-c400`. Use `-o:speed`: `-o:minimal`
does not reproduce the release throughput class. On a two-box rig, replace
`127.0.0.1` with the server's private NIC address, give the server all eight
cores, and omit the `4` argument (or pass the actual CPU allocation).

Dedicated accept is the default. To build the retained rollback control, add
`-define:DRUSE_DEDICATED_ACCEPT=false`.

No runtime tuning is required for the measured path. The default also carries
the C-03-validated limit of two not-yet-consumed connection handoffs per lane.
Do not raise that private constant as a throughput tweak: values three, four
and eight reproduced healthy-client starvation under a high-rate RST flood,
while two stayed within 1.6% of eight in steady-state `/ping`.
