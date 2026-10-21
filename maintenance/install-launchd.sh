#!/bin/bash
# Install (or refresh) the host watchdog as a macOS LaunchAgent, every 15 minutes. No sudo needed.
#   install-launchd.sh /path/to/deployment [label]
# Default label io.handarbeit.werkbank.maintenance; log ~/Library/Logs/<label>.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$(cd "${1:?usage: $0 /path/to/deployment [label]}" && pwd)"
LABEL=${2:-io.handarbeit.werkbank.maintenance}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HERE/host-maintenance.sh</string><string>$DEPLOY</string></array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the job is fully gone; bootstrapping too soon fails with error 5.
for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 1; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (every 15 min); log: $LOG"
