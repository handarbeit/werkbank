# macOS host

## Linux runners under OrbStack

[OrbStack](https://orbstack.dev) runs the Linux containers in a lightweight VM, so on Apple silicon
they're arm64, not the x64 of `ubuntu-latest`. Most Node, Python and Rust CI doesn't care; jobs
that download x64-only binaries do. Give the VM enough memory for every runner's `mem_limit`
(limits, not reservations, so they may add up to more than the VM). Check no runner is mid-job
before restarting OrbStack: restarting it restarts every container.

Docker Desktop works too; OrbStack has been faster and lighter for this.

## Time Machine local snapshots eat the disk

Time Machine takes an **hourly local snapshot of the whole volume** and keeps each one for 24
hours. Every snapshot pins whatever is deleted after it was taken, and a CI host deletes
constantly: finished containers, cache churn, and rewrites inside the VM's disk image. A busy day
of snapshots has held **over 100 GB** of already-deleted data.

- **Excluding paths from Time Machine doesn't help.** Exclusions only keep paths off the backup
  disk; a local snapshot still covers the whole volume.
- **The watchdog thins them**: every 15 minutes it deletes local snapshots older than
  `SNAPSHOT_KEEP_HOURS` (default 2), and thins harder below `WARN_GB` free. Backups on the Time
  Machine disk are untouched. Deleting snapshots by date needs no root.
- **A separate APFS volume** keeps data out of snapshots entirely. Time Machine only snapshots the
  volumes it backs up, so exclude the whole volume:
  `diskutil apfs addVolume disk3 APFS CI -quota 100g`. A volume in the same container shares free
  space and needs no fixed size; the quota caps runaway use. Docker VMs don't support relocating
  their disk image cleanly, though. Good candidates are agent worktrees and build output, not the
  VM's own disk.

## Native macOS runners (`macos/setup.sh`)

For jobs that need macOS itself: Xcode builds, the iOS Simulator, Electron end-to-end tests.

```bash
sudo bash werkbank/macos/setup.sh /path/to/macos-runners.conf   # see examples/mac/
```

- They run as a dedicated **standard** (non-admin) user, `ci`, so jobs can't use sudo or read other
  users' homes.
- Jobs need a **GUI session** (Electron windows, the Simulator), which a LaunchDaemon can't give
  them. So each runner is a LaunchAgent in `ci`'s own session: log `ci` in once with fast user
  switching, then switch back, and it keeps running. **After a reboot, `ci` must be logged in
  again** or macOS jobs queue.
- The script is re-runnable. It removes `RETIRED` runners first, registers missing ones, rewrites
  each runner's `.env` (`LANG`, because CocoaPods refuses to run without a UTF-8 locale, and
  `PATH`, because a launchd-started runner gets almost none), and installs a cleanup agent that
  runs every 6 h, between jobs only. Unlike the containers, these runners keep their files, and
  each iOS build leaves gigabytes of DerivedData and simulators behind.
- Registration tokens are passed to `curl` on stdin, not the command line, where any user's `ps`
  could see them.

## The watchdog (`maintenance/`)

`maintenance/install-launchd.sh /path/to/deployment` runs `host-maintenance.sh` every 15 minutes:

- Time Machine snapshot thinning (above).
- **Disk floor:** notify under `WARN_GB` free, stop the Linux runners under `STOP_GB` (a full disk
  can stop the Docker VM itself, taking every job down), restart them at `START_GB`.
- **Daily, only while no runner is mid-job:** wipe the shared cache volume past `CACHE_MAX_GB`
  (it refills on demand), and prune dangling images.
- **pnpm store repair** ([pnpm.md](pnpm.md)).
- **Controller heartbeat:** if the overflow controller's heartbeat is stale, warn and restore any
  shed runners ([overflow.md](overflow.md)).

Override any setting in `maintenance.env` in the deployment directory.
