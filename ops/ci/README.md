# VPS verification gate

This is the remote repetition of the mandatory local pre-push gate. It does
not use GitHub Actions and does not receive GitHub credentials: the Druse
repository is public and fetched read-only.

The verifier runs as the unprivileged `druse-ci` user. Every five minutes it
fetches `main`, archives a new commit into a fresh temporary
directory, runs `build/check.sh`, and records an atomic status plus the latest
log under `/var/lib/druse-ci`.

Installation outline for Ubuntu/Debian x86_64:

1. Install host prerequisites: `git`, `curl`, `tar`, and `clang`.
2. Create system user `druse-ci` and writable directories
   `/opt/druse-ci` and `/var/lib/druse-ci`.
3. Copy `run.sh` to `/opt/druse-ci/run.sh` and make it executable.
4. From a trusted checkout, run `install-odin.sh` with permission to create
   `/opt/druse`; it verifies the pinned SHA-256 and compiler commit.
5. Install the service and timer in `/etc/systemd/system/`.
6. Run `systemctl daemon-reload` and enable `druse-ci.timer`.

Optional `/etc/druse-ci.env` overrides:

```text
DRUSE_CI_BRANCH=main
DRUSE_CI_REPO_URL=https://github.com/jpierreribeiro/druse.git
DRUSE_ODIN_BIN=/opt/druse/odin
```

Check the last result with `/opt/druse-ci/status.sh` or inspect
`journalctl -u druse-ci.service`. No HTTP port, dashboard, token, or secret
is required.
