# Alerts

The watchdog (`maintenance/host-maintenance.sh`, every 15 minutes on each host) raises an alert
when it has to act or when something needs a person:

| Alert | Pushover priority |
|---|---|
| Disk nearly full: Linux runners stopped | 1 (high) |
| Runners down: another host's runners are missing (`EXPECT_RUNNERS`, below) | 1 |
| Docker not reachable on this host, two runs in a row | 1 |
| Overflow controller stopped | 1 |
| Disk space low, disk space recovered, runners back, Docker back | 0 |
| Runner image rebuilt (or failed to), broken pnpm store wiped | 0 |

Every alert goes to the host itself (a desktop notification on macOS, the journal on Linux as
`logger -t werkbank`), which nobody sees on a headless box. To get them on a phone, add Pushover.

## Pushover

1. In Pushover, create an application (for example "CI runners") and note its API token, and your
   user key.
2. On each host, add both to the deployment's `.env` by hand (mode 600, never committed):

   ```sh
   PUSHOVER_TOKEN=...
   PUSHOVER_USER=...
   ```

That's all. The watchdog reads the two values from `.env` without sourcing it, and passes them
to `curl` on stdin, so they never appear in `ps`. Compose reads `.env` only to fill in `${...}`,
and services name their credentials one by one, so jobs never see these keys. Each message's
title is `CI runners: <host>` (override with `HOST_LABEL` in `maintenance.env`). If the send
fails, the watchdog logs it and carries on.

To check the keys, send a test message from the deployment directory. This reads the two values
the way the watchdog does, rather than sourcing `.env`, which may hold a multi-line App key:

```sh
v() { grep "^$1=" .env | tail -1 | cut -d= -f2- | tr -d "\"'"; }
printf 'form-string = "token=%s"\nform-string = "user=%s"\n' "$(v PUSHOVER_TOKEN)" "$(v PUSHOVER_USER)" \
  | curl -fsS -K - --form-string "message=test from $(hostname -s)" https://api.pushover.net/1/messages.json
```

## Watching the other hosts (`EXPECT_RUNNERS`)

A host that has crashed or lost power can't report itself. So each host's watchdog can check, on
GitHub, that another host's runners are online. List the groups in `maintenance.env`, one per
line: the API scope the runners are registered at, a runner name prefix, and the minimum that
should be online:

```sh
EXPECT_RUNNERS="orgs/my-org mac-studio- 3
orgs/my-org windows-box-win 1
repos/me/my-app mac-studio-my-app 1"
```

When fewer than the minimum are online on two runs in a row (about 15 to 30 minutes), it alerts
once; when they are back, it says so. Two runs, because an ephemeral runner is unregistered for a
few seconds between jobs. A failed GitHub call counts as neither down nor up.

It needs to read runners: a `gh` login on the host, or, without one, an App token from the
overflow controller's config (`overflow.py --token`; the App needs "Self-hosted runners: read",
which [github-app.md](github-app.md) already grants). A repo-scoped group needs a credential that
can read that repo's runners.

Point the hosts at each other: the Linux box watches the Mac and the Windows box, and the Mac
watches the Linux box. Then any single host going down is reported by another.
