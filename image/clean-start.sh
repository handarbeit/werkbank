#!/bin/bash
# Runs as root each time the container starts. An ephemeral runner exits
# after one job and Docker restarts the *same* container, so without this the
# previous job's checkout, node_modules and temp files stay behind: state leaks
# into the next job and the disk fills (23 GB across 9 runners in two hours).
# Kept on purpose: /opt/hostedtoolcache (setup-node downloads) and the
# /caches volume (pnpm store, Playwright browsers).
rm -rf /_work/* /tmp/* /var/tmp/* 2>/dev/null
find /home/runner -mindepth 1 -maxdepth 1 ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' -exec rm -rf {} + 2>/dev/null
rm -rf /root/.cache /root/.npm /root/setup-pnpm 2>/dev/null
exec /entrypoint.sh "$@"
