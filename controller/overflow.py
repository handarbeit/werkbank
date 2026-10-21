#!/usr/bin/env python3
"""Priority bucketing for self-hosted runners: keep slower runners out of GitHub's choice
until the faster ones are full.

GitHub hands a queued job to *any* idle runner whose labels match, with no notion of
preference. So overflow runners register with a label workflows never ask for
(`orb-overflow`) instead of the routing label (`orb`), plus a `tier-N` label. This loop
watches the queue and, when queued `orb` jobs outnumber idle `orb` runners, adds `orb` to
idle overflow runners, best tier first. When the queue is empty it removes `orb` again.

An ephemeral runner re-registers after every job with its configured labels, so a promoted
runner drops back to hidden on its own; it is re-promoted only if the queue still needs it.
If this loop stops, overflow runners simply stay hidden: the failure is safe.

Host pressure. Queue depth alone misses one case: the primary host is pegged by work outside CI
(say, coding agents running builds and tests on it) while CI has idle `orb` slots there, so jobs
never queue but run slowly on a contended host, and the overflow tier sits idle. When the host's 5-minute
load average passes pressure_load_high, the loop enters pressure mode: it promotes every idle
overflow runner and hides ("sheds") idle primary runners by swapping `orb` for `orb-shed`, so new
jobs go to the overflow tier first. If jobs then queue, shed runners come back before anything
else waits. Below pressure_load_low (hysteresis) every shed runner is restored. Busy runners are
never touched. A shed runner does NOT recover on its own (it is idle, so it never re-registers),
so this loop restores them at startup and on exit, and the host watchdog runs `--restore` if the
heartbeat goes stale.

Run:  overflow.py [--config PATH] [--once] [--dry-run] [--restore]
Config: --config, else $WERKBANK_OVERFLOW_CONFIG, else ./overflow.json (see examples/overflow.json).
Uses the `gh` CLI with the org token named in the config (token_var), read from the config's
env_file (default: .env next to the config).
"""
import json, os, signal, subprocess, sys, time
from pathlib import Path

def _arg(flag):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv[:-1] else None


CFG_PATH = Path(_arg("--config") or os.environ.get("WERKBANK_OVERFLOW_CONFIG") or "overflow.json").resolve()
CFG = json.loads(CFG_PATH.read_text())
ORG = CFG["org"]
WANT = CFG["routing_label"]            # what workflows ask for: "orb"
HIDDEN = CFG["overflow_label"]         # what overflow runners carry instead: "orb-overflow"
TIERS = CFG["overflow_tiers"]          # best first, e.g. ["tier-2", "tier-3"]
SHED = CFG["shed_label"]               # marks a primary runner hidden for host pressure: "orb-shed"
LOAD_HIGH = CFG["pressure_load_high"]  # 5-min load average that starts pressure mode
LOAD_LOW = CFG["pressure_load_low"]    # ...and that ends it
REPOS = CFG["repos"]                   # repos whose queues count as demand
DRY = "--dry-run" in sys.argv
_DEFAULT_STATE = ("~/Library/Application Support/werkbank/overflow" if sys.platform == "darwin"
                  else "~/.local/state/werkbank/overflow")
STATE = Path(os.path.expanduser(CFG.get("state_dir", _DEFAULT_STATE)))

# Credentials: an org token from the env file (fine-grained: org "Self-hosted runners: read and
# write" to change labels, repo "Actions: read" to see queued jobs), not a personal `gh` login, so
# the loop runs the same under launchd or systemd. Nothing else in the env file is used.
_ENV_FILE = (CFG_PATH.parent / CFG.get("env_file", ".env")).resolve()
_env = {k: v for k, _, v in (l.partition("=") for l in _ENV_FILE.read_text().splitlines()) if v}
os.environ["GH_TOKEN"] = _env[CFG["token_var"]]
STATE.mkdir(parents=True, exist_ok=True)


def log(msg):
    print(f"{time.strftime('%F %T')} {msg}", flush=True)


def gh(*args, method="GET"):
    out = subprocess.run(["gh", "api", "-X", method, *args], capture_output=True, text=True, timeout=60)
    if out.returncode:
        raise RuntimeError(f"gh api {' '.join(args)}: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout) if out.stdout.strip() else None


def runners():
    rs, page = [], 1
    while True:
        r = gh(f"orgs/{ORG}/actions/runners?per_page=100&page={page}")
        rs += r["runners"]
        if len(rs) >= r["total_count"] or not r["runners"]:
            return rs
        page += 1


def queued_orb_jobs():
    """Jobs waiting for an `orb` runner. A run that is in progress can still hold queued jobs."""
    n = 0
    for repo in REPOS:
        for status in ("queued", "in_progress"):
            runs = gh(f"repos/{ORG}/{repo}/actions/runs?status={status}&per_page=50")["workflow_runs"]
            for run in runs:
                jobs = gh(f"repos/{ORG}/{repo}/actions/runs/{run['id']}/jobs?per_page=100")["jobs"]
                n += sum(1 for j in jobs if j["status"] == "queued" and WANT in j.get("labels", []))
    return n


def labels(r):
    return {l["name"] for l in r["labels"]}


def tier_rank(r):
    ls = labels(r)
    return next((i for i, t in enumerate(TIERS) if t in ls), len(TIERS))


def promote(r):
    log(f"promote {r['name']} ({'/'.join(sorted(labels(r) & set(TIERS)))})" + (" [dry-run]" if DRY else ""))
    if not DRY:
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels", "-f", f"labels[]={WANT}", method="POST")


def demote(r):
    log(f"demote {r['name']}" + (" [dry-run]" if DRY else ""))
    if not DRY:
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels/{WANT}", method="DELETE")


def shed(r):
    log(f"shed {r['name']} (host pressure)" + (" [dry-run]" if DRY else ""))
    if not DRY:
        # Marker first: if the second call fails, the runner is still visible and still tracked.
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels", "-f", f"labels[]={SHED}", method="POST")
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels/{WANT}", method="DELETE")


def unshed(r, why):
    log(f"restore {r['name']} ({why})" + (" [dry-run]" if DRY else ""))
    if not DRY:
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels", "-f", f"labels[]={WANT}", method="POST")
        gh(f"orgs/{ORG}/actions/runners/{r['id']}/labels/{SHED}", method="DELETE")


def restore_all(why):
    for r in runners():
        if SHED in labels(r):
            unshed(r, why)


def host_load():
    return os.getloadavg()[1]                      # 5-minute; this loop runs on the host it protects


def tick(memo):
    rs = [r for r in runners() if r["status"] == "online"]
    serving = [r for r in rs if WANT in labels(r)]                 # visible to `orb` jobs
    idle = [r for r in serving if not r["busy"]]
    overflow = [r for r in rs if HIDDEN in labels(r)]
    hidden_idle = sorted((r for r in overflow if WANT not in labels(r) and not r["busy"]), key=tier_rank)
    promoted_idle = [r for r in overflow if WANT in labels(r) and not r["busy"]]
    primary_idle = [r for r in idle if HIDDEN not in labels(r)]
    shed_rs = [r for r in rs if SHED in labels(r)]
    queued = queued_orb_jobs()
    deficit = queued - len(idle)
    load = host_load()
    was = memo.get("pressure", False)
    memo["pressure"] = load >= LOAD_HIGH or (was and load > LOAD_LOW)
    if memo["pressure"] != was:
        log(f"host pressure {'ON' if memo['pressure'] else 'OFF'}: 5-min load {load:.0f}")
    memo["deficit_ticks"] = memo.get("deficit_ticks", 0) + 1 if deficit > 0 else 0
    memo["empty_ticks"] = memo.get("empty_ticks", 0) + 1 if queued == 0 else 0
    line = (f"queued={queued} serving={len(serving)} idle={len(idle)} "
            f"overflow={len(overflow)} hidden_idle={len(hidden_idle)} promoted_idle={len(promoted_idle)} "
            f"shed={len(shed_rs)}" + (" PRESSURE" if memo["pressure"] else ""))
    if line != memo.get("last"):
        log(line)
        memo["last"] = line
    if memo["pressure"]:
        # The overflow tier goes first; the host's own runners step aside while idle.
        for r in hidden_idle:
            promote(r)
        for r in primary_idle:
            shed(r)
        # Jobs still waiting: bring shed runners back rather than let anything sit in the queue.
        if memo["deficit_ticks"] >= CFG["promote_after_ticks"]:
            for r in shed_rs[:deficit]:
                unshed(r, "queue under pressure")
    else:
        if shed_rs:
            for r in shed_rs:
                unshed(r, "pressure over")
        # Spill over only once the shortfall has lasted a couple of ticks: a faster runner that is
        # just finishing a job would otherwise pull a slower one in for nothing.
        if memo["deficit_ticks"] >= CFG["promote_after_ticks"]:
            for r in hidden_idle[:deficit]:
                promote(r)
        # Withdraw idle promoted runners once the queue has stayed empty for a while.
        if memo["empty_ticks"] >= CFG["demote_after_ticks"]:
            for r in promoted_idle:
                demote(r)
    (STATE / "heartbeat").write_text(time.strftime("%F %T") + " " + line + "\n")


def main():
    # launchd stops the agent with SIGTERM; turn it into SystemExit so the shutdown restore runs.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if "--restore" in sys.argv:                    # used by the watchdog when this loop is down
        restore_all("restore requested")
        return
    memo = {}
    log(f"start org={ORG} repos={','.join(REPOS)} tiers={','.join(TIERS)} "
        f"pressure={LOAD_HIGH}/{LOAD_LOW}" + (" DRY-RUN" if DRY else ""))
    try:
        restore_all("startup")                     # a previous run may have died mid-pressure
    except Exception as e:
        log(f"error: {e}")
    try:
        while True:
            try:
                tick(memo)
            except Exception as e:                 # keep going; GitHub hiccups are routine
                log(f"error: {e}")
            if "--once" in sys.argv:
                return
            time.sleep(CFG["interval_seconds"])
    finally:
        if not DRY and "--once" not in sys.argv:
            try:
                restore_all("shutdown")
            except Exception as e:
                log(f"error: {e}")


if __name__ == "__main__":
    main()
