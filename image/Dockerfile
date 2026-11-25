# The runner image: GitHub's official runner image plus what GitHub's ubuntu-latest has and it
# lacks, and our own start-up (clean-start.sh, then register.sh).
# Builds for the host's architecture (arm64 on Apple silicon, amd64 on x64 hosts).

# The base, pinned to a release and its digest: a build gets exactly this image, whatever the tag
# points to later. bin/pin-base.sh moves the pin; the watchdog builds each new runner release with
# both as --build-args (docs/runners.md, "Runner versions"). The base is Ubuntu 24.04 (through
# Microsoft's .NET runtime-deps image) with the runner, git, sudo, curl, jq and a `runner` user
# (uid 1001, passwordless sudo).
ARG RUNNER_VERSION=2.338.2
ARG BASE_DIGEST=sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}@${BASE_DIGEST}

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
# The base copies the runner's whole diagnostic log to stdout, so into `docker logs`, which grows
# without bound on a busy host. The log stays in /actions-runner/_diag, as on ubuntu-latest.
ENV ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=

# The runner lives in /actions-runner, as bin/roll.sh and the watchdog expect, not in the base's
# /home/runner: that is the jobs' $HOME, which clean-start.sh empties at every start. The base
# also leaves /home/runner world-writable.
RUN mkdir /actions-runner /_work /opt/hostedtoolcache \
 && find /home/runner -mindepth 1 -maxdepth 1 ! -name '.*' -exec mv -t /actions-runner {} + \
 && rm -rf /actions-runner/k8s /actions-runner/k8s-novolume \
 && chown -R runner:runner /actions-runner /_work /opt/hostedtoolcache \
 && chmod 755 /home/runner
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache

# Third-party apt repositories, with their signing keys kept in this repo (image/keys/) rather
# than fetched at build time. Fingerprints:
#   NodeSource  6F71F525282841EEDAF851B42F59B5F99B1BE0B4
#   GitHub CLI  2C6106201985B60E6C7AC87323F3D4EA75716059, 7F38BBB59D064DBCB3D84D725612B36462313325
COPY keys/ /usr/share/keyrings/werkbank/
RUN echo "deb [signed-by=/usr/share/keyrings/werkbank/nodesource.asc] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/werkbank/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list

# Packages from Ubuntu's archive and the two repositories above, with the base's own packages
# brought up to date: the base is rebuilt only for runner releases, a few weeks apart.
# - nodejs 24: actions that run before setup-node (pnpm/action-setup, for one) use the system node.
# - gh, jq, git-lfs, zstd (actions/cache compresses with it when present), zip, xz, wget, rsync,
#   ssh, python3 with pip and venv: what ubuntu-latest has and jobs here use.
# - C/C++ toolchain, CMake, pkg-config and the common -dev libraries: -sys crates, node-gyp,
#   CMake-built dependencies, OpenSSL found through pkg-config.
# - tini: PID 1, so the processes jobs leave behind are reaped.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      nodejs gh git-lfs zstd zip unzip xz-utils wget rsync openssh-client ca-certificates gnupg \
      python3 python3-pip python3-venv python3-setuptools \
      build-essential cmake pkg-config libssl-dev zlib1g-dev libcurl4-openssl-dev libpq-dev \
      libyaml-dev gettext-base iputils-ping openssl tini \
 && rm -rf /var/lib/apt/lists/*

# Chromium's system libraries, so `playwright install --with-deps` finds them already present
# instead of apt-installing them on every E2E job. Pinned: the version decides the package list.
RUN npx -y playwright@1.65.1 install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# Start-up: wipe the last job's files, then register and run as `runner` (see the scripts).
COPY clean-start.sh register.sh /usr/local/bin/
WORKDIR /actions-runner
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clean-start.sh"]
CMD ["/usr/local/bin/register.sh"]
