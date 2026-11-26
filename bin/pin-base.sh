#!/bin/bash
# Pin the runner image's base, GitHub's official ghcr.io/actions/actions-runner, to a release and
# the digest that release's tag points to now. The Dockerfile names both, so a build always gets
# the image that was pinned, never whatever the tag has moved to since.
#
#   pin-base.sh             pin the latest Actions runner release (rewrites image/Dockerfile)
#   pin-base.sh 2.338.2     pin that release
#   pin-base.sh --print 2.338.2
#                           print the digest only; the watchdog builds with it (--build-arg)
#
# The digest is the multi-architecture index's, so one pin covers arm64 and amd64 hosts.
set -euo pipefail
REPO=actions/actions-runner
DOCKERFILE="$(cd "$(dirname "$0")/.." && pwd)/image/Dockerfile"

PRINT=0
[ "${1:-}" = --print ] && { PRINT=1; shift; }
version=${1:-}
if [ -z "$version" ]; then
  version=$(curl -fsS --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \
    | sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p')
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a runner version: '$version'" >&2; exit 2; }

# Anonymous pull token for the public repository, then the digest the tag resolves to.
token=$(curl -fsS --max-time 30 "https://ghcr.io/token?scope=repository:$REPO:pull" \
  | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
digest=$(curl -fsSI --max-time 30 -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/$REPO/manifests/$version" \
  | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *\(sha256:[0-9a-f]\{64\}\)$/\1/p')
[ -n "$digest" ] || { echo "ghcr.io/$REPO:$version not found (not published yet?)" >&2; exit 1; }

if [ "$PRINT" = 1 ]; then echo "$digest"; exit 0; fi
sed -i.bak -e "s/^ARG RUNNER_VERSION=.*/ARG RUNNER_VERSION=$version/" \
           -e "s/^ARG BASE_DIGEST=.*/ARG BASE_DIGEST=$digest/" "$DOCKERFILE"
rm -f "$DOCKERFILE.bak"
echo "pinned ghcr.io/$REPO:$version@$digest"
