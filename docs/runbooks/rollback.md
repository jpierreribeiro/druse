# R1 controlled-pilot rollback

Rollback is a coordinated release-bundle switch. A bundle contains the binary,
`runtime-limits`, `pilot-profile`, Caddy configuration and their SHA-256
manifest. Changing only one component is a new, unverified topology.
The rollback target must remain inside `docs/supported-profile.md`.

## Preconditions

- The previous bundle remains immutable and its manifest verifies locally.
- The pilot uses no irreversible data migration. If a candidate requires one,
  it is outside R1 and must not be deployed.
- The active release is selected by one atomic `current` symlink (or an
  equivalent platform primitive) whose target is recorded before deployment.
- The operator can complete rollback and smoke within five minutes.

## Procedure

1. Record UTC abort reason, active target and active bundle manifest hash.
2. Close proxy admission and wait until readiness is false.
3. Send `SIGTERM`; allow the cooperative drain. If a Handler remains blocked,
   let `TimeoutStopSec` perform the documented kill and record the signal/status.
4. Verify the previous bundle manifest, then atomically repoint `current` to the
   previous directory. Do not edit either directory in place.
5. Reload the proxy and restart the service so binary and configuration change
   in the same operation.
6. Verify effective runtime preflight, binary/config hashes, health, readiness,
   allowed-route smoke, rejected-route smoke, client identity and one short
   stream through the proxy.
7. Verify no candidate process, listener or spool remains and that the previous
   bundle serves traffic. Keep the pilot closed unless the owner explicitly
   authorizes reopening.

## Roll-forward is not rollback

Building a third artifact during the incident is a roll-forward and needs a new
candidate campaign. Editing the active Caddyfile, runtime limits or unit is also
a roll-forward. Rollback uses only the previously verified bundle.

## Success criteria

- `current` targets the previous bundle and every manifest entry verifies;
- service and proxy report healthy/ready with the previous binary hash;
- route allowlist and data-integrity sentinel match the pre-deploy baseline;
- rollback elapsed time is at most five minutes;
- exit status, restart count and every manual command are in the UTC timeline.
