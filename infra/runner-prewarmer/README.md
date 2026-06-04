# runner-prewarmer (M2-Komp.2) — deploy + coordinate

Keeps self-hosted runners warm BEFORE the cost-switch flips to self-hosted, so the first
burst doesn't wait for cold starts. Runs on the **Proxmox host** (`192.168.1.20`); writes a
`min-floor` into LXC104 that the **runner-controller** honors. Idle warm runners cost only RAM
(plenty free), ~0 CPU. Spec: `docs/superpowers/specs/2026-06-04-ci-load-manager-design.md`.

## Prereqs (host)
- `jq` + `curl` (already installed for the watchdog).
- A read-only GitHub token (scope `read:org`) — the same one the watchdog uses works.

## Deploy
```bash
ssh root@192.168.1.20
mkdir -p /opt/runner-prewarmer
install -m 0755 prewarmer.sh /opt/runner-prewarmer/prewarmer.sh
cp .env.example /opt/runner-prewarmer/.env && chmod 600 /opt/runner-prewarmer/.env
$EDITOR /opt/runner-prewarmer/.env          # set GH_TOKEN
install -m 0644 runner-prewarmer.service /etc/systemd/system/
install -m 0644 runner-prewarmer.timer   /etc/systemd/system/
systemctl daemon-reload
```

## ✅ APPLIED 2026-06-04 — controller reads the floor (deployed + live)

> **Status:** the block below was inserted into `/opt/runner-controller/runner-controller.sh`
> in `scale()` right after the demand→`DESIRED` computation (backup:
> `runner-controller.sh.bak-prewarmer`). `bash -n` clean, controller restarted (4 runner units
> unaffected), both timers live. Prewarmer + controller are wired end-to-end (floor logic 7/7
> isolated tests; live floor=3 written + read, currently masked by demand=4). Kept here for
> reference / re-apply after a controller update.

The pre-warmer only HELPS once the `runner-controller` reads the floor. **This 1-block change into
`/opt/runner-controller/runner-controller.sh`** (owned by the CI-power-up session), where it
computes how many runners to keep / its scale-down minimum:

```bash
# honor an external pre-warm floor (absent/unreadable -> no override)
FLOOR="$(cat /run/runner-controller/min-floor 2>/dev/null || echo 0)"
case "$FLOOR" in (*[!0-9]*|"") FLOOR=0 ;; esac          # only accept a plain integer
EFFECTIVE_MIN="$MIN_RUNNERS"
[ "$FLOOR" -gt "$EFFECTIVE_MIN" ] && EFFECTIVE_MIN="$FLOOR"
# ...then use $EFFECTIVE_MIN instead of $MIN_RUNNERS as the scale-down floor.
```

Once that line is in, enable:
```bash
systemctl enable --now runner-prewarmer.timer
systemctl start runner-prewarmer.service               # one tick
pct exec 104 -- cat /run/runner-controller/min-floor   # see the floor value (1 normally)
journalctl -u runner-prewarmer -n 10 --no-pager
```

## Operate
```bash
systemctl list-timers runner-prewarmer.timer
journalctl -u runner-prewarmer -n 20 --no-pager
pct exec 104 -- cat /run/runner-controller/min-floor
```

## Update the deployed script after code changes
```bash
scp infra/runner-prewarmer/prewarmer.sh root@192.168.1.20:/opt/runner-prewarmer/prewarmer.sh
scp infra/runner-prewarmer/runner-prewarmer.{service,timer} root@192.168.1.20:/etc/systemd/system/
ssh root@192.168.1.20 'systemctl daemon-reload'
```
(`.gitattributes` pins LF so the shebang/units never arrive as CRLF.)
