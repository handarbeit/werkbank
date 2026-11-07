# Linux host

A dedicated Linux box is the simplest place to run Werkbank's Linux runners: Docker Engine runs the
containers directly, with no VM, so jobs get every core and all the memory, and on x64 they match
`ubuntu-latest`. This is how to set one up so it runs unattended, and what went wrong the first time.

[`examples/linux/`](../examples/linux/) is a complete deployment for such a box.

## The OS and Docker

- **Ubuntu Server LTS**, the full install (not minimized), with OpenSSH. Install **Docker Engine from
  Docker's apt repository** ([docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/)),
  not the Docker snap the installer offers: the snap confines Docker's data and lags releases.
- Ubuntu's installer gives the root logical volume only part of an LVM disk (100 GB, for example).
  Grow it to the whole disk: `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`.
- **Unused network ports can stall boot.** netplan makes `systemd-networkd-wait-online` wait for every
  port it configures, so a box with several ports and one cable sits at "Job
  systemd-networkd-wait-online.service/start" for about two minutes. Mark every port that may be
  unplugged `optional: true` in `/etc/netplan/*.yaml`. If two ports both get DHCP, give each a
  `route-metric` in both `dhcp4-overrides` and `dhcp6-overrides`, or netplan rejects the file.

## Docker's data on its own drive

CI writes constantly: every job unpacks a fresh container filesystem, installs dependencies and builds.
On one host that came to about 270 GB a day. Put it on a fast drive of its own, and keep the OS drive
for the OS. That matters most if the OS drive is a cheap QLC or DRAM-less one, as small PCs often ship
with.

- **Move both `/var/lib/docker` and `/var/lib/containerd`.** Docker 29 uses the containerd image
  store by default, so images and container filesystems live under `/var/lib/containerd`. Moving only
  Docker's directory leaves the heavy part on the OS drive.
- **Bind-mount** both from the data drive rather than changing `data-root`, so every tool finds them
  where it expects. In `/etc/fstab`:
  ```
  UUID=<data partition>  /srv/ci-disk  ext4  defaults,noatime  0 2
  /srv/ci-disk/docker      /var/lib/docker      none  bind,x-systemd.requires-mounts-for=/srv/ci-disk  0 0
  /srv/ci-disk/containerd  /var/lib/containerd  none  bind,x-systemd.requires-mounts-for=/srv/ci-disk  0 0
  ```
  Mount by UUID: NVMe device names (`nvme0n1`, `nvme1n1`) can swap between boots.
- **Make Docker refuse to start without the drive.** Otherwise a drive that fails to mount means
  Docker silently starts empty on the OS drive and fills it. Add a drop-in for each service, e.g.
  `/etc/systemd/system/docker.service.d/10-require-disk.conf`:
  ```
  [Unit]
  RequiresMountsFor=/var/lib/docker /var/lib/containerd
  ```
  and the same for `containerd.service` with `/var/lib/containerd`.
- To move existing data: stop docker and containerd, copy or empty both directories, mount, and start them.
- **Check the PCIe link.** Some small PCs ship with their M.2 slots capped at PCIe Gen3 in the BIOS,
  so a Gen4 drive runs at half its speed. Compare `/sys/class/nvme/nvme*/device/current_link_speed`
  with `max_link_speed`. If the OS logs a steady trickle of correctable PCIe errors for a drive
  (`journalctl -k | grep "AER: Correctable"`), capping that slot at Gen3 in the BIOS usually stops
  them, and for an OS-only drive the cost is invisible.
- The watchdog should watch both drives: `DISKS="/ /srv/ci-disk"` in `maintenance.env`.

## Keep upgrades from killing jobs

Ubuntu's unattended security upgrades run **needrestart**, which restarts services whose libraries
changed. A restart of containerd or docker kills every running container, mid-job. Exclude them; they
pick up the new libraries at the next reboot. In `/etc/needrestart/conf.d/50-ci.conf`:

```perl
$nrconf{override_rc}{qr(^containerd)} = 0;
$nrconf{override_rc}{qr(^docker)} = 0;
```

## CPU and memory

- **cpusets of whole cores.** Pin each runner to whole physical cores *with their SMT siblings*, never
  half a core shared with another runner. `lscpu -e` lists each thread's core, or read
  `/sys/devices/system/cpu/cpu0/topology/thread_siblings_list`. On many AMD and Intel parts, core N's
  sibling is N + (number of cores), so on 16 cores / 32 threads, "0-3,16-19" is cores 0-3. Keep each
  cpuset inside one CCD or L3 domain (`lscpu -e`'s `L3` column).
- **How many threads per runner.** Fewer, bigger runners finish heavy test suites faster; more,
  smaller ones run more jobs at once. On one 16-core host, a test-heavy job took about 1,150 s with
  4 threads and 635 s with 8 (its load inside a 4-thread cpuset was ~11). Everything else ran fine on
  either. Measure your own heaviest job before choosing.
- **No swap for jobs.** By default a container may swap as much again as its `mem_limit`, onto the
  host's swap. Set `memswap_limit` equal to `mem_limit`, so a job that outgrows its memory fails fast
  instead of crawling. Lowering the host's `vm.swappiness` (to 10, in `/etc/sysctl.d/`) helps too.
- **The performance governor** is worth having on a dedicated CI box: with `amd-pstate-epp` it also
  sets the energy-performance preference to performance. A oneshot systemd unit can write
  `performance` to every `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` at boot. Mobile and
  mini-PC chips then run hot under load (90-95 °C is their normal boost behaviour, not throttling);
  give the box airflow.

## A service user

Run everything as a dedicated, unprivileged user, here `ci`, in the `docker` group, with **linger**,
so its systemd user services run without anyone logged in:

```bash
sudo useradd --system --create-home --shell /bin/bash ci
sudo usermod -aG docker ci && sudo loginctl enable-linger ci
sudo install -d -o ci -g ci -m 755 /opt/my-ci
```

- Keep the deployment as a **git checkout** of your private deployment repo, owned by `ci`, at
  `/opt/my-ci`, with Werkbank as its submodule. A **read-only deploy key** for that one repo is
  enough. An ssh host alias in `~ci/.ssh/config` (`Host github-my-ci`, `HostName github.com`,
  `IdentityFile ~/.ssh/my-ci-deploy`, `IdentitiesOnly yes`) makes `git pull` use it.
- `.env` (the App's key) sits in the deployment directory with mode 600, owned by `ci`. Place it by hand.
- Run commands as `ci` with `sudo -u ci -H bash -c "cd /opt/my-ci && docker compose ps"`.
  `sudo -iu ci bash -c "..."` mangles multi-line commands.
- `systemctl --user` as `ci` from another account needs its runtime directory:
  `sudo -u ci -H env XDG_RUNTIME_DIR=/run/user/$(id -u ci) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u ci)/bus systemctl --user status`.
  Its logs: `sudo journalctl _SYSTEMD_USER_UNIT=<unit>.service`.

## The controller and the watchdog

Both install as `ci`'s systemd user units:

```bash
werkbank/controller/install-systemd.sh /opt/my-ci/overflow.json         # service: werkbank-overflow
werkbank/maintenance/install-systemd.sh /opt/my-ci                      # timer: werkbank-maintenance, every 15 min
```

- Both need the **`gh` CLI** (Ubuntu's `gh` package is enough) but **no `gh` login**. The controller
  hands `gh` an App installation token itself. The watchdog's `bin/roll.sh` call borrows one from
  `overflow.py --config overflow.json --token` when `gh` isn't logged in. By hand:
  `GH_TOKEN=$(python3 werkbank/controller/overflow.py --config overflow.json --token) werkbank/bin/roll.sh pool-1`.
- If the controller runs here and a busy workstation is an overflow tier, that workstation can report
  its load to the controller's account over ssh: see [overflow.md](overflow.md), "Busy overflow
  hosts". The reporter's key goes in `~ci/.ssh/authorized_keys` restricted to `receive-load.sh` and
  pinned to its tier. Leave **host pressure** off on a box that runs nothing but CI: its load is the
  runners' own, so it would only shed runners because of their jobs.
- On Linux the watchdog's alerts go to the journal (`logger -t werkbank`), not to a desktop. Its
  actions (stopping runners on a full disk, restoring after a stale controller) still happen.

## Running unattended

- In the BIOS, set **power on after AC loss**, so the box comes back after a power cut. From the OS,
  `sudo systemctl reboot --firmware-setup` reboots straight into setup. Stop the runners first.
- Boot to runners takes well under a minute: Docker brings the containers back (`restart: always`),
  and they register again.
- Test it once by pulling the plug while the runners are idle.
