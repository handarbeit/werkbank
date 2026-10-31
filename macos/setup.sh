#!/usr/bin/env bash
# Self-hosted macOS GitHub Actions runners, run as a dedicated standard user.
#
#   sudo bash macos/setup.sh /path/to/macos-runners.conf
#
# The conf file (bash; see examples/mac/macos-runners.conf) sets TARGETS, and optionally CI_USER,
# LABEL, RETIRED, APPS, TOKEN_VARS and ENV_FILE. Creates the `ci` account (asks for its password),
# installs one runner per entry in TARGETS under /Users/ci/actions-runners/<name>, and a
# LaunchAgent that starts them when `ci` logs in. Jobs need a GUI session (Electron windows, the
# iOS Simulator), which a LaunchDaemon cannot give them — so after this, log
# `ci` in once via fast user switching and switch back; it keeps running.
#
# Re-running is safe: existing runners are left alone, missing ones added.
# A TARGETS entry is a repo (owner/name, a repo-level runner) or an org (name
# alone, a runner in that org's pool: it serves every private repo there).
# Registration tokens come from ENV_FILE (default: .env next to the conf): a GitHub
# App's, if APPS has the target's owner (docs/github-app.md), else the PAT in the
# variable TOKEN_VARS names for the owner, else ACCESS_TOKEN; nothing is printed. RETIRED names are runners that used to be installed here: their
# LaunchAgent and directory are removed first (their GitHub registration is
# deleted separately, via the API, since config.sh remove 404s for a repo that
# has been transferred).
set -euo pipefail

CONF="$(cd "$(dirname "${1:?usage: sudo bash $0 /path/to/macos-runners.conf}")" && pwd)/$(basename "$1")"
CI_USER=ci
LABEL=orb-macos
TARGETS=()
RETIRED=()
APPS=()                  # "owner=app_id:VAR" pairs, VAR holding the App's key, e.g. (my-org=123456:MY_APP_KEY)
TOKEN_VARS=()            # "owner=VAR" pairs, e.g. (my-org=MY_ORG_TOKEN)
ENV_FILE="$(dirname "$CONF")/.env"
# shellcheck disable=SC1090
. "$CONF"
[ ${#TARGETS[@]} -gt 0 ] || { echo "no TARGETS in $CONF" >&2; exit 1; }

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
env_val() {            # a value from ENV_FILE, quotes stripped
  local v
  v=$(grep "^$1=" "$ENV_FILE" | cut -d= -f2-)
  v=${v#\"}; printf '%s' "${v%\"}"
}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_token() {          # target app_id key_var: an installation token for the App
  local key now jwt inst
  key=$(env_val "$3")
  [ -n "$key" ] || { echo "no $3 in $ENV_FILE" >&2; exit 1; }
  now=$(date +%s)
  jwt=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    $((now - 60)) $((now + 540)) "$2" | b64url)
  # The key reaches openssl through a pipe, never a file or the command line.
  jwt=$jwt.$(printf '%s' "$jwt" | openssl dgst -sha256 -sign <(printf '%b\n' "$key") | b64url)
  inst=$(printf 'Authorization: Bearer %s\n' "$jwt" | curl -fsSL -H @- \
    "https://api.github.com/$(api_of "$1")/installation" | /usr/bin/jq -r .id)
  printf 'Authorization: Bearer %s\n' "$jwt" | curl -fsSL -X POST -H @- \
    "https://api.github.com/app/installations/$inst/access_tokens" | /usr/bin/jq -r .token
}
token_for() {          # a token that may register runners for this target
  local var=ACCESS_TOKEN t pair
  for pair in ${APPS[@]+"${APPS[@]}"}; do
    if [ "${1%%/*}" = "${pair%%=*}" ]; then
      t=${pair#*=}; app_token "$1" "${t%%:*}" "${t#*:}"; return
    fi
  done
  for pair in ${TOKEN_VARS[@]+"${TOKEN_VARS[@]}"}; do
    [ "${1%%/*}" = "${pair%%=*}" ] && var=${pair#*=}
  done
  t=$(grep "^$var=" "$ENV_FILE" | cut -d= -f2-)
  [ -n "$t" ] || { echo "no $var in $ENV_FILE" >&2; exit 1; }
  echo "$t"
}
name_of() { echo "${1#*/}"; }                   # owner/repo -> repo, org -> org
api_of()  { case "$1" in */*) echo "repos/$1";; *) echo "orgs/$1";; esac; }

# 1. The account: standard (not admin), so jobs cannot sudo or read other homes.
if ! id "$CI_USER" >/dev/null 2>&1; then
  read -rsp "Password for the new '$CI_USER' account: " pw; echo
  sysadminctl -addUser "$CI_USER" -fullName "CI Runner" -password "$pw" -home "/Users/$CI_USER"
  createhomedir -c -u "$CI_USER" >/dev/null 2>&1 || true
  [ -d "/Users/$CI_USER" ] || { mkdir -p "/Users/$CI_USER"; chown "$CI_USER":staff "/Users/$CI_USER"; chmod 700 "/Users/$CI_USER"; }
  unset pw
fi
CI_HOME=$(dscl . -read "/Users/$CI_USER" NFSHomeDirectory | awk '{print $2}')
as_ci() { sudo -u "$CI_USER" -H "$@"; }

# 1b. Retire runners that no longer belong here, before adding new ones, so two
# runners never compete for ci's one GUI session.
uid=$(id -u "$CI_USER")
for name in ${RETIRED[@]+"${RETIRED[@]}"}; do
  plist="$CI_HOME/Library/LaunchAgents/com.github.actions-runner.$name.plist"
  [ -e "$plist" ] || [ -d "$CI_HOME/actions-runners/$name" ] || continue
  while pgrep -u "$CI_USER" -f "actions-runners/$name/bin/Runner.Worker" >/dev/null; do
    echo "$name: waiting for its current job to finish before retiring it…"; sleep 15
  done
  launchctl bootout "gui/$uid/com.github.actions-runner.$name" 2>/dev/null || true
  rm -f "$plist"
  rm -rf "${CI_HOME:?}/actions-runners/$name"
  echo "$name: retired (delete its GitHub registration via the API)"
done

# 2. The runner binary, downloaded once and copied per target.
ver=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | /usr/bin/jq -r .tag_name | sed 's/^v//')
pkg="$CI_HOME/actions-runner-osx-arm64-$ver.tar.gz"
[ -f "$pkg" ] || as_ci curl -fsSL -o "$pkg" \
  "https://github.com/actions/runner/releases/download/v$ver/actions-runner-osx-arm64-$ver.tar.gz"

# PATH jobs see: Homebrew (gh etc.) and Apple's jq, as on macos-latest.
JOB_PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

for target in "${TARGETS[@]}"; do
  name=$(name_of "$target")
  dir="$CI_HOME/actions-runners/$name"
  if [ -f "$dir/.runner" ]; then echo "$target: already configured"; continue; fi
  as_ci mkdir -p "$dir"
  as_ci tar xzf "$pkg" -C "$dir"
  # The header goes in on stdin (-H @-): on the command line, the token would show
  # in any user's `ps` output for as long as curl runs.
  reg=$(printf 'Authorization: Bearer %s\n' "$(token_for "$target")" | curl -fsSL -X POST -H @- \
    "https://api.github.com/$(api_of "$target")/actions/runners/registration-token" | /usr/bin/jq -r .token)
  as_ci bash -c "cd '$dir' && ./config.sh --unattended --replace \
    --url 'https://github.com/$target' --token '$reg' \
    --name '$(scutil --get LocalHostName)-$name' --labels '$LABEL' --work _work >/dev/null"
  echo "$target: registered"
done

# Job environment, rewritten on every run so re-running applies changes.
# `.path` and `.env` are read by the runner at startup. launchd gives the
# runner no locale, and CocoaPods refuses to run without a UTF-8 one (Expo
# then reports it "not found"); macos-latest sets LANG, so we do too.
for target in "${TARGETS[@]}"; do
  dir="$CI_HOME/actions-runners/$(name_of "$target")"
  as_ci bash -c "echo '$JOB_PATH' > '$dir/.path'"
  # PATH goes in .env too: jobs of a launchd-started runner got .env but not
  # .path, and saw only /usr/bin:/bin:/usr/sbin:/sbin (no Homebrew, no pod).
  as_ci bash -c "printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\nPATH=%s\n' '$JOB_PATH' > '$dir/.env'"
done

# 3. One LaunchAgent per runner, in ci's own session so jobs get a GUI.
as_ci mkdir -p "$CI_HOME/Library/LaunchAgents" "$CI_HOME/Library/Logs/actions-runners"
for target in "${TARGETS[@]}"; do
  name=$(name_of "$target")
  plist="$CI_HOME/Library/LaunchAgents/com.github.actions-runner.$name.plist"
  as_ci tee "$plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.github.actions-runner.$name</string>
  <key>ProgramArguments</key><array><string>$CI_HOME/actions-runners/$name/run.sh</string></array>
  <key>WorkingDirectory</key><string>$CI_HOME/actions-runners/$name</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$CI_HOME/Library/Logs/actions-runners/$name.log</string>
  <key>StandardErrorPath</key><string>$CI_HOME/Library/Logs/actions-runners/$name.log</string>
</dict></plist>
EOF
done

# 4. Disk hygiene for ci, every 6 hours and only between jobs. Unlike the
# Linux containers, this runner keeps its files, and each iOS build leaves
# gigabytes of Xcode build products, simulators and temp files behind.
as_ci mkdir -p "$CI_HOME/bin"
as_ci tee "$CI_HOME/bin/ci-cleanup.sh" >/dev/null <<'EOF'
#!/bin/bash
# Installed by werkbank's macos/setup.sh (runs as ci; see there).
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
if pgrep -u "$(id -u)" -f 'bin/Runner.Worker' >/dev/null; then
  echo "$(date '+%F %T') skipped: a job is running"; exit 0
fi
before=$(df -g / | awk 'NR==2 {print $4}')
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/"* \
       "$HOME/Library/Developer/CoreSimulator/Caches/"* 2>/dev/null
xcrun simctl shutdown all >/dev/null 2>&1
xcrun simctl delete all >/dev/null 2>&1          # CI creates its own devices
tmp=$(getconf DARWIN_USER_TEMP_DIR)
find "$tmp" -maxdepth 1 -mindepth 1 -mmin +360 -exec rm -rf {} + 2>/dev/null
find "$HOME"/actions-runners/*/_work/_temp -mindepth 1 -mmin +360 -exec rm -rf {} + 2>/dev/null
# Package caches refill on demand; only drop them once they get large.
for c in "$HOME/Library/Caches/CocoaPods" "$HOME/Library/pnpm/store" "$HOME/.npm"; do
  [ -d "$c" ] && [ "$(du -sm "$c" | cut -f1)" -gt 5120 ] && rm -rf "$c"
done
echo "$(date '+%F %T') cleaned: free ${before}G -> $(df -g / | awk 'NR==2 {print $4}')G"
EOF
as_ci chmod +x "$CI_HOME/bin/ci-cleanup.sh"
as_ci tee "$CI_HOME/Library/LaunchAgents/com.github.actions-runner.cleanup.plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.github.actions-runner.cleanup</string>
  <key>ProgramArguments</key><array><string>$CI_HOME/bin/ci-cleanup.sh</string></array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$CI_HOME/Library/Logs/actions-runners/cleanup.log</string>
  <key>StandardErrorPath</key><string>$CI_HOME/Library/Logs/actions-runners/cleanup.log</string>
</dict></plist>
EOF

# Start them now if ci is already logged in; otherwise its next login does.
# A runner that is already loaded is restarted, but only between jobs, so it
# picks up the environment above without killing a job in progress.
if uid=$(id -u "$CI_USER") && launchctl print "gui/$uid" >/dev/null 2>&1; then
  for target in "${TARGETS[@]}"; do
    name=$(name_of "$target")
    svc="gui/$uid/com.github.actions-runner.$name"
    if launchctl print "$svc" >/dev/null 2>&1; then
      while pgrep -u "$CI_USER" -f "actions-runners/$name/bin/Runner.Worker" >/dev/null; do
        echo "$name: waiting for its current job to finish…"; sleep 15
      done
      launchctl kickstart -k "$svc" && echo "$name: restarted"
    else
      launchctl bootstrap "gui/$uid" "$CI_HOME/Library/LaunchAgents/com.github.actions-runner.$name.plist" && echo "$name: started"
    fi
  done
  launchctl bootout "gui/$uid/com.github.actions-runner.cleanup" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$CI_HOME/Library/LaunchAgents/com.github.actions-runner.cleanup.plist" \
    && echo "cleanup: scheduled every 6h (log: ~ci/Library/Logs/actions-runners/cleanup.log)"
else
  echo "Now log in as '$CI_USER' once (Apple menu → fast user switching), then switch back."
fi
