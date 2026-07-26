# Framework `/ping` throughput harness

This is the smallest real Uruquim application used by the dedicated-accept
validation. The optional first argument sets `web.Limits.max_handlers`.

The measured four-core server build:

    odin build bench/framework_ping \
      -collection:uruquim=. \
      -o:speed \
      -out:/tmp/uruquim-framework-ping

Run the server on four cores:

    taskset -c 0-3 /tmp/uruquim-framework-ping 4

Run the load generator on the other four cores:

    taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      http://127.0.0.1:8080/ping

For the saturation point, repeat with `-c400`. Use `-o:speed`: `-o:minimal`
does not reproduce the release throughput class. On a two-box rig, replace
`127.0.0.1` with the server's private NIC address, give the server all eight
cores, and omit the `4` argument (or pass the actual CPU allocation).

Dedicated accept is the default. To build the retained rollback control, add
`-define:URUQUIM_DEDICATED_ACCEPT=false`.
