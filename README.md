# Werkbank

**Self-hosted GitHub Actions runners on machines you already have**: ephemeral Linux containers
on a Mac (OrbStack or Docker Desktop) or in WSL2 on Windows, native macOS and Windows runners,
and a small controller that routes jobs to your fastest machine first and spills over to slower
ones only when it's busy.

*Werkbank* is German for workbench. It's part of the [handarbeit](https://github.com/handarbeit)
family, alongside [Fabrik](https://github.com/handarbeit/fabrik).

## Why

GitHub-hosted runners bill by the minute for private repos, and macOS and "larger" runners cost
the most. A spare Mac Studio or an old gaming PC can run that CI for the price of its electricity,
and is often faster. Getting that to work *reliably* takes care in the details: CPU pinning, heap
sizes, cache sharing, job-safe restarts, disk hygiene, and priority between machines of different
speeds. Werkbank packages those details, and [`docs/`](docs/) explains each one.

**Keep public repos on GitHub-hosted runners.** They're free there, and a self-hosted runner lets
a fork's pull request run code on your machine.

## What's here

| Path | What |
|---|---|
| [`image/`](image/) | The runner image: [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner) plus what `ubuntu-latest` has and the base lacks (Node 24, Playwright's system libraries, C/C++ build tools), and a start script that wipes the previous job's files |
| [`compose/runner.yml`](compose/runner.yml) | The shared runner definition your deployment `extends` once per runner |
| [`bin/roll.sh`](bin/roll.sh) | Recreate runners only once they're idle, so a config change never kills a job |
| [`controller/`](controller/) | The **overflow controller**: priority tiers across machines, plus host-pressure mode ([docs/overflow.md](docs/overflow.md)) |
| [`maintenance/`](maintenance/) | The host watchdog: disk space, Time Machine snapshot thinning, runner upgrades, cache hygiene, pnpm store repair, controller heartbeat |
| [`macos/`](macos/) | Native macOS runners in a dedicated user's GUI session (for Electron, the iOS Simulator) |
| [`windows/`](windows/) | A native Windows runner as a service, and a sealed WSL2 distro for Linux x64 containers |
| [`examples/`](examples/) | Complete example deployments |

## How a deployment uses it

Keep your own configuration in a separate (private) repo and pull Werkbank in as a submodule,
pinned to a release:

```
my-ci/                       # your private deployment repo
  werkbank/                  # git submodule -> handarbeit/werkbank
  compose.yml                # your runners, each `extends: werkbank/compose/runner.yml`
  overflow.json              # controller config (org, repos, tiers, thresholds)
  macos-runners.conf         # native macOS runners, if any
  maintenance.env            # watchdog overrides, if any
  .env                       # the GitHub App's key (gitignored, mode 600)
```

```bash
git submodule add https://github.com/handarbeit/werkbank werkbank
cp werkbank/examples/mac/compose.yml werkbank/examples/mac/.env.example .
# edit compose.yml: `file: werkbank/compose/runner.yml`, your org, cpusets and labels
mv .env.example .env && chmod 600 .env    # then add the App's key: docs/github-app.md

docker compose build && docker compose up -d
werkbank/maintenance/install-launchd.sh "$PWD"                   # the watchdog (macOS)
werkbank/controller/install-launchd.sh "$PWD/overflow.json"      # the controller, if you use tiers
```

Then point workflows at the runners with a repo variable and a hosted fallback:

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}      # set CI_RUNNER=orb in the repo's variables
```

Unset the variable and the repo is back on GitHub-hosted runners, with no workflow change, for
example while a machine is away for repair.

To take a Werkbank upgrade, bump the submodule, read the changelog, and roll:
`werkbank/bin/roll.sh <service>...`.

## Docs

- [Credentials: a GitHub App](docs/github-app.md): why not a personal token, creating the App,
  wiring runners, the controller and native macOS runners to it.
- [Runners](docs/runners.md): the ephemeral model, cpusets, heap size, routing, safe restarts,
  light tier, and gotchas.
- [Overflow and priority tiers](docs/overflow.md): spilling to slower machines only when needed,
  and host-pressure mode.
- [pnpm on shared runners](docs/pnpm.md): sharing one store safely, and the action-setup trap.
- [macOS host](docs/macos-host.md): OrbStack, Time Machine snapshots, native macOS runners.
- [Windows host](docs/windows-host.md): a service runner, and WSL2 for Linux containers.

## Status

Werkbank is extracted from a working setup: a Mac Studio and a Windows PC serving a busy
GitHub org around the clock. Expect rough edges outside that shape, and please open issues.

## Licence

Apache-2.0, as Fabrik; see [LICENSE](LICENSE). The base image it builds on,
[`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner), is GPL-3.0;
Werkbank references it and doesn't redistribute it.
