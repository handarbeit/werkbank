# Runners

## The ephemeral model

Every Linux runner is a container that takes **one job**, then deregisters and exits. Docker
restarts it (`restart: always`), it registers again, and it waits for the next job.
`image/clean-start.sh` runs on every start and wipes the previous job's checkout, `node_modules`
and temp files. Without it, an ephemeral runner leaks state into the next job and fills the disk:
we once saw 23 GB across 9 runners in two hours. Two things survive on purpose:
`/opt/hostedtoolcache` (setup-node downloads) and the shared `/caches` volume (pnpm store,
Playwright browsers).

The toolcache keeps the Node releases, not what jobs installed into them. `npm i -g` writes into
the cached Node's own prefix, and setup-node puts that `bin/` first on `PATH`, so one repo's
`npm i -g pnpm@12` would shadow another repo's pnpm from pnpm/action-setup. `clean-start.sh`
resets each cached Node to what it ships with (`node`, `npm`, `npx`, `corepack`) at every start.

Re-registration takes a few seconds, longer on a loaded host. A runner between jobs briefly
disappears from GitHub's runner list; that's normal.

Jobs run as the image's non-root `runner` user (passwordless sudo), as on `ubuntu-latest`. As
root, tests that make a file unreadable can still read it.

## How jobs reach a runner

Runners **poll**: each one keeps an outbound HTTPS long-poll open to GitHub, and GitHub answers it
when it assigns a job. Nothing connects in, so runners work behind NAT with no port forwarding.
GitHub assigns a queued job to *any* online, idle runner whose labels include every label in the
job's `runs-on`. It has no notion of preference; [overflow.md](overflow.md) adds one.

## cpusets are load-bearing

Pin every runner to its own cpuset (`cpuset: "0-3"`), one runner per set. Node's
`availableParallelism()` reports the cpuset, so test runners such as vitest and jest size their
worker pools to it. Without pinning, every job sees every core of the VM and starts that many
workers. With several jobs running at once that oversubscribes the machine many times over, and
tests time out. Two runners sharing a cpuset starve each other the same way. Exception: the light
tier (below) shares a cpuset with `cpus: 2` per runner, because its jobs barely compute.

The same applies to **work on the host outside CI**. If developers or coding agents run test
suites directly on the machine, an uncapped vitest starts cores - 1 workers there too. Cap local
runs in the project's config, not in `package.json` scripts (direct `npx vitest` invocations skip
those), e.g. `maxWorkers: process.env.CI ? undefined : 4`. Overflow's
[host-pressure mode](overflow.md#host-pressure) is the safety net when that's not enough.

## Heap size

Node sizes its default heap from the container's memory limit: about 2 GB in an 8 GB container,
against about 4 GB on GitHub-hosted runners. A `tsc && vite build` that passes on hosted runners
then dies with "JavaScript heap out of memory". `compose/runner.yml` sets
`NODE_OPTIONS=--max-old-space-size=4096`. Lower it for small runners (the light tier uses 2048 in
3 GB). A workflow that sets `NODE_OPTIONS` itself overrides it.

## Routing: repo variables with a hosted fallback

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
runs-on: ${{ vars.MACOS_RUNNER || 'macos-latest' }}
runs-on: ${{ vars.LIGHT_RUNNER || 'ubuntu-latest' }}
```

Set the variable in the repo (or org) settings and jobs go to your runners. Delete it and they go
back to GitHub-hosted runners, with no workflow change. Use it when a machine is down for a while.

**Org runners** (`RUNNER_SCOPE: org`) join the org's "Default" runner group, which serves every
*private* repo in the org and refuses public ones. Runners can't be shared across orgs without
GitHub Enterprise. Each runner registers to exactly one repo, org or enterprise.

## The light tier

Seconds-long jobs (change detection, config checks, verdict and aggregator jobs, deploy steps)
shouldn't wait behind a 10-minute build. Give them their own runners, labelled `orb-light` only
and targeted with `vars.LIGHT_RUNNER`. Heavy jobs can't take them, and they keep working when
GitHub-hosted runners have an outage. Most of a light job is the ~20 s container restart, so a few
replicas keep up with bursts. They aren't for builds or tests.

## Safe restarts: `bin/roll.sh`

**Never recreate runners with a bare `docker compose up -d`** after a config change: it kills
whatever job a runner is running. `bin/roll.sh <service>...` recreates one service at a time, and
only once its runners are idle by three checks, all passing twice, 20 s apart:

1. no `Runner.Worker` process in the container;
2. GitHub reports the runner not busy. An assigned job shows up here several seconds before
   `Runner.Worker` exists, the window a `ps` check alone misses;
3. the runner is registered and online.

`roll.sh --once <service>...` doesn't wait: it recreates the services that are idle now, skips
the busy ones and exits 1 if it skipped any. The watchdog uses it to move runners onto a new image.

## Runner versions

**Runners don't update themselves** (`DISABLE_AUTO_UPDATE` in `compose/runner.yml`). By default
a runner updates itself after a job when GitHub has released a newer version. It moves `bin/` and
`externals/` aside, starts an updater, and exits. In an ephemeral container that exit restarts
the container, which can cut the update short and leave no runner at all. The container then
crash-loops (`./bin/Runner.Listener: No such file or directory`) until it's recreated, and since
every runner hits the next release within hours, a whole tier can go dark at once.

The watchdog keeps the image current instead. Every `RUNNER_CHECK_HOURS` (6) it compares the
image's runner with GitHub's latest release, and if there's a newer one it rebuilds:
`docker compose build --pull` picks up the base image's new runner, and if the base hasn't caught
up yet, the build installs the release itself (the Dockerfile's `RUNNER_VERSION` argument). Then,
every run, it recreates each runner still on the old image once it's idle (`roll.sh --once`).
GitHub keeps sending jobs to an older runner for some weeks after a release, so there's no rush.

To upgrade by hand: `docker compose build --pull`, then `bin/roll.sh <service>...`; or pin a
version with `docker compose build --build-arg RUNNER_VERSION=2.338.1`.

If a runner did update itself and broke anyway, `image/clean-start.sh` puts the previous version
back (`bin.<version>` to `bin`) when the container restarts.

## Superseded runs

Most queueing on self-hosted runners is self-inflicted: every push to a PR starts a full run while
the previous one is still going. Cancel superseded runs, but never on the default branch or tags:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || ((github.ref == format('refs/heads/{0}', github.event.repository.default_branch) || startsWith(github.ref, 'refs/tags/')) && github.run_id) || github.ref }}
  cancel-in-progress: true
```

Default-branch and tag runs are keyed by `github.run_id`, so they're never cancelled *or
replaced*. GitHub keeps only one *pending* run per concurrency group even with
`cancel-in-progress: false`, so a shared group would still silently drop runs.

## Gotchas

- **`setup-node` with `cache: pnpm` (or npm/yarn) on self-hosted runners** uploads the whole
  package store to GitHub's cache service after every job. That's slow, and on a weak uplink it
  stalls jobs for an hour. The shared local store already *is* the cache. See [pnpm.md](pnpm.md).
- **Repo transfers break repo-level runners.** After a repo moves to another owner, its ephemeral
  runners can't re-register and crash-loop with "Invalid configuration provided for token".
  Re-register them at the new owner. Delete leftover registrations through the API
  (`DELETE /repos/{owner}/{repo}/actions/runners/{id}`), because `config.sh remove` returns 404
  after a transfer.
- **Inside `docker exec <c> sh -c '...'`, `pgrep -f` matches its own shell.** Use
  `ps -eo comm= | grep -qx Runner.Worker`.
- **Check the host's uplink**, not just its download speed. Jobs upload logs, artifacts and caches
  constantly. A host that showed fine speed tests was getting ~0.5 Mbit/s per connection upstream
  over a 6 GHz Wi-Fi link; a cable fixed it.

## Credentials

Register runners with a GitHub App, not a personal token: an ephemeral runner asks for a
registration token after every job, and on a personal token that spends the person's API quota.
[github-app.md](github-app.md) has the setup. Whatever the credential, name it per service in
`environment:` and don't give services `env_file: .env`: the image clears only its own variables
(`ACCESS_TOKEN`, `APP_*`) before a job starts, so anything else in the container's environment is
visible to every job.
