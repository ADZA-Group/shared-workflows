# runner-watchdog — deploy + verify

External watchdog for the CI cost-switch. Runs on the **Proxmox host** (`192.168.1.20`),
**outside** LXC104, and keeps the self-hosted runner alive + e-mails on unrecoverable failure.
Cost-hart: it **never** falls back to paid hosted. Spec:
`docs/superpowers/specs/2026-06-04-ci-runner-watchdog-design.md`.

## Why external

LXC104 is load-bearing (over free minutes → all CI runs there). If LXC104/the
`runner-controller` dies while over-quota, jobs stall silently — and a watchdog *inside*
Actions or *inside* LXC104 couldn't run to fix/report it. So it lives on the host.

## Current deployed state (2026-06-04) — SAFE MODE, pending 2 secrets

Deployed + **timer enabled** (`systemctl enable --now runner-watchdog.timer`, every 5 min):
- ✅ **LIVE now (no secrets needed):** container-down → `pct start`; controller-down →
  `systemctl restart runner-controller` — the two most common LXC104 failures, auto-healed.
- ⏳ **Gated until `GH_TOKEN` is set:** runner-count detection (`runners online`). Without a
  token the API is unreadable → `unknown` → **no escalation, no reboot** (safety by design —
  a token problem must never reboot a healthy runner).
- ⏳ **Gated until `/root/.msmtprc` exists:** the e-mail alert on unrecoverable failure.

Verified on host: manual tick logged `tick start → WARN unknown:online_api (skipping) → tick end`,
service exit 0, state `healthy`, 4 runners undisturbed.

## Finish activation (the 2 user secrets)

```bash
ssh root@192.168.1.20
# 1) GitHub token (scope read:org) so the watchdog can read runner status:
$EDITOR /opt/runner-watchdog/.env        # set GH_TOKEN=ghp_...   (chmod 600 already)
# 2) one.com SMTP for the alert mail:
$EDITOR /root/.msmtprc                    # account 'onecom' (host, smtp.one.com:587, user/pass), chmod 600
systemctl start runner-watchdog.service   # one tick to confirm: journalctl shows used/remain or healthy
```

Recommended: use a **dedicated fine-grained PAT (read-only org/runners)**, not a broad token.

## Operate

```bash
systemctl list-timers runner-watchdog.timer        # next run
journalctl -u runner-watchdog -n 30 --no-pager     # recent ticks
systemctl start runner-watchdog.service            # run one tick now
cat /var/lib/runner-watchdog/state                 # status / down_since / last_alert
```

## Controlled integration tests (run in a QUIET window — no CI jobs active)

1. **Heal Stufe 1 (controller restart, benign — does not kill running jobs):**
   `pct exec 104 -- systemctl stop runner-controller; systemctl start runner-watchdog.service`
   → journal must show `heal: restart controller`; controller `active` again.
2. **Heal Stufe 2 (reboot) — MAINTENANCE WINDOW, ensure `busy=0`:**
   `pct stop 104` → tick logs `heal: pct start`; container back. (Reboot path needs `GH_TOKEN`.)
3. **Alert path:** with a valid token but `GH_TOKEN` pointed at a stopped controller that won't
   recover → after heal, `🔴` mail; restore → `✅` recovery mail.
4. **Anti-spam:** two down-ticks within 6h → only the first mails.

## Update the deployed script after code changes

```bash
scp infra/runner-watchdog/watchdog.sh root@192.168.1.20:/opt/runner-watchdog/watchdog.sh
scp infra/runner-watchdog/runner-watchdog.{service,timer} root@192.168.1.20:/etc/systemd/system/
ssh root@192.168.1.20 'systemctl daemon-reload'   # units only
```
(`.gitattributes` pins LF so the shebang/units never arrive as CRLF.)
