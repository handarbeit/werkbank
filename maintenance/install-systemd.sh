#!/bin/bash
# Install (or refresh) the host watchdog as a systemd user timer on Linux, every 15 minutes.
#   install-systemd.sh /path/to/deployment [name]
# Default name werkbank-maintenance; logs: journalctl --user -u <name>.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$(cd "${1:?usage: $0 /path/to/deployment [name]}" && pwd)"
NAME=${2:-werkbank-maintenance}
D="$HOME/.config/systemd/user"; mkdir -p "$D"
cat > "$D/$NAME.service" <<U
[Unit]
Description=werkbank host watchdog ($DEPLOY)

[Service]
Type=oneshot
ExecStart=$HERE/host-maintenance.sh $DEPLOY
U
cat > "$D/$NAME.timer" <<U
[Unit]
Description=Run $NAME every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
U
systemctl --user daemon-reload
systemctl --user enable --now "$NAME.timer"
echo "installed $NAME.timer (every 15 min); logs: journalctl --user -u $NAME"
