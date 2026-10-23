#!/bin/bash
# Recreate compose services one at a time, each only once its runner is idle, so a config change
# never kills a job. Run it from the deployment directory (where its compose.yml is), or point
# WERKBANK_DEPLOY at it. Usage: roll.sh [--dry-run] [--once] <service>...
#   --once: don't wait. Recreate the services that are idle now, skip the busy ones, and exit 1 if
#           any were skipped (the watchdog's runner upgrade calls it this way every run).
# Needs the `gh` CLI, logged in with read access to the runners it checks.
#
# "Idle" is decided three ways, all of which must agree twice, 20 s apart:
#   1. no Runner.Worker process in the container (a job is executing);
#   2. GitHub says the runner is not busy (it has been ASSIGNED a job, which shows up here up to
#      several seconds before Runner.Worker exists - the window a plain `ps` check misses;
#      a recreate that only did check 1 has cancelled a job in that window);
#   3. the runner is registered and online (a runner between jobs has no listener and no name).
# A job can still be assigned between the last check and the recreate; that window is now ~1 s.
set -uo pipefail
cd "${WERKBANK_DEPLOY:-.}" || exit 1
[ -f compose.yml ] || [ -f compose.yaml ] || [ -f docker-compose.yml ] || { echo "no compose file in $(pwd)" >&2; exit 2; }
DRY=0; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) DRY=1 ;; --once) ONCE=1 ;; *) break ;; esac; shift
done
[ $# -gt 0 ] || { echo "usage: $0 [--dry-run] [--once] <service>..." >&2; exit 2; }

idle_now() {
  local c=$1 name url slug
  docker exec "$c" sh -c 'ps -eo comm= | grep -qx Runner.Worker' 2>/dev/null && return 1
  name=$(docker exec "$c" sh -c 'grep -o "\"agentName\" *: *\"[^\"]*\"" /actions-runner/.runner 2>/dev/null' | sed 's/.*: *"\(.*\)"/\1/')
  url=$(docker exec "$c" sh -c 'grep -o "\"gitHubUrl\" *: *\"[^\"]*\"" /actions-runner/.runner 2>/dev/null' | sed 's/.*: *"\(.*\)"/\1/')
  [ -n "$name" ] && [ -n "$url" ] || return 1          # between jobs: registering; not idle
  slug=${url#https://github.com/}
  local scope=repos/$slug
  case "$slug" in */*) ;; *) scope=orgs/$slug ;; esac   # org-level runner
  [ "$(gh api "$scope/actions/runners?per_page=100" -q ".runners[]|select(.name==\"$name\")|\"\(.status) \(.busy)\"" 2>/dev/null)" = "online false" ]
}

# A service can have several replicas: it is idle only when every container is.
all_idle() {
  local ids c; ids=$(docker compose ps -q "$1"); [ -n "$ids" ] || return 1
  for c in $ids; do idle_now "$c" || return 1; done
}

skipped=0
for svc in "$@"; do
  idle=0
  while :; do
    if all_idle "$svc"; then sleep 20; all_idle "$svc" && { idle=1; break; }; fi
    [ "$ONCE" = 1 ] && break
    sleep 10
  done
  if [ "$idle" = 0 ]; then echo "$svc: busy, skipped"; skipped=1; continue; fi
  if [ "$DRY" = 1 ]; then echo "$svc: idle (dry run, not recreating)"; continue; fi
  docker compose up -d --no-build --no-deps "$svc" 2>&1 | tail -1
done
exit $skipped
