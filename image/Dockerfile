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

# Wipe the last job's files each time the container (re)starts; see the script.
COPY clean-start.sh /clean-start.sh
ENTRYPOINT ["/clean-start.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
