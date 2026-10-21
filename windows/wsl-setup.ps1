# Linux x64 runners on a Windows machine: a dedicated WSL2 distro running Docker Engine and the
# same ephemeral runner image as any other werkbank host (../image), built for amd64.
#
#   .\wsl-setup.ps1 -Source <deployment dir> [-Processors 12] [-Memory 24GB] [-Location D:\wsl\ci-runners]
#
# Run elevated as an admin. -Source holds the deployment's compose.yml (extending
# werkbank/compose/runner.yml; see examples/wsl) and its .env. Re-runnable.
#
# Why a distro of its own rather than your everyday one:
# - It can live on a different drive (images and job trees grow the VHDX).
# - It is sealed off from Windows: no drive automount and no interop. In an ordinary distro,
#   /mnt/c is your whole disk with your permissions, and a container escape would land there.
# - It can be torn down (`wsl --unregister <distro>`) without touching anything of yours.
#
# Why .wslconfig changes: WSL runs every distro in one VM whose idle timeout would stop the runners
# the moment nothing Windows-side holds a session, and whose default size is half the machine.
# .wslconfig is shared by every distro on the machine; this rewrites it (keeping a backup).

param(
  [Parameter(Mandatory)][string]$Source,
  [string]$Distro = 'ci-runners',
  [string]$Location = 'D:\wsl\ci-runners',
  [int]$Processors = [Environment]::ProcessorCount,
  [string]$Memory = '24GB'
)

$ErrorActionPreference = 'Stop'
$Werkbank = Split-Path -Parent $PSScriptRoot
$Deploy   = "/opt/$Distro"

function Step($m) { Write-Host "==> $m" }
function InDistro([string]$cmd) {
  # A CRLF checkout (core.autocrlf) puts \r in multi-line commands; bash would choke on it.
  wsl.exe -d $Distro -u root -- bash -c ($cmd -replace "`r", '')
  if ($LASTEXITCODE) { throw "in $Distro failed ($LASTEXITCODE): $cmd" }
}

# 1. The WSL VM: sized for runners, never idled out --------------------------------------
Step '.wslconfig'
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
$want = @"
[wsl2]
# Written by werkbank's wsl-setup.ps1. Shared by every WSL distro on this machine.
processors=$Processors
memory=$Memory
# Never stop the VM when idle: the $Distro distro hosts self-hosted GitHub runners.
vmIdleTimeout=-1
"@
if (-not (Test-Path $cfg) -or (Get-Content $cfg -Raw) -ne $want) {
  if (Test-Path $cfg) { Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMddHHmmss)" }
  Set-Content -Encoding ascii $cfg $want
  wsl.exe --shutdown   # the VM only reads .wslconfig at start
}

# 2. The distro ----------------------------------------------------------------------------
Step 'distro'
$have = (wsl.exe -l -q) -replace "`0", '' | ? { $_ -eq $Distro }
if (-not $have) {
  New-Item -ItemType Directory -Force $Location | Out-Null
  wsl.exe --install Ubuntu-24.04 --name $Distro --location $Location --no-launch
  if ($LASTEXITCODE) { throw "wsl --install failed: $LASTEXITCODE" }
}

InDistro @'
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
[user]
default=root
EOF
'@
wsl.exe --terminate $Distro   # apply wsl.conf

# 3. Docker Engine ------------------------------------------------------------------------
Step 'docker'
InDistro 'command -v docker >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 >/dev/null; }; systemctl enable --now docker >/dev/null 2>&1; docker version --format "docker {{.Server.Version}}"'

# 4. The runners ---------------------------------------------------------------------------
Step 'runners'
if (-not (Test-Path (Join-Path $Source '.env'))) { Write-Host 'no .env (tokens) yet: skipping runners'; return }
# Interop is off, so the distro cannot read Windows files; pipe each one in: the deployment's
# compose.yml and .env, plus the werkbank files it extends. The image is built once by hand:
# compose would build it per service, and without buildx the second one fails on the tag the first
# just made.
InDistro "mkdir -p $Deploy/werkbank/image $Deploy/werkbank/compose && chmod 700 $Deploy"
$files = @{
  (Join-Path $Source 'compose.yml')                  = "$Deploy/compose.yml"
  (Join-Path $Source '.env')                         = "$Deploy/.env"
  (Join-Path $Werkbank 'image\Dockerfile')           = "$Deploy/werkbank/image/Dockerfile"
  (Join-Path $Werkbank 'image\clean-start.sh')       = "$Deploy/werkbank/image/clean-start.sh"
  (Join-Path $Werkbank 'compose\runner.yml')         = "$Deploy/werkbank/compose/runner.yml"
}
foreach ($f in $files.Keys) {
  Get-Content -Raw $f | wsl.exe -d $Distro -u root -- bash -c "tr -d '\r' > $($files[$f])"
}
$project = ($Distro.ToLower() -replace '[^a-z0-9_-]', '')
InDistro @"
set -e
cd $Deploy && chmod 600 .env && chmod 755 werkbank/image/clean-start.sh
image=`$(grep -s '^WERKBANK_IMAGE=' .env | cut -d= -f2-); image=`${image:-werkbank-runner:local}
docker build -q -t "`$image" werkbank/image
docker volume create ${project}_runner-caches >/dev/null
docker run --rm --entrypoint chown -v ${project}_runner-caches:/caches "`$image" runner:runner /caches
docker compose up -d --no-build --remove-orphans
docker compose ps --format '{{.Name}} {{.Status}}'
"@

# 5. Keep the distro running --------------------------------------------------------------
# With vmIdleTimeout=-1 the VM stays up, but a distro still stops once no wsl.exe session holds
# it. A scheduled task holds one open; a Windows-service runner needs no logon.
Step 'keep-alive task'
# conhost --headless: without it the task opens a console window on the desktop.
$action  = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless wsl.exe -d $Distro -u root -- sleep infinity"
# Log on, plus every 5 minutes: if anything stops the VM (`wsl --shutdown`, a WSL update, sleep) the
# holder dies with it, and the next tick starts it again (IgnoreNew skips the tick while it lives).
$trigger = @(
  (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
  (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$set     = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -MultipleInstances IgnoreNew `
             -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "$Distro WSL keep-alive" -Action $action -Trigger $trigger -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName "$Distro WSL keep-alive"

Step 'done'
