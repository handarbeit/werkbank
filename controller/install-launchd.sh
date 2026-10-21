#!/bin/bash
# Install (or reinstall) the overflow controller as a macOS LaunchAgent for the current user.
#   install-launchd.sh /path/to/overflow.json [label]
# Re-runnable. Default label dev.werkbank.overflow; log ~/Library/Logs/<label>.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$(cd "$(dirname "${1:?usage: $0 /path/to/overflow.json [label]}")" && pwd)/$(basename "$1")"
[ -f "$CFG" ] || { echo "no config at $CFG" >&2; exit 1; }
LABEL=${2:-dev.werkbank.overflow}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$HERE/overflow.py</string>
    <string>--config</string><string>$CFG</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL; log: $LOG"
