#!/bin/bash
# Registers this container as a runner, runs it, and deregisters it if the container is stopped
# while it waits for a job. Runs as root after clean-start.sh; the runner itself runs as `runner`.
#
# Settings (compose environment):
#   RUNNER_SCOPE        org | repo (default repo)
#   ORG_NAME            the org, for org runners
#   REPO_URL            https://github.com/<owner>/<repo>, for repo runners
#   APP_ID, APP_PRIVATE_KEY (or APP_PRIVATE_KEY_FILE), APP_LOGIN
#                       sign in as a GitHub App (docs/github-app.md); APP_LOGIN defaults to the
#                       org or the repo's owner. A key with literal \n line breaks (as .env holds
#                       it) is accepted.
#   ACCESS_TOKEN        or a token that may create registration tokens, instead of the App
#   RUNNER_NAME         full name; otherwise RUNNER_NAME_PREFIX (default github-runner) plus a
#                       random suffix, since every registration needs a fresh name
#   LABELS              comma-separated extra labels
#   RUNNER_GROUP        default Default
#   EPHEMERAL           any value: take one job, then exit (compose/runner.yml sets it)
#   DISABLE_AUTO_UPDATE any value: the runner never updates itself (compose/runner.yml sets it)
#   RUN_AS_ROOT         true: run jobs as root (default false, as on ubuntu-latest)
#
# Same interface as the myoung34/github-runner image this replaces, minus what Werkbank never
# used (enterprise scope, GitHub Enterprise Server, runner reuse, Docker-in-Docker).
#
# Credentials are un-exported first, so the runner and jobs don't inherit them. They are still in
# this container's starting environment (/proc/1/environ), which a job can read with sudo: see
# docs/github-app.md, "What a job can see".
set -euo pipefail
export -n ACCESS_TOKEN APP_ID APP_PRIVATE_KEY APP_PRIVATE_KEY_FILE APP_LOGIN RUNNER_TOKEN

API=https://api.github.com
RUNNER_DIR=/actions-runner
WORK_DIR=/_work

die() { echo "register: $*" >&2; exit 1; }
log() { echo "register: $*"; }

# --- what to register with --------------------------------------------------------------------
scope=${RUNNER_SCOPE:-repo}; scope=${scope,,}
case "$scope" in
  org*)
    [ -n "${ORG_NAME:-}" ] || die "ORG_NAME is required for org runners"
    url="https://github.com/$ORG_NAME"; api_path="orgs/$ORG_NAME"; owner=$ORG_NAME ;;
  repo*)
    [ -n "${REPO_URL:-}" ] || die "REPO_URL is required for repo runners"
    slug=${REPO_URL#https://github.com/}; slug=${slug%/}; slug=${slug%.git}
    [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || die "REPO_URL must be https://github.com/<owner>/<repo>"
    url="https://github.com/$slug"; api_path="repos/$slug"; owner=${slug%%/*} ;;
  *) die "RUNNER_SCOPE must be org or repo, not '$RUNNER_SCOPE'" ;;
esac

if [ -n "${APP_PRIVATE_KEY_FILE:-}" ]; then
  [ -z "${APP_PRIVATE_KEY:-}" ] || die "set APP_PRIVATE_KEY or APP_PRIVATE_KEY_FILE, not both"
  [ -r "$APP_PRIVATE_KEY_FILE" ] || die "APP_PRIVATE_KEY_FILE '$APP_PRIVATE_KEY_FILE' is not readable"
  APP_PRIVATE_KEY=$(<"$APP_PRIVATE_KEY_FILE")
fi
if [ -n "${APP_ID:-}${APP_PRIVATE_KEY:-}" ]; then
  [ -n "${APP_ID:-}" ] && [ -n "${APP_PRIVATE_KEY:-}" ] || die "APP_ID and APP_PRIVATE_KEY go together"
  [ -z "${ACCESS_TOKEN:-}" ] || die "set the App (APP_*) or ACCESS_TOKEN, not both"
  APP_LOGIN=${APP_LOGIN:-$owner}
  APP_PRIVATE_KEY=${APP_PRIVATE_KEY//\\n/$'\n'}
elif [ -z "${ACCESS_TOKEN:-}" ]; then
  die "no credentials: set APP_ID, APP_PRIVATE_KEY and APP_LOGIN, or ACCESS_TOKEN"
fi

# --- GitHub API ---------------------------------------------------------------------------------
# Tokens go to curl on a file descriptor, never on its command line, where `ps` would show them.
# api METHOD PATH TOKEN
api() {
  curl -fsS --max-time 30 --retry 3 --retry-connrefused -X "$1" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H @<(printf 'Authorization: Bearer %s\n' "$3") "$API/$2"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# An installation token for the App's installation on APP_LOGIN, good for an hour.
app_token() {
  local now header payload sig jwt id
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -binary -sign <(printf '%s\n' "$APP_PRIVATE_KEY") | b64url) \
    || die "could not sign with APP_PRIVATE_KEY (is it the App's PEM key?)"
  jwt="$header.$payload.$sig"
  id=$(api GET "app/installations?per_page=100" "$jwt" \
    | jq -r --arg l "$APP_LOGIN" '.[] | select(.account.login | ascii_downcase == ($l | ascii_downcase)) | .id' \
    | head -1) || die "App $APP_ID: listing its installations failed"
  [ -n "$id" ] || die "App $APP_ID is not installed on '$APP_LOGIN'"
  api POST "app/installations/$id/access_tokens" "$jwt" | jq -er .token \
    || die "App $APP_ID: no installation token for '$APP_LOGIN'"
}

access_token() { if [ -n "${APP_ID:-}" ]; then app_token; else printf '%s' "$ACCESS_TOKEN"; fi; }

# runner_token registration-token | remove-token
runner_token() {
  local tok; tok=$(access_token) || exit 1
  api POST "$api_path/actions/runners/$1" "$tok" | jq -er .token \
    || die "$api_path: could not get a $1 (does the credential have runner admin rights?)"
}

as_runner() { setpriv --reuid=runner --regid=runner --init-groups env HOME=/home/runner USER=runner "$@"; }

# --- register -----------------------------------------------------------------------------------
cd "$RUNNER_DIR"
rm -f .runner .runner_migrated .credentials .credentials_migrated .credentials_rsaparams
name=${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-github-runner}-$(tr -dc 'a-z0-9' </dev/urandom | head -c 13 || true)}
args=(--unattended --replace --url "$url" --name "$name" --work "$WORK_DIR"
      --runnergroup "${RUNNER_GROUP:-Default}")
[ -n "${LABELS:-}" ] && args+=(--labels "$LABELS")
[ -n "${EPHEMERAL:-}" ] && args+=(--ephemeral)
[ -n "${DISABLE_AUTO_UPDATE:-}" ] && args+=(--disableupdate)

log "registering $name with $url"
reg=$(runner_token registration-token)
chown runner:runner "$RUNNER_DIR" "$WORK_DIR"
as_runner ./config.sh "${args[@]}" --token "$reg"
unset reg

# --- run ----------------------------------------------------------------------------------------
# Jobs see none of the settings above.
export -n RUNNER_SCOPE ORG_NAME REPO_URL RUNNER_NAME RUNNER_NAME_PREFIX LABELS RUNNER_GROUP \
  EPHEMERAL DISABLE_AUTO_UPDATE RUN_AS_ROOT

# Stopped while idle: the runner is still registered, so take it off GitHub's list. (An ephemeral
# runner that ran its job has already removed itself, and with it .runner.)
listener=
deregister() {
  trap - TERM INT
  [ -n "$listener" ] && kill -TERM "$listener" 2>/dev/null && wait "$listener" 2>/dev/null || true
  if [ -f "$RUNNER_DIR/.runner" ]; then
    log "stopping: deregistering $name"
    as_runner ./config.sh remove --token "$(runner_token remove-token)" || true
  fi
  exit 0
}
trap deregister TERM INT

# Started as plain commands, not through as_runner: a backgrounded function runs in a subshell,
# and $! would be that subshell, not the listener the trap has to stop.
if [ "${RUN_AS_ROOT:-false}" = true ]; then
  RUNNER_ALLOW_RUNASROOT=1 ./bin/Runner.Listener run --startuptype service &
else
  setpriv --reuid=runner --regid=runner --init-groups env HOME=/home/runner USER=runner \
    ./bin/Runner.Listener run --startuptype service &
fi
listener=$!
set +e
wait "$listener"; status=$?
# wait returns early (>128) when a trapped signal arrives; the trap has exited by then.
exit "$status"
