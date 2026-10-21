#!/bin/bash
# Disk watchdog and cache hygiene for a werkbank deployment. Run every 15 minutes by launchd
# (install-launchd.sh) or a systemd timer; safe to run by hand:
#   host-maintenance.sh /path/to/deployment
# The deployment directory holds its compose.yml and .env, and optionally overflow.json and a
# maintenance.env that overrides the settings below (WARN_GB=20, SNAPSHOT_KEEP_HOURS=4, ...).
#
# Every run:  (macOS) delete Time Machine local snapshots older than SNAPSHOT_KEEP_HOURS.
#             check free disk space.
#   < WARN_GB   notify.
#   < STOP_GB   stop the Linux runners so CI cannot fill the disk to zero: a full disk can
#               stop the Docker VM itself and take every runner down mid-job.
#   >= START_GB start them again if this script was what stopped them.
# Once a day, only while no runner is mid-job:
#   the shared cache volume is wiped if it exceeds CACHE_MAX_GB (it refills
#   on demand), and dangling Docker images are pruned.
set -uo pipefail

WERKBANK="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(cd "${1:-${WERKBANK_DEPLOY:?usage: $0 /path/to/deployment}}" && pwd)" || exit 1
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$DIR" || exit 1

WARN_GB=15
STOP_GB=5
START_GB=10
CACHE_MAX_GB=12
SNAPSHOT_KEEP_HOURS=2
# The runner image (for throwaway containers on the cache volume) and that volume's name: compose
# prefixes volumes with the project name, which defaults to the deployment directory's name.
IMAGE=$(grep -s '^WERKBANK_IMAGE=' .env | cut -d= -f2-); IMAGE=${IMAGE:-werkbank-runner:local}
CACHE_VOLUME="$(basename "$DIR" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')_runner-caches"
OVERFLOW_CONFIG="$DIR/overflow.json"
if [ "$(uname)" = Darwin ]; then STATE="$HOME/Library/Application Support/werkbank"
else STATE="${XDG_STATE_HOME:-$HOME/.local/state}/werkbank"; fi
# shellcheck disable=SC1091
[ -f maintenance.env ] && . ./maintenance.env
mkdir -p "$STATE"

log()    { echo "$(date '+%F %T') $*"; }
notify() {
  if command -v osascript >/dev/null; then
    osascript -e "display notification \"$1\" with title \"CI runners\"" >/dev/null 2>&1 || true
  else
    command -v logger >/dev/null && logger -t werkbank "$1"
  fi
}
# `timeout` is GNU coreutils (Homebrew on macOS); run without a limit where it is missing.
to() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }
free_gb() { df -Pk / | awk 'NR==2 {print int($4 / 1048576)}'; }

# --- Time Machine local snapshots (macOS) ---------------------------------------
# Time Machine takes an hourly whole-volume snapshot and keeps each for 24 h. Every one pins
# whatever CI deletes after it (OrbStack's disk image rewrites, containers, caches), and a day of
# them has held well over 100 GB on a busy runner host. A snapshot can't exclude a directory, so
# keep only the last SNAPSHOT_KEEP_HOURS. Backups on the Time Machine disk are untouched. Runs
# before the docker check so it works with Docker down. See docs/macos-host.md.
[ "$(uname)" = Darwin ] && cutoff=$(date -v-"${SNAPSHOT_KEEP_HOURS}"H +%Y-%m-%d-%H%M%S) && for d in $(to 60 tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$'); do
  if [[ "$d" < "$cutoff" ]]; then
    to 120 tmutil deletelocalsnapshots "$d" >/dev/null 2>&1 \
      && log "deleted local snapshot $d (older than ${SNAPSHOT_KEEP_HOURS}h)" \
      || log "could not delete local snapshot $d"
  fi
done

docker info >/dev/null 2>&1 || { log "docker not reachable; skipping"; exit 0; }

busy_runners() {
  for c in $(docker compose ps -q 2>/dev/null); do
    docker exec "$c" sh -c 'ps -eo comm= | grep -qx Runner.Worker' 2>/dev/null && echo "$c"
  done
}

# --- disk watchdog ---------------------------------------------------------
free=$(free_gb)
# Time Machine's hourly local snapshots keep everything CI deletes, so space
# freed by cleanup (ours or the runners') does not come back until they
# expire. Under pressure, thin them first; backups on the TM disk are kept.
if [ "$free" -lt "$WARN_GB" ] && command -v tmutil >/dev/null; then
  tmutil thinlocalsnapshots / 50000000000 4 >/dev/null 2>&1 \
    && log "free ${free}G: thinned local snapshots -> $(free_gb)G"
  free=$(free_gb)
fi
if [ "$free" -lt "$STOP_GB" ]; then
  if [ ! -f "$STATE/stopped-for-disk" ]; then
    docker compose stop -t 60 >/dev/null 2>&1
    touch "$STATE/stopped-for-disk"
    log "free ${free}G < ${STOP_GB}G: Linux runners STOPPED"
    notify "Disk nearly full (${free} GB free). Linux CI runners stopped until space is freed."
  fi
elif [ -f "$STATE/stopped-for-disk" ] && [ "$free" -ge "$START_GB" ]; then
  docker compose up -d >/dev/null 2>&1
  rm -f "$STATE/stopped-for-disk"
  log "free ${free}G: Linux runners restarted"
  notify "Disk space recovered (${free} GB free). Linux CI runners restarted."
elif [ "$free" -lt "$WARN_GB" ]; then
  # At most one warning an hour.
  if [ -z "$(find "$STATE/warned" -mmin -60 2>/dev/null)" ]; then
    touch "$STATE/warned"
    log "free ${free}G < ${WARN_GB}G: warning"
    notify "Disk space low: ${free} GB free."
  fi
fi

# --- pnpm 11+ self-install check -------------------------------------------
# pnpm 11+ installs itself into the shared store (v11/links). Its native binary is a
# hardlink of a store file, and pnpm/action-setup's version switching can overwrite that file
# with a 3.5 KB placeholder script, after which every job dies in "Setup pnpm"
# (ERR_PNPM_BROKEN_PNPM_INSTALL) and nothing repairs it (docs/pnpm.md). Detect a placeholder-sized binary that is older than a first download
# could plausibly still be replacing it, and drop v11 (it refills, ~1 GB).
broken=$(docker run --rm -v "$CACHE_VOLUME":/caches --entrypoint sh "$IMAGE" -c \
  'find /caches/pnpm-store/v11/links/@pnpm -path "*/node_modules/@pnpm/exe.*/pnpm" -type f -size -1000k -mmin +10 2>/dev/null | head -1')
if [ -n "$broken" ]; then
  docker run --rm -v "$CACHE_VOLUME":/caches --entrypoint sh "$IMAGE" -c 'rm -rf /caches/pnpm-store/v11'
  log "broken pnpm self-install in the shared store ($broken): wiped pnpm-store/v11"
  notify "Wiped a broken pnpm store (v11); it refills on the next job."
fi

# --- overflow controller heartbeat --------------------------------------------
# controller/overflow.py writes a heartbeat every tick (only if this deployment runs it). If it stops, overflow runners stay
# hidden (safe, but the spill-over capacity is gone), so say so, at most once an hour.
# Under host pressure it also hides idle primary runners (`orb-shed`), and those do NOT come back
# on their own, so a stale heartbeat also restores them (`overflow.py --restore`, every run).
hb_dir=$( [ -f "$OVERFLOW_CONFIG" ] && /usr/bin/python3 -c 'import json,os,sys
c = json.load(open(sys.argv[1]))
d = "~/Library/Application Support/werkbank/overflow" if sys.platform == "darwin" else "~/.local/state/werkbank/overflow"
print(os.path.expanduser(c.get("state_dir", d)))' "$OVERFLOW_CONFIG")
hb="${hb_dir:-/nonexistent}/heartbeat"
if [ -f "$hb" ] && [ -n "$(find "$hb" -mmin +5 2>/dev/null)" ]; then
  /usr/bin/python3 "$WERKBANK/controller/overflow.py" --config "$OVERFLOW_CONFIG" --restore 2>&1 | sed 's/^/overflow --restore: /'
  if [ -z "$(find "$STATE/overflow-warned" -mmin -60 2>/dev/null)" ]; then
    touch "$STATE/overflow-warned"
    log "overflow controller heartbeat is stale: $(cat "$hb")"
    notify "CI overflow controller has stopped; slower runners stay hidden until it is back."
  fi
fi

# --- daily cache hygiene ---------------------------------------------------
[ -n "$(find "$STATE/daily" -mmin -1440 2>/dev/null)" ] && exit 0
if [ -n "$(busy_runners)" ]; then
  log "daily hygiene deferred: a runner is mid-job"
  exit 0
fi
cache_mb=$(docker run --rm -v "$CACHE_VOLUME":/caches --entrypoint sh "$IMAGE" \
  -c 'du -sm /caches 2>/dev/null | cut -f1')
if [ "${cache_mb:-0}" -gt $((CACHE_MAX_GB * 1024)) ]; then
  docker compose stop -t 60 >/dev/null 2>&1
  docker run --rm -v "$CACHE_VOLUME":/caches --entrypoint sh "$IMAGE" \
    -c 'rm -rf /caches/pnpm-store /caches/ms-playwright; mkdir -p /caches/pnpm-store /caches/ms-playwright; chown -R runner:runner /caches'
  [ -f "$STATE/stopped-for-disk" ] || docker compose up -d >/dev/null 2>&1
  log "cache volume was ${cache_mb}M > ${CACHE_MAX_GB}G: wiped"
fi
docker image prune -f >/dev/null 2>&1
touch "$STATE/daily"
log "daily hygiene done: cache ${cache_mb}M, free $(free_gb)G"
