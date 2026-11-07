#!/bin/sh
# Report this host's 5-minute load average to the overflow controller's host, for `tier_load`
# (docs/overflow.md, "Busy overflow hosts"). Run it every minute (install-load-reporter-launchd.sh).
#   report-load.sh <ssh destination> <tier> <ssh key>
# The key should be one the receiving account accepts only with receive-load.sh as a forced
# command, so all it can do is write this one number.
set -eu
dest=${1:?usage: $0 <ssh destination> <tier> <ssh key>}; tier=${2:?tier}; key=${3:?ssh key}
case "$(uname)" in
  Darwin) load=$(sysctl -n vm.loadavg | awk '{print $3}') ;;   # "{ 1m 5m 15m }"
  *)      load=$(awk '{print $2}' /proc/loadavg) ;;
esac
echo "$load" | ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
  -o ConnectTimeout=10 "$dest" "$tier"
