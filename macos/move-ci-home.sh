#!/usr/bin/env bash
# Move the macOS runners' user's home to another volume, e.g. an APFS volume Time Machine excludes,
# so its local snapshots don't pin what jobs delete: Xcode DerivedData, simulator devices,
# CocoaPods/pnpm/npm caches, Playwright browsers, temp files (docs/macos-host.md).
#
#   sudo bash macos/move-ci-home.sh /Volumes/CI/Users [user]      # user defaults to ci
#
# It waits until no runner is mid-job, stops the runners, logs the user out, copies the home with
# ditto, checks the copy, points the account at it and keeps the old home as <home>.old. Then
# re-run setup.sh (it rewrites the LaunchAgents for the new home) and log the user in again. Delete
# <home>.old once a job has passed. The Terminal running this may need Full Disk Access, because
# parts of a home's Library are protected.
set -euo pipefail

DEST_PARENT=${1:?usage: sudo bash $0 /Volumes/CI/Users [user]}
CI_USER=${2:-ci}
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
id "$CI_USER" >/dev/null 2>&1 || { echo "no user $CI_USER" >&2; exit 1; }
uid=$(id -u "$CI_USER")
old=$(dscl . -read "/Users/$CI_USER" NFSHomeDirectory | awk '{print $2}')
new="${DEST_PARENT%/}/$CI_USER"
[ "$old" != "$new" ] || { echo "$CI_USER's home is already $new"; exit 0; }
[ ! -e "$new" ] || { echo "$new already exists; move or delete it first" >&2; exit 1; }
[ ! -e "$old.old" ] || { echo "$old.old already exists; delete it first" >&2; exit 1; }

# 1. No job may be running: logging out kills it.
while pgrep -u "$CI_USER" -f 'bin/Runner.Worker' >/dev/null; do
  echo "waiting for the current job to finish…"; sleep 15
done

# 2. Stop the runners and end the user's session; nothing may write to the home while it's copied.
for plist in "$old"/Library/LaunchAgents/com.github.actions-runner.*.plist; do
  [ -e "$plist" ] && launchctl bootout "gui/$uid/$(basename "$plist" .plist)" 2>/dev/null || true
done
launchctl bootout "gui/$uid" 2>/dev/null || true
sleep 5
pkill -TERM -u "$CI_USER" 2>/dev/null || true
sleep 5
pkill -KILL -u "$CI_USER" 2>/dev/null || true
if pgrep -u "$CI_USER" >/dev/null; then
  echo "$CI_USER still has processes:" >&2; pgrep -lu "$CI_USER" >&2; exit 1
fi

# 3. Copy, keeping owners, permissions, ACLs and extended attributes, then compare.
mkdir -p "$DEST_PARENT"
echo "copying $old -> $new ($(du -sh "$old" | cut -f1))…"
ditto "$old" "$new"
n_old=$(find "$old" | wc -l); n_new=$(find "$new" | wc -l)
if [ "$n_old" -ne "$n_new" ]; then
  echo "copy incomplete: $n_old entries in $old, $n_new in $new; the account still uses $old" >&2
  exit 1
fi

# 4. Switch the account over; keep the old home until the runners have proved themselves.
dscl . -create "/Users/$CI_USER" NFSHomeDirectory "$new"
mv "$old" "$old.old"

# 5. Runner directories hold absolute links (bin, externals) into the old home.
for link in "$new"/actions-runners/*/bin "$new"/actions-runners/*/externals; do
  [ -L "$link" ] || continue
  target=$(readlink "$link")
  case "$target" in "$old"/*) ln -sfn "$new${target#"$old"}" "$link"; chown -h "$CI_USER" "$link";; esac
done

echo "$CI_USER's home is now $new (old copy: $old.old)."
echo "Next: sudo bash macos/setup.sh /path/to/macos-runners.conf, then log $CI_USER in once."
