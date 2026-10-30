#!/bin/bash
# Runs as root each time the container starts. An ephemeral runner exits
# after one job and Docker restarts the *same* container, so without this the
# previous job's checkout, node_modules and temp files stay behind: state leaks
# into the next job and the disk fills (23 GB across 9 runners in two hours).
# Kept on purpose: /opt/hostedtoolcache (setup-node downloads, minus what jobs installed into
# them; below) and the /caches volume (pnpm store, Playwright browsers).
rm -rf /_work/* /tmp/* /var/tmp/* 2>/dev/null
find /home/runner -mindepth 1 -maxdepth 1 ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' -exec rm -rf {} + 2>/dev/null
rm -rf /root/.cache /root/.npm /root/setup-pnpm 2>/dev/null
# Keep setup-node's Node downloads, but not what jobs installed into them: `npm i -g` lands in the
# cached Node's own prefix, and setup-node puts that bin/ first on PATH. One repo's
# `npm i -g pnpm@12` then shadowed another repo's pnpm 10 from pnpm/action-setup, and its
# install died in node-gyp (2026-10-30). GitHub-hosted runners start every job on a fresh VM;
# this gives each job the Node release as shipped: node, npm, npx, corepack.
for prefix in /opt/hostedtoolcache/node/*/*/; do
  [ -d "$prefix/lib/node_modules" ] || continue
  find "$prefix/lib/node_modules" -mindepth 1 -maxdepth 1 ! -name npm ! -name corepack -exec rm -rf {} + 2>/dev/null
  find "$prefix/bin" -mindepth 1 -maxdepth 1 ! -name node ! -name npm ! -name npx ! -name corepack -exec rm -rf {} + 2>/dev/null
done
# A runner that updated itself moves bin/ and externals/ aside (bin.<old version>) before
# installing the new ones; if the container restarts mid-update, there is no runner left and it
# crash-loops. Runners here don't self-update (DISABLE_AUTO_UPDATE), but if one ever did, put the
# old version back rather than loop forever.
for d in bin externals; do
  d=/actions-runner/$d
  [ -n "$(ls -A "$d" 2>/dev/null)" ] && continue
  old=$(ls -d "$d".[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$old" ] && rm -rf "$d" && mv "$old" "$d" && echo "clean-start: restored $d from $old"
done
exec /entrypoint.sh "$@"
