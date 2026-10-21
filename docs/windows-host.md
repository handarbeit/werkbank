# Windows host

An old desktop PC makes a good second CI machine. It runs two kinds of runner, side by side.

## Native Windows runner (`windows/setup.ps1`)

For jobs that need Windows itself (MSVC builds, Windows packaging), as a Windows service:

```powershell
.\windows\setup.ps1 -Url https://github.com/<owner>/<repo> -RunnerName win-1 -Labels orb-win `
  -Root D:\ -DenyPaths C:\dev -RegistrationToken <token>
```

- The service logs on as a **standard local user `ci`**, never an admin. Windows grants Modify to
  Authenticated Users on new folders and data drives by default, so pass your own working trees as
  `-DenyPaths` and data drives as `-WriteDenyPaths`.
- Everything the runner owns lives under `-Root`: the runner and its work tree, plus rustup, cargo
  and vcpkg. A **ReFS Dev Drive** makes builds noticeably faster. Defender excludes both trees.
- **Job `PATH` is an allowlist**, written to the runner's `.env`. A developer's PATH typically
  carries msys (which shadows cmd, sh and openssl), Git's `mingw64\bin` (whose OpenSSL DLLs can
  silently satisfy a build's imports and hide real bugs) and nvm. Git's `bin` comes before
  `System32`, so `shell: bash` is Git Bash, not WSL's `bash.exe`.
- PowerShell 7 is installed machine-wide (`shell: pwsh`).
- rustup's proxies (`cargo.exe`, `rustc.exe`, ...) are symlinks to `rustup.exe`, and Windows can
  refuse to launch a process through one (os error 448). The script replaces them with hardlinks.
- Power settings: no sleep or hibernate on AC. A runner that sleeps is a queue that never drains.

Warm builds on a self-hosted Windows runner can be dramatically faster than on GitHub-hosted
runners, which start cold every time. We saw ~2 min against 16–20.

## Linux x64 containers in WSL2 (`windows/wsl-setup.ps1`)

The same ephemeral runner image as on any other host, built for amd64, in **a WSL2 distro of its
own**:

```powershell
.\windows\wsl-setup.ps1 -Source C:\path\to\deployment -Processors 12 -Memory 24GB
```

- **Sealed off from Windows**: no drive automount and no interop. In an ordinary distro, `/mnt/c` is
  your whole disk with your permissions, and a container escape would land there. Because interop
  is off, the script pipes the deployment files into the distro, to `/opt/<distro>/`.
- **Sized and never idled out.** `.wslconfig` sets processors and memory and
  `vmIdleTimeout=-1`, because WSL's default idle timeout stops the VM, and every runner in it, the
  moment nothing Windows-side holds a session. `.wslconfig` is shared by every distro on the
  machine. The script backs it up, and applying a new one restarts the VM, so only do that while
  its runners are idle.
- **A keep-alive task.** Even with the VM up, a distro stops once no `wsl.exe` session holds it. A
  scheduled task (at logon and every 5 minutes, headless via `conhost --headless`) holds one open
  and starts it again if anything stops it.
- **Docker Engine inside the distro**, not Docker Desktop.
- Can be torn down with `wsl --unregister <distro>` without touching anything else.

An older x64 CPU will be slower than an Apple-silicon Mac; a 2018 6-core desktop ran unit tests
about 2.3x slower than a Mac Studio. That's the case for making it an overflow tier
([overflow.md](overflow.md)).

## Remote access

SSH with a dedicated key works well for administration; an admin SSH session is elevated already.
If your SSH config sends everything through an agent such as 1Password's, pass
`-o IdentitiesOnly=yes -o IdentityAgent=none -i <key>` for this host.
