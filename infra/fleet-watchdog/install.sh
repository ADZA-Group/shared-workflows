#!/usr/bin/env bash
# Installs the fleet-watchdog systemd service + daily timer on the Proxmox host.
set -e
D=/opt/fleet-watchdog
sed -i 's/\r$//' "$D/fleet-watchdog.sh"
chmod +x "$D/fleet-watchdog.sh"
# Log-only by default (report lands in journalctl). E-mail is opt-in: set
# ALERTS_ENABLED=1 here yourself to get the daily summary mailed (msmtp 'onecom').
printf 'ALERTS_ENABLED=0\n' > "$D/.env"
chmod 600 "$D/.env"

cat > /etc/systemd/system/fleet-watchdog.service <<'EOF'
[Unit]
Description=ADZA fleet LXC health + conservative maintenance
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/fleet-watchdog/fleet-watchdog.sh maintain
EOF

cat > /etc/systemd/system/fleet-watchdog.timer <<'EOF'
[Unit]
Description=Run fleet-watchdog daily (06:30 + jitter)

[Timer]
OnCalendar=*-*-* 06:30:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now fleet-watchdog.timer
echo "INSTALLED"
systemctl list-timers fleet-watchdog.timer --all --no-pager
