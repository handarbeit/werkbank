# The runner image: myoung34/github-runner plus what GitHub's ubuntu-latest has and the base lacks.
# Builds for the host's architecture (arm64 on Apple silicon, amd64 on x64 hosts).
FROM myoung34/github-runner:ubuntu-noble

# Actions that run before setup-node (pnpm/action-setup, for one) use the system node. Ubuntu's is
# 18, too old for pnpm's installer; ubuntu-latest ships 20+.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Chromium's system libraries, so `playwright install --with-deps` finds them already present
# instead of apt-installing them on every E2E job.
RUN npx -y playwright install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# Native build tooling ubuntu-latest has: C/C++ for -sys crates and CMake-built dependencies, and
# OpenSSL headers and static libraries found through pkg-config.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# The Actions runner version. The base image ships the current release, usually within a day of
# it. If it lags, the watchdog rebuilds with RUNNER_VERSION set and the release is installed here
# instead. Runners never update themselves (DISABLE_AUTO_UPDATE in compose/runner.yml): an
# ephemeral container's self-update can leave it with no runner at all (docs/runners.md).
ARG RUNNER_VERSION=
RUN if [ -n "$RUNNER_VERSION" ] && ! grep -q "\"Runner.Listener/$RUNNER_VERSION\"" /actions-runner/bin/Runner.Listener.deps.json; then \
      case "$(uname -m)" in x86_64) a=x64 ;; aarch64) a=arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac \
   && cd /actions-runner && rm -rf bin externals \
   && curl -fsSL "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-$a-$RUNNER_VERSION.tar.gz" | tar xz \
   && chown -R runner:runner /actions-runner; \
    fi

# Wipe the last job's files each time the container (re)starts; see the script.
COPY clean-start.sh /clean-start.sh
ENTRYPOINT ["/clean-start.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
