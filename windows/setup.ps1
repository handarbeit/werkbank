# A self-hosted GitHub Actions runner for native Windows jobs, as a Windows service.
#
#   .\setup.ps1 -Url https://github.com/<owner>/<repo> -RunnerName <name> [-Labels orb-win]
#               [-Root D:\] [-DenyPaths C:\dev] [-WriteDenyPaths F:\,G:\] [-RegistrationToken <t>]
#
# Run elevated as an admin (an admin SSH session is elevated already). Re-runnable: every step
# checks before it acts. Pass -RegistrationToken only when (re)registering the runner; get one with
#   gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token
#
# Shape, and why:
# - The runner is a Windows service logged on as a standard (non-admin) local user `ci`, never
#   the admin who runs this. `ci` gets no access to -DenyPaths (say, your own working trees, which
#   Windows grants Modify to Authenticated Users by default) and no write on -WriteDenyPaths
#   (data drives with the same default).
# - Everything the runner owns lives under -Root: the runner, its _work tree, and the toolchains
#   jobs use (rustup/cargo, vcpkg). A ReFS Dev Drive is a good choice. Defender excludes both trees.
# - Job PATH is pinned in the runner's .env to an allowlist. An interactive PATH often carries msys
#   (shadows cmd/sh/openssl), Git's mingw64\bin (ships OpenSSL DLLs that can silently satisfy a
#   build's imports) and nvm; none of that may leak into a build. Git\bin comes before System32 so
#   `shell: bash` is Git Bash, not WSL's bash.exe.
# - The machine-wide PowerShell 7 install is the one global change: workflows use `shell: pwsh`.

param(
  [string]$RegistrationToken,
  [Parameter(Mandatory)][string]$Url,
  [Parameter(Mandatory)][string]$RunnerName,
  [string]$Labels = 'orb-win',
  [string]$Root = 'D:\',
  [string[]]$DenyPaths = @(),
  [string[]]$WriteDenyPaths = @(),
  [string]$Admin = $env:USERNAME
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RunnersRoot = Join-Path $Root 'actions-runners'
$RunnerDir   = Join-Path $RunnersRoot $RunnerName
$CiRoot      = Join-Path $Root 'ci'
$RustupHome  = Join-Path $CiRoot 'rustup'
$CargoHome   = Join-Path $CiRoot 'cargo'
$VcpkgRoot   = Join-Path $CiRoot 'vcpkg'
$CredFile    = Join-Path $RunnersRoot 'ci-credential.xml'   # DPAPI: only $Admin on this machine can read it

function Step($m) { Write-Host "==> $m" }

# 1. The `ci` user ----------------------------------------------------------------------------
Step 'ci user'
if (Test-Path $CredFile) {
  $cred = Import-Clixml $CredFile
} else {
  $plain = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | % { [char]$_ }) + '!a1'
  $cred = New-Object PSCredential('ci', (ConvertTo-SecureString $plain -AsPlainText -Force))
  New-Item -ItemType Directory -Force $RunnersRoot | Out-Null
  $cred | Export-Clixml $CredFile
}
if (-not (Get-LocalUser -Name ci -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name ci -Password $cred.Password -FullName 'GitHub Actions runner' `
    -Description 'Self-hosted GitHub Actions runner' `
    -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
} else {
  Set-LocalUser -Name ci -Password $cred.Password   # keep it in step with the credential file
}

# 2. Directories and ACLs -------------------------------------------------------------------
Step 'directories and ACLs'
foreach ($d in $RunnersRoot, $RunnerDir, $CiRoot) { New-Item -ItemType Directory -Force $d | Out-Null }
icacls $RunnersRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' "${Admin}:(OI)(CI)F" | Out-Null
# The runner insists on reading every directory above its own; this folder only, no inheritance,
# so the credential file stays unreadable to ci.
icacls $RunnersRoot /grant 'ci:(RX)' | Out-Null
icacls $RunnerDir /grant:r 'ci:(OI)(CI)M' | Out-Null
icacls $CredFile /inheritance:r /grant:r "${Admin}:F" 'SYSTEM:F' | Out-Null
icacls $CiRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' "${Admin}:(OI)(CI)F" 'ci:(OI)(CI)M' | Out-Null
foreach ($p in $DenyPaths) { if (Test-Path $p) { icacls $p /deny 'ci:(OI)(CI)F' | Out-Null } }
foreach ($p in $WriteDenyPaths) { if (Test-Path $p) { icacls $p /deny 'ci:(OI)(CI)(W,D,DC)' | Out-Null } }

# 3. Defender -------------------------------------------------------------------------------
Step 'Defender exclusions'
$have = @((Get-MpPreference).ExclusionPath)
foreach ($p in $RunnersRoot, $CiRoot) { if ($have -notcontains $p) { Add-MpPreference -ExclusionPath $p } }

# 4. Power: a runner that sleeps is a queue that never drains --------------------------------
Step 'power'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# 5. PowerShell 7 (workflows use shell: pwsh) ------------------------------------------------
Step 'PowerShell 7'
$pwshDir = 'C:\Program Files\PowerShell\7'
if (-not (Test-Path "$pwshDir\pwsh.exe")) {
  $rel = Invoke-RestMethod https://api.github.com/repos/PowerShell/PowerShell/releases/latest
  $msi = $rel.assets | ? name -match 'win-x64\.msi$' | Select -First 1
  $out = Join-Path $env:TEMP $msi.name
  Invoke-WebRequest $msi.browser_download_url -OutFile $out
  Start-Process msiexec.exe -Wait -ArgumentList "/i `"$out`" /quiet /norestart ADD_PATH=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=0 ENABLE_MU=0"
}

# 6. Rust, on D:, for ci -------------------------------------------------------------------
Step 'rustup'
if (-not (Test-Path "$CargoHome\bin\rustup.exe")) {
  $init = Join-Path $env:TEMP 'rustup-init.exe'
  Invoke-WebRequest https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe -OutFile $init
  $env:RUSTUP_HOME = $RustupHome; $env:CARGO_HOME = $CargoHome
  & $init -y --no-modify-path --profile minimal --default-toolchain stable -c clippy
  if ($LASTEXITCODE) { throw "rustup-init failed: $LASTEXITCODE" }
}
# rustup lays its proxies (cargo.exe, rustc.exe, ...) down as symlinks to rustup.exe, and Windows
# can refuse to launch a process through one (os error 448). Hardlinks behave identically.
Get-ChildItem "$CargoHome\bin" -Filter *.exe | ? LinkType -eq 'SymbolicLink' | % {
  Remove-Item $_.FullName
  New-Item -ItemType HardLink -Path $_.FullName -Target "$CargoHome\bin\rustup.exe" | Out-Null
}

# 7. vcpkg, on D:, for ci ------------------------------------------------------------------
Step 'vcpkg'
if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
  if (-not (Test-Path "$VcpkgRoot\.git")) { git clone --quiet https://github.com/microsoft/vcpkg $VcpkgRoot }
  & "$VcpkgRoot\bootstrap-vcpkg.bat" -disableMetrics
  if ($LASTEXITCODE) { throw "vcpkg bootstrap failed: $LASTEXITCODE" }
}
# The runner runs git in here as ci; git refuses a repo owned by someone else.
$safe = $VcpkgRoot -replace '\\', '/'
if (@(git config --system --get-all safe.directory) -notcontains $safe) { git config --system --add safe.directory $safe }

# 8. The runner ---------------------------------------------------------------------------
Step 'runner'
if (-not (Test-Path "$RunnerDir\config.cmd")) {
  $rel = Invoke-RestMethod https://api.github.com/repos/actions/runner/releases/latest
  $zip = $rel.assets | ? name -match '^actions-runner-win-x64-[\d.]+\.zip$' | Select -First 1
  $out = Join-Path $env:TEMP $zip.name
  Invoke-WebRequest $zip.browser_download_url -OutFile $out
  Expand-Archive $out -DestinationPath $RunnerDir -Force
}

# Job environment. The runner reads .env at start; PATH here replaces the service account's.
@"
PATH=$CargoHome\bin;$pwshDir;C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Program Files\CMake\bin;C:\Program Files\GitHub CLI;C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH
RUSTUP_HOME=$RustupHome
CARGO_HOME=$CargoHome
VCPKG_INSTALLATION_ROOT=$VcpkgRoot
VCPKG_ROOT=$VcpkgRoot
LANG=en_US.UTF-8
"@ | Set-Content -Encoding ascii "$RunnerDir\.env"

if ($RegistrationToken) {
  # To re-register, first run `config.cmd remove --token <removal token>` in the runner directory.
  if (Test-Path "$RunnerDir\.runner") { throw "$RunnerName is already configured; remove it first" }
  Push-Location $RunnerDir
  try {
    & .\config.cmd --unattended --replace --url $Url --token $RegistrationToken --name $RunnerName `
      --labels $Labels --work _work --runasservice `
      --windowslogonaccount '.\ci' --windowslogonpassword $cred.GetNetworkCredential().Password
    if ($LASTEXITCODE) { throw "config.cmd failed: $LASTEXITCODE" }
  } finally { Pop-Location }
} else {
  # .env is only read at start: restart an existing service so edits above take effect.
  $svcName = Get-Content "$RunnerDir\.service" -ErrorAction SilentlyContinue
  if ($svcName) { Restart-Service $svcName }
}

Step 'done'
$svcName = Get-Content "$RunnerDir\.service" -ErrorAction SilentlyContinue
if ($svcName) { Get-Service $svcName | Format-Table -AutoSize Name, Status, StartType }
