#!/bin/sh
# The receiving end of report-load.sh: an ssh forced command that stores one load report as
# <state_dir>/load/<tier>, "<epoch> <load>", stamped with this host's clock. In the controller
# account's ~/.ssh/authorized_keys:
#   command="/path/to/werkbank/controller/receive-load.sh /path/to/state_dir",restrict ssh-ed25519 AAAA... load reporter
# The tier comes from the reporter's ssh command line; anything but one load number is refused.
set -eu
dir=${1:?usage: receive-load.sh <state_dir> (as an ssh forced command)}
tier=${SSH_ORIGINAL_COMMAND:-}
case "$tier" in ''|*[!a-z0-9-]*) echo "bad tier: $tier" >&2; exit 2 ;; esac
IFS= read -r load || true
echo "$load" | grep -Eqx '[0-9]{1,4}(\.[0-9]{1,3})?' || { echo "bad load report" >&2; exit 2; }
mkdir -p "$dir/load"
printf '%s %s\n' "$(date +%s)" "$load" > "$dir/load/.$tier.tmp"
mv "$dir/load/.$tier.tmp" "$dir/load/$tier"
