#!/bin/bash
# Install (or reinstall) the overflow controller as a systemd user service on Linux.
#   install-systemd.sh /path/to/overflow.json [name]
# Re-runnable. Default name werkbank-overflow; logs: journalctl --user -u <name>.
# For it to run without a login session: sudo loginctl enable-linger "$USER".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$(cd "$(dirname "${1:?usage: $0 /path/to/overflow.json [name]}")" && pwd)/$(basename "$1")"
[ -f "$CFG" ] || { echo "no config at $CFG" >&2; exit 1; }
NAME=${2:-werkbank-overflow}
UNIT="$HOME/.config/systemd/user/$NAME.service"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<U
[Unit]
Description=werkbank overflow controller ($CFG)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 $HERE/overflow.py --config $CFG
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
U
systemctl --user daemon-reload
systemctl --user enable --now "$NAME.service"
echo "installed $NAME; logs: journalctl --user -u $NAME"
