#!/bin/bash
# Install (or reinstall) report-load.sh as a macOS LaunchAgent that runs every minute.
#   install-load-reporter-launchd.sh <ssh destination> <tier> <ssh key> [label]
# Re-runnable. Default label io.handarbeit.werkbank.load-reporter; log ~/Library/Logs/<label>.log
# (written only when a report fails).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST=${1:?usage: $0 <ssh destination> <tier> <ssh key> [label]}; TIER=${2:?tier}; KEY=${3:?ssh key}
[ -f "$KEY" ] || { echo "no key at $KEY" >&2; exit 1; }
LABEL=${4:-io.handarbeit.werkbank.load-reporter}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>$HERE/report-load.sh</string>
    <string>$DEST</string><string>$TIER</string><string>$KEY</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 1; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL; failures logged to $LOG"
