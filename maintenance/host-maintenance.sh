#!/bin/bash
# Disk watchdog and cache hygiene for a werkbank deployment. Run every 15 minutes by launchd
# (install-launchd.sh) or a systemd timer; safe to run by hand:
#   host-maintenance.sh /path/to/deployment
# The deployment directory holds its compose.yml and .env, and optionally overflow.json and a
# maintenance.env that overrides the settings below (WARN_GB=20, SNAPSHOT_KEEP_HOURS=4, ...).
#
# Every run:  (macOS) delete Time Machine local snapshots older than SNAPSHOT_KEEP_HOURS.
#             check free disk space on DISKS (the lowest of them counts).
#   < WARN_GB   notify.
#   < STOP_GB   stop the Linux runners so CI cannot fill the disk to zero: a full disk can
#               stop the Docker VM itself and take every runner down mid-job.
#   >= START_GB start them again if this script was what stopped them.
# Every RUNNER_CHECK_HOURS: if GitHub has released a newer Actions runner than the image has,
#             rebuild the image (docs/runners.md, "Runner versions").
# Every run:  recreate runners still on an older image, each only while idle (bin/roll.sh --once).
# Every run:  (optional) check that other hosts' runners are online: EXPECT_RUNNERS, below.
# Alerts:     a desktop notification on macOS, the journal on Linux, and, with PUSHOVER_TOKEN and
#             PUSHOVER_USER in .env, a push to Pushover (docs/alerts.md).
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
# Mount points to watch. Add the one that holds Docker's data when it isn't on /, e.g.
# DISKS="/ /Volumes/CI" (on macOS, OrbStack's storage location; on Linux, Docker's data-root).
DISKS="/"
CACHE_MAX_GB=12
SNAPSHOT_KEEP_HOURS=2
RUNNER_CHECK_HOURS=6
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
# A value from .env, read without sourcing it (.env is compose's file, not shell).
env_get() { grep -s "^$1=" .env | tail -1 | cut -d= -f2- | sed -e "s/^[\"']//" -e "s/[\"']\$//"; }
PUSHOVER_TOKEN=${PUSHOVER_TOKEN:-$(env_get PUSHOVER_TOKEN)}
PUSHOVER_USER=${PUSHOVER_USER:-$(env_get PUSHOVER_USER)}
HOST_LABEL=${HOST_LABEL:-$(hostname -s)}
# notify MESSAGE [PRIORITY]: PRIORITY is Pushover's (-2..1; default 0). 1 is for "CI is down" alerts.
notify() {
  if command -v osascript >/dev/null; then
    osascript -e "display notification \"$1\" with title \"CI runners\"" >/dev/null 2>&1 || true
  else
    command -v logger >/dev/null && logger -t werkbank "$1"
  fi
  [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ] || return 0
  # The keys go to curl on stdin (-K -), not on its command line, so they never show in ps.
  printf 'form-string = "token=%s"\nform-string = "user=%s"\n' "$PUSHOVER_TOKEN" "$PUSHOVER_USER" \
    | curl -fsS --max-time 20 -o /dev/null -K - \
        --form-string "title=CI runners: $HOST_LABEL" --form-string "message=$1" \
        --form-string "priority=${2:-0}" https://api.pushover.net/1/messages.json \
    || log "pushover: could not send: $1"
}
# A token for `gh`: none if gh is logged in, else an App installation token minted from the
# overflow controller's config (good for an hour). Empty, and logged, if neither is available.
gh_token() {
  gh auth status >/dev/null 2>&1 && return 0
  [ -f "$OVERFLOW_CONFIG" ] && /usr/bin/python3 "$WERKBANK/controller/overflow.py" --config "$OVERFLOW_CONFIG" --token 2>/dev/null && return 0
  log "no gh login, and no token from $OVERFLOW_CONFIG" >&2
}
# Run a command a given number of runs in a row before acting, then once on recovery:
#   streak NAME true|false  -> prints "alert" on the run the streak reaches STREAK_RUNS,
#                              "recovered" on the first good run after an alert.
STREAK_RUNS=2
streak() {
  local f="$STATE/streak-$1" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$2" = true ]; then
    n=$((n + 1)); echo "$n" > "$f"
    [ "$n" -eq "$STREAK_RUNS" ] && echo alert
  else
    rm -f "$f"
    [ "$n" -ge "$STREAK_RUNS" ] && echo recovered
  fi
  return 0
}
# `timeout` is GNU coreutils (Homebrew on macOS); run without a limit where it is missing.
to() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }
free_gb() {   # the lowest free space across DISKS, in GB
  local d f min=
  for d in $DISKS; do
    f=$(df -Pk "$d" | awk 'NR==2 {print int($4 / 1048576)}')
    [ -z "$min" ] || [ "$f" -lt "$min" ] && min=$f
  done
  echo "${min:-0}"
}

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

# --- other hosts' runners (optional) ------------------------------------------------
# A host that is down can't say so, so each host can watch the others' runners on GitHub.
# EXPECT_RUNNERS (in maintenance.env) has one line per group: "<API scope> <name prefix> <minimum>":
#   EXPECT_RUNNERS="orgs/my-org other-host- 4
#   repos/me/my-app my-mac-app 1"
# When fewer than <minimum> runners whose name starts with <name prefix> are online on
# STREAK_RUNS runs in a row (ephemeral runners are briefly unregistered between jobs), notify
# once at priority 1; notify again when they are back. A failed GitHub call counts as neither.
if [ -n "${EXPECT_RUNNERS:-}" ]; then
  tok=$(gh_token)
  while read -r scope prefix min; do
    [ -n "$scope" ] && [ -n "$prefix" ] && [ -n "$min" ] || continue
    online=$( ( [ -z "$tok" ] || export GH_TOKEN="$tok"
      gh api --paginate "$scope/actions/runners?per_page=100" \
        --jq "[.runners[] | select(.status == \"online\" and (.name | startswith(\"$prefix\")))] | length" ) 2>/dev/null) \
      || { log "expected runners: GitHub call failed for $scope"; continue; }
    online=$(echo "$online" | awk '{ n += $1 } END { print n + 0 }')
    key=$(printf '%s' "expect $scope $prefix" | tr -c 'A-Za-z0-9_.-' _)
    case $(streak "$key" "$([ "$online" -lt "$min" ] && echo true || echo false)") in
      alert)     log "expected runners: $prefix* has $online online (want $min)"
                 notify "Runners down: $prefix* has $online of $min online." 1 ;;
      recovered) log "expected runners: $prefix* back ($online online)"
                 notify "Runners back: $prefix* has $online online." ;;
    esac
  done <<< "$EXPECT_RUNNERS"
fi

if ! docker info >/dev/null 2>&1; then
  log "docker not reachable; skipping"
  [ "$(streak docker-down true)" = alert ] && notify "Docker is not reachable; this host's Linux runners are down." 1
  exit 0
fi
[ "$(streak docker-down false)" = recovered ] && notify "Docker is reachable again."

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
    notify "Disk nearly full (${free} GB free). Linux CI runners stopped until space is freed." 1
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
# (ERR_PNPM_BROKEN_PNPM_INSTALL) and nothing repairs it (docs/pnpm.md). Detect a small pnpm
# "binary" that isn't an ELF executable, and drop v11 (it refills, ~1 GB). The real binary is tens
# of MB and starts with the ELF header even mid-download, so this needs no age guard; an earlier
# 10-minute guard never fired on a busy host, where every job rewrites the placeholder.
broken=$(docker run --rm -v "$CACHE_VOLUME":/caches --entrypoint sh "$IMAGE" -c \
  'for f in $(find /caches/pnpm-store/v11/links/@pnpm -path "*/node_modules/@pnpm/exe.*/pnpm" -type f -size -1000k 2>/dev/null); do
     [ "$(head -c 4 "$f" | tail -c 3)" = ELF ] || { echo "$f"; break; }
   done')
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
    notify "CI overflow controller has stopped; slower runners stay hidden until it is back." 1
  fi
fi

# --- runner upgrades ---------------------------------------------------------
# Runners don't update themselves (DISABLE_AUTO_UPDATE, compose/runner.yml): an ephemeral
# container's self-update can leave it with no runner. GitHub stops sending jobs to a runner some
# weeks after a newer release, so the image follows releases here instead: it is rebuilt on
# GitHub's official runner image for the new release, pinned to the digest that release's tag
# has now (bin/pin-base.sh --print). GitHub publishes that image with the release; until it
# appears, the rebuild waits for the next check.
runner_version() {
  docker run --rm --entrypoint sh "$IMAGE" -c \
    'grep -o "\"Runner.Listener/[0-9.]*\"" /actions-runner/bin/Runner.Listener.deps.json | head -1' 2>/dev/null \
    | sed 's/.*\///; s/"//g'
}
if [ ! -f "$STATE/stopped-for-disk" ] && [ -z "$(find "$STATE/runner-checked" -mmin -$((RUNNER_CHECK_HOURS * 60)) 2>/dev/null)" ]; then
  latest=$(curl -fsS --max-time 30 https://api.github.com/repos/actions/runner/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p')
  current=$(runner_version)
  if [ -n "$latest" ] && [ -n "$current" ]; then
    touch "$STATE/runner-checked"
    if [ "$latest" != "$current" ] && [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" = "$latest" ]; then
      if ! digest=$("$WERKBANK/bin/pin-base.sh" --print "$latest" 2>&1); then
        log "Actions runner $latest released (image has $current), but: $digest; retrying next check"
        now=skip
      else
        log "Actions runner $latest released (image has $current): rebuilding on $digest"
        to 1800 docker compose build --build-arg RUNNER_VERSION="$latest" \
          --build-arg BASE_DIGEST="$digest" >/dev/null 2>&1
        now=$(runner_version)
      fi
      if [ "$now" = skip ]; then
        :
      elif [ "$now" = "$latest" ]; then
        log "image rebuilt with runner $now; runners move to it as they go idle"
        notify "CI runner image rebuilt with Actions runner $now."
      else
        log "image rebuild failed (runner ${now:-unknown}, want $latest)"
        notify "CI runner image rebuild for Actions runner $latest failed; see the maintenance log."
      fi
    fi
  fi
fi
# Recreate, while idle, every runner whose container isn't on the current image. Needs `gh`
# (bin/roll.sh checks GitHub's view of each runner), logged in or with the controller's token
# (below); busy ones are retried next run.
if [ ! -f "$STATE/stopped-for-disk" ] && image_id=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null); then
  stale=$(for svc in $(docker compose config --services 2>/dev/null); do
    for c in $(docker compose ps -q "$svc"); do
      [ "$(docker inspect -f '{{.Config.Image}}' "$c")" = "$IMAGE" ] || continue
      [ "$(docker inspect -f '{{.Image}}' "$c")" = "$image_id" ] || { echo "$svc"; break; }
    done
  done)
  if [ -n "$stale" ]; then
    # With no gh login on the host, borrow the overflow controller's credentials (a GitHub App
    # installation token, good for an hour) for this one call. Otherwise roll.sh can't see that a
    # runner is idle, and every runner counts as busy forever.
    tok=$(gh_token)
    # Exported in a subshell, not passed on a command line, so the token never shows in ps.
    # shellcheck disable=SC2086
    ( [ -z "$tok" ] || export GH_TOKEN="$tok"
      WERKBANK_DEPLOY="$DIR" "$WERKBANK/bin/roll.sh" --once $stale 2>&1 ) | grep -v 'busy, skipped' \
      | while read -r line; do log "runner upgrade: $line"; done
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
