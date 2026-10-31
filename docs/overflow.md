# Overflow and priority tiers

GitHub hands a queued job to *any* idle runner whose labels match. If you have a fast machine and
a slow one, jobs land on the slow one as often as on the fast one, even when the fast one is idle.
`controller/overflow.py` adds the missing preference.

## How it works

- **Primary runners** carry the routing label workflows ask for, `orb`.
- **Overflow runners** register *hidden*. They carry `orb-overflow` and a tier label (`tier-2`,
  `tier-3`) instead of `orb`, so no `orb` job can land on them.
- **The controller** polls every 15 s. When queued `orb` jobs in the configured repos outnumber
  idle `orb` runners for two ticks in a row, it **adds `orb`** to idle overflow runners, best tier
  first, through GitHub's runner-labels API. Requiring two ticks stops a fast runner that's just
  finishing a job from pulling a slow one in for nothing.
- **Demotion is mostly free.** An ephemeral runner re-registers after every job with its
  configured labels, so a promoted runner falls back to hidden after its one job. Idle promoted
  runners are demoted after `demote_after_ticks` ticks of empty queue.
- **Failure is safe.** If the controller stops, overflow runners stay hidden and primary runners
  carry on. Spill-over capacity is gone until it's back, but nothing breaks. The watchdog warns
  when the heartbeat goes stale.

Adding a machine as a new first choice later is a relabel: give it `orb`, and give the old primary
`orb-overflow` + `tier-2`.

## Host pressure

Queue depth misses one case: the primary host is overloaded by work *outside* CI (developers or
coding agents running builds and tests on it) while CI still has idle `orb` slots there. Nothing
queues, so the controller never acts, but every job runs slowly on a contended host while the
overflow tier sits idle.

When the host's 5-minute load average reaches `pressure_load_high`, the controller enters
pressure mode:

- it promotes **every** idle overflow runner;
- it **sheds** idle primary runners, swapping `orb` for `orb-shed`, so new jobs go to the overflow
  tier first;
- if jobs queue anyway, shed runners come back before anything waits;
- below `pressure_load_low` (hysteresis), every shed runner is restored.

Busy runners are never touched.

**A shed runner doesn't recover by itself:** it's idle, so it never re-registers. So the controller
restores every shed runner at startup and on SIGTERM, and the watchdog runs
`overflow.py --restore` whenever the controller's heartbeat is stale. By hand:
`python3 controller/overflow.py --config overflow.json --restore`.

The load is read with `os.getloadavg()`, so the controller must run **on the primary host** for
pressure mode to mean anything.

## Config (`overflow.json`)

| Key | Meaning |
|---|---|
| `org` | The org whose runners and repos are managed |
| `token_var`, `env_file` | Which variable in which env file (relative to the config) holds the token: fine-grained, org "Self-hosted runners: read and write", repo "Actions: read" on the watched repos |
| `routing_label` | What workflows ask for (`orb`) |
| `overflow_label` | What hidden overflow runners carry instead (`orb-overflow`) |
| `overflow_tiers` | Tier labels, best first |
| `shed_label` | Marks a primary runner hidden for host pressure (`orb-shed`) |
| `pressure_load_high`, `pressure_load_low` | 5-minute load average that starts and ends pressure mode. Start around 1.5x the core count for high and 1x for low, then tune |
| `repos` | Repos whose queues count as demand. **Add every repo that uses the pool**, or its queue is invisible to the controller |
| `interval_seconds`, `promote_after_ticks`, `demote_after_ticks` | Timing |
| `state_dir` | Where the heartbeat goes (default `~/Library/Application Support/werkbank/overflow` on macOS, `~/.local/state/werkbank/overflow` elsewhere) |

## Running it

```bash
python3 controller/overflow.py --config overflow.json --once --dry-run   # one tick, no changes
controller/install-launchd.sh /path/to/overflow.json                     # macOS LaunchAgent
controller/install-systemd.sh /path/to/overflow.json                     # Linux user service
```

It needs the `gh` CLI (for label changes). A tick reads the runner list, each repo's queued and
in-progress runs, and every such run's jobs, which used to come to thousands of calls an hour on a
busy org: enough to exhaust a token's 5,000-an-hour quota, which it shares with everything else
using that token. Reads are now conditional, and GitHub doesn't charge for an unchanged answer
(304), so a tick costs one or two calls, a few hundred an hour. If the quota runs out anyway,
the controller waits for the reset rather than erroring every tick.
