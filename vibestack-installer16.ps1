# ==============================================================================
# VIBESTACK INSTALLER v1.5.1
# ==============================================================================
# One-file installer for AI-powered local app development on Windows.
#
# INTERNAL CONTRACTS (read before editing):
#   Port registry keys:    db, api, studio, mail, pooler, analytics, dev
#   Registry path:         C:\VIBESTACK\TOOLS\DATABASE\port-registry.json
#   Registry structure:    { nextBase: N, projects: { "slug": { db:N, api:N, ... } } }
#   Project slug:          lowercase, [^a-z0-9-_] replaced with -, trimmed
#   Folder paths:          C:\VIBESTACK\PROJECTS\<OriginalName>\
#   Dashboard port:        9999
#   Project port blocks:   40 ports each, starting at 55000
#   Status enums:          running, stopped, docker-offline, loading
#   Launcher pattern:      .ps1 has logic, .cmd is double-click wrapper
#   Version variable:      $VibeStackVersion (set once, referenced everywhere)
# ==============================================================================

param([switch]$PatchOnly)

$ErrorActionPreference = "Stop"
$VibeRoot = "C:\VIBESTACK"
$VibeStackVersion = "1.5.1"
$script:CurrentStep = 0
$script:TotalSteps = 12
$ProgressFile = "$VibeRoot\CORE\install-progress.json"

# ==============================================================================
# PROGRESS TRACKING -- resume on rerun after failure or restart
# ==============================================================================

function Get-Progress {
  if (-not (Test-Path $ProgressFile)) {
    return [PSCustomObject]@{
      version = "1.5.1"; startedAt = ""; completedSteps = @(); lastRun = ""
    }
  }
  try {
    $raw = [System.IO.File]::ReadAllText($ProgressFile).TrimStart([char]0xFEFF)
    $p = $raw | ConvertFrom-Json
    if (-not $p.completedSteps) { $p | Add-Member -NotePropertyName completedSteps -NotePropertyValue @() }
    return $p
  } catch {
    return [PSCustomObject]@{ version = "1.2"; startedAt = ""; completedSteps = @(); lastRun = "" }
  }
}

function Test-StepDone($step) {
  $p = Get-Progress
  return ($p.completedSteps -contains $step)
}

function Mark-StepDone($step) {
  Ensure-Dir (Split-Path $ProgressFile)
  $p = Get-Progress
  $existing = @($p.completedSteps)
  if ($existing -notcontains $step) { $existing += $step }
  $updated = [PSCustomObject]@{
    version        = "1.5.1"
    startedAt      = if ($p.startedAt) { $p.startedAt } else { Get-Date -Format "o" }
    completedSteps = $existing
    lastRun        = Get-Date -Format "o"
  }
  $json = $updated | ConvertTo-Json -Depth 3
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($ProgressFile, $json, $utf8NoBom)
}

function Show-SkipStep($label) {
  Write-Host "  [SKIP] $label was already completed." -ForegroundColor DarkGray
  Write-Host "  (Delete C:\VIBESTACK\CORE\install-progress.json to force a full re-run)" -ForegroundColor DarkGray
}

# ==============================================================================
# DISPLAY HELPERS
# ==============================================================================

function Write-Section($text) {
  Write-Host ""
  Write-Host "  ==================================================" -ForegroundColor Cyan
  Write-Host "  $text" -ForegroundColor Cyan
  Write-Host "  ==================================================" -ForegroundColor Cyan
}

function Write-Step($text) {
  $script:CurrentStep++
  Write-Host ""
  Write-Host "  [$($script:CurrentStep)/$($script:TotalSteps)] $text" -ForegroundColor Cyan
  Write-Host "  $("-" * 50)" -ForegroundColor DarkGray
}

function Write-Good($text)    { Write-Host "  [OK]    $text" -ForegroundColor Green }
function Write-WarnMsg($text) { Write-Host "  [WAIT]  $text" -ForegroundColor Yellow }
function Write-Bad($text)     { Write-Host "  [ERROR] $text" -ForegroundColor Red }
function Write-Info($text)    { Write-Host "  [INFO]  $text" -ForegroundColor Cyan }

function Write-CheckRow($label, $status, $detail = "") {
  $pad = 28
  $labelStr = $label.PadRight($pad)
  switch ($status) {
    "OK"      { Write-Host "  [OK]    $labelStr $detail" -ForegroundColor Green }
    "WARN"    { Write-Host "  [WARN]  $labelStr $detail" -ForegroundColor Yellow }
    "MISSING" { Write-Host "  [--]    $labelStr $detail" -ForegroundColor DarkGray }
    "ERROR"   { Write-Host "  [ERR]   $labelStr $detail" -ForegroundColor Red }
  }
}

function Show-RebootRequired($reason) {
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host "  ACTION REQUIRED -- READ THIS CAREFULLY" -ForegroundColor Yellow
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  $reason" -ForegroundColor White
  Write-Host ""
  Write-Host "  WHAT TO DO NEXT:" -ForegroundColor Yellow
  Write-Host "  1. Wait for any installs on screen to finish." -ForegroundColor White
  Write-Host "  2. Restart your computer if a restart was mentioned." -ForegroundColor White
  Write-Host "  3. After restart, open PowerShell as Administrator." -ForegroundColor White
  Write-Host "     Right-click the Start button > Terminal (Admin)" -ForegroundColor DarkGray
  Write-Host "  4. Run these two commands one at a time:" -ForegroundColor White
  Write-Host "     Set-ExecutionPolicy -Scope Process Bypass" -ForegroundColor Cyan
  Write-Host "     `& `"$HOME\Desktop\vibestack-installer.ps1`"" -ForegroundColor Cyan
  Write-Host "  5. The installer will pick up where it left off." -ForegroundColor White
  Write-Host ""
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host "  You can now close this window (click the X)." -ForegroundColor Green
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host ""
  Read-Host "  Or press Enter"
}

# ==============================================================================
# CORE UTILITIES
# ==============================================================================

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  YOU NEED TO RUN THIS AS ADMINISTRATOR." -ForegroundColor Red
    Write-Host ""
    Write-Host "  HOW TO FIX THIS:" -ForegroundColor Yellow
    Write-Host "  1. Close this window." -ForegroundColor White
    Write-Host "  2. Right-click the Start button." -ForegroundColor White
    Write-Host "  3. Click Terminal (Admin) or Windows PowerShell (Admin)." -ForegroundColor White
    Write-Host "  4. Run: Set-ExecutionPolicy -Scope Process Bypass" -ForegroundColor Cyan
    Write-Host "  5. Run: `& `"$HOME\Desktop\vibestack-installer.ps1`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host "  You can now close this window (click the X)." -ForegroundColor Green
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host ""
  Read-Host "  Or press Enter"
    exit 1
  }
}

function Ensure-Dir($path) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Test-CommandExists($name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
  if (-not (Test-CommandExists "winget")) {
    throw "winget is not available. Make sure you are on Windows 10/11 with App Installer from the Microsoft Store."
  }
}

function Refresh-Path {
  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Install-Or-UpgradeWingetPackage {
  param(
    [Parameter(Mandatory=$true)][string]$WingetId,
    [Parameter(Mandatory=$true)][string]$DisplayName,
    [string]$CommandToCheck = ""
  )
  Ensure-Winget
  if ($CommandToCheck -and (Test-CommandExists $CommandToCheck)) {
    Write-Host "  Checking $DisplayName for updates..." -ForegroundColor DarkGray
    $null = winget upgrade --id $WingetId -e --source winget --accept-package-agreements --accept-source-agreements 2>&1
    Write-Good "$DisplayName checked for updates."
    return
  }
  Write-Host "  Installing $DisplayName..." -ForegroundColor White
  winget install --id $WingetId -e --source winget --accept-package-agreements --accept-source-agreements | Out-Host
  Refresh-Path
  Write-Good "$DisplayName installed."
}

# ==============================================================================
# TOOL INSTALLERS
# ==============================================================================

function Ensure-WSLReady {
  # We only need the WSL2 kernel -- Docker Desktop manages its own WSL distro.
  # No Ubuntu, no Linux username/password, no extra terminal windows.
  if (-not (Test-CommandExists "wsl")) {
    throw "WSL command not found. This requires Windows 10 version 2004 or Windows 11."
  }

  $statusOutput = ""
  try { $statusOutput = wsl --status 2>&1 | Out-String } catch { $statusOutput = "" }

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($statusOutput)) {
    Write-WarnMsg "WSL2 kernel needs to be installed. Starting now..."
    Write-Host "  Installing WSL2 kernel only (no Linux distro, no login required)..." -ForegroundColor DarkGray
    wsl --install --no-distribution | Out-Host
    Show-RebootRequired "WSL2 was just installed. Your computer needs to restart to finish. After restart, run the installer again."
    throw "WSL2 install triggered. Rerun after restart."
  }

  Write-Host "  Updating WSL2 kernel..." -ForegroundColor DarkGray
  wsl --update 2>&1 | Out-Null
  Write-Good "WSL2 kernel is ready."
}

function Test-GitHubDesktopInstalled {
  $paths = @(
    "$Env:LocalAppData\GitHubDesktop\GitHubDesktop.exe",
    "$Env:ProgramFiles\GitHub Desktop\GitHubDesktop.exe",
    "$Env:ProgramFiles(x86)\GitHub Desktop\GitHubDesktop.exe"
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $true } }
  return $false
}

function Ensure-GitHubDesktop {
  if (Test-GitHubDesktopInstalled) {
    Write-Host "  Checking GitHub Desktop for updates..." -ForegroundColor DarkGray
    winget upgrade --id GitHub.GitHubDesktop -e --source winget --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    Write-Good "GitHub Desktop is ready."
  } else {
    Write-Host "  Installing GitHub Desktop..." -ForegroundColor White
    winget install --id GitHub.GitHubDesktop -e --source winget --accept-package-agreements --accept-source-agreements | Out-Host
    Write-Good "GitHub Desktop installed."
  }
}

function Ensure-VSCode {
  if (Test-CommandExists "code") {
    Write-Host "  Checking VS Code for updates..." -ForegroundColor DarkGray
    winget upgrade --id Microsoft.VisualStudioCode -e --source winget --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    Write-Good "VS Code is ready."
  } else {
    Write-Host "  Installing VS Code..." -ForegroundColor White
    winget install --id Microsoft.VisualStudioCode -e --source winget --accept-package-agreements --accept-source-agreements | Out-Host
    Refresh-Path
    Write-Good "VS Code installed."
  }
}



function Ensure-Dyad {
  $dyadFound = $false
  # Try where.exe first (finds Dyad regardless of install location)
  try {
    $w = & where.exe dyad 2>$null
    if ($w) { $dyadFound = $true }
  } catch {}
  if (-not $dyadFound) {
    $dyadPaths = @(
      "$Env:LocalAppData\Programs\Dyad\Dyad.exe",
      "$Env:LocalAppData\Dyad\Dyad.exe",
      "$Env:ProgramFiles\Dyad\Dyad.exe"
    )
    foreach ($p in $dyadPaths) { if (Test-Path $p) { $dyadFound = $true; break } }
  }

  if ($dyadFound) { Write-Good "Dyad is installed."; return }

  Write-Host "  Installing Dyad..." -ForegroundColor White
  $ok = $false
  try {
    winget install --id Dyad.Dyad -e --source winget --accept-package-agreements --accept-source-agreements | Out-Host
    $ok = $true
    Write-Good "Dyad installed."
  } catch { $ok = $false }

  if (-not $ok) {
    Write-Host ""
    Write-WarnMsg "Dyad could not be installed automatically."
    Write-Host ""
    Write-Host "  INSTALL DYAD MANUALLY (2 minutes):" -ForegroundColor Yellow
    Write-Host "  1. Open your browser." -ForegroundColor White
    Write-Host "  2. Go to:  https://dyad.sh" -ForegroundColor Cyan
    Write-Host "  3. Click Download and run the installer." -ForegroundColor White
    Write-Host "  4. Come back here when done." -ForegroundColor White
    Write-Host ""
    Read-Host "  Press Enter once Dyad is installed (or Enter to skip)"
  }
}

function Ensure-GitHubAuth {
  if (-not (Test-CommandExists "gh")) {
    Write-WarnMsg "GitHub CLI not found in PATH. Skipping auth check."
    return
  }
  $authOk = $false
  try { gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $authOk = $true } } catch {}

  if (-not $authOk) {
    Write-Host ""
    Write-WarnMsg "GitHub CLI is not logged in yet."
    Write-Host "  You can log in now, or skip it -- GitHub Desktop handles normal push/pull without this." -ForegroundColor DarkGray
    Write-Host ""
    $doLogin = Read-Host "  Log in to GitHub CLI now? (Y/N)"
    if ($doLogin -eq "Y" -or $doLogin -eq "y") { gh auth login }
    else { Write-WarnMsg "Skipped. Run 'gh auth login' later if you need it." }
  } else {
    Write-Good "GitHub CLI login confirmed."
  }
}

function Find-DockerExe {
  $paths = @(
    "$Env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
    "$Env:LocalAppData\Docker\Docker Desktop.exe"
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $p } }
  return $null
}

function Ensure-DockerRunning {
  if (-not (Test-CommandExists "docker")) {
    throw "Docker CLI not found. The Docker Desktop install may need a restart to take effect."
  }

  $dockerOk = $false
  try { docker info 2>&1 | Out-Null; $dockerOk = $true } catch {}

  if (-not $dockerOk) {
    $dExe = Find-DockerExe
    if ($dExe) {
      Write-WarnMsg "Docker Desktop is not running. Launching it automatically..."
      Start-Process $dExe
      Write-Host "  Waiting for Docker to start (up to 90 seconds)..." -ForegroundColor DarkGray
      Write-Host "  If a license or WSL prompt appears on screen, accept it." -ForegroundColor Yellow
      Write-Host ""
      $waited = 0
      while ($waited -lt 90) {
        Start-Sleep -Seconds 5
        $waited += 5
        try { docker info 2>&1 | Out-Null; $dockerOk = $true; break } catch {}
        Write-Host "  Still starting... ($waited s)" -ForegroundColor DarkGray
      }
    }

    if (-not $dockerOk) {
      Write-Host ""
      Write-Host "  ================================================" -ForegroundColor Yellow
      Write-Host "  DOCKER NEEDS A LITTLE HELP" -ForegroundColor Yellow
      Write-Host "  ================================================" -ForegroundColor Yellow
      Write-Host ""
      Write-Host "  Docker Desktop is starting but needs your attention." -ForegroundColor White
      Write-Host "  1. Check your screen for any Docker prompts or agreements." -ForegroundColor White
      Write-Host "  2. Accept any license agreement or WSL integration prompt." -ForegroundColor White
      Write-Host "  3. Wait for the whale icon in your taskbar to stop animating." -ForegroundColor White
      Write-Host ""
      Read-Host "  Press Enter once Docker Desktop is running"

      try { docker info 2>&1 | Out-Null; $dockerOk = $true } catch {}
      if (-not $dockerOk) {
        throw "Docker is still not running. Make sure Docker Desktop is fully started and rerun this installer."
      }
    }
  }
  Write-Good "Docker is running."

  # Set Docker Resource Saver to 60 minutes max
  # This pauses containers after 60 min of inactivity -- good balance of
  # resource saving vs keeping your databases alive during normal work sessions.
  # To adjust: Docker Desktop > Settings > Resources > Resource Saver
  $dockerSettingsPath = "$Env:APPDATA\Docker\settings-store.json"
  $dockerSettingsOld  = "$Env:APPDATA\Docker\settings.json"
  $settingsFile = if (Test-Path $dockerSettingsPath) { $dockerSettingsPath }
                  elseif (Test-Path $dockerSettingsOld) { $dockerSettingsOld }
                  else { $null }

  if ($settingsFile) {
    try {
      $raw = [System.IO.File]::ReadAllText($settingsFile)
      $settings = $raw | ConvertFrom-Json
      $changed = $false

      # Enable Resource Saver but set to 60 minutes (3600 seconds)
      if (-not $settings.PSObject.Properties["pauseContainersOnCpuUsage"]) {
        $settings | Add-Member -NotePropertyName "pauseContainersOnCpuUsage" -NotePropertyValue $true
        $changed = $true
      } elseif ($settings.pauseContainersOnCpuUsage -ne $true) {
        $settings.pauseContainersOnCpuUsage = $true
        $changed = $true
      }

      # Set pause threshold to 60 minutes
      if (-not $settings.PSObject.Properties["cpuPauseThreshold"]) {
        $settings | Add-Member -NotePropertyName "cpuPauseThreshold" -NotePropertyValue 60
        $changed = $true
      } elseif ($settings.cpuPauseThreshold -ne 60) {
        $settings.cpuPauseThreshold = 60
        $changed = $true
      }

      if ($changed) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $newJson = $settings | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($settingsFile, $newJson, $utf8NoBom)
        Write-Good "Docker Resource Saver set to 60 minutes."
      } else {
        Write-Good "Docker Resource Saver already configured."
      }
    } catch {
      Write-WarnMsg "Could not update Docker settings automatically."
    }
  } else {
    Write-WarnMsg "Docker settings file not found."
  }
}

# ==============================================================================
# STEP 1: PRE-FLIGHT SYSTEM CHECK
# ==============================================================================

function Invoke-PreflightCheck {
  Write-Step "SYSTEM PRE-FLIGHT CHECK"

  # Windows version
  $osInfo = Get-CimInstance Win32_OperatingSystem
  $build  = [int]$osInfo.BuildNumber
  $caption = $osInfo.Caption
  if ($build -ge 19041) {
    Write-CheckRow "Windows version" "OK" "$caption (Build $build)"
  } else {
    Write-CheckRow "Windows version" "ERROR" "Build $build -- needs 19041+ (Win10 2004 or Win11)"
    throw "Windows version is too old. Please update Windows before running VIBESTACK."
  }

  # RAM check
  $ramGB = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
  if ($ramGB -ge 8) {
    Write-CheckRow "RAM" "OK" "${ramGB} GB"
  } else {
    Write-CheckRow "RAM" "WARN" "${ramGB} GB -- 8 GB+ recommended for Docker + Supabase"
  }

  # Disk space (C: drive)
  $disk = Get-PSDrive C -ErrorAction SilentlyContinue
  if ($disk) {
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    if ($freeGB -ge 10) {
      Write-CheckRow "Disk space (C:)" "OK" "${freeGB} GB free"
    } elseif ($freeGB -ge 5) {
      Write-CheckRow "Disk space (C:)" "WARN" "${freeGB} GB free -- 10 GB+ recommended (Docker images are large)"
    } else {
      Write-CheckRow "Disk space (C:)" "ERROR" "${freeGB} GB free -- too low, Docker will likely fail"
      throw "Not enough disk space. Free up space on C: and try again."
    }
  }

  # Internet check
  $netOk = $false
  try {
    $r = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $netOk = ($r.StatusCode -eq 200)
  } catch { $netOk = $false }
  if ($netOk) {
    Write-CheckRow "Internet connection" "OK" "Online"
  } else {
    Write-CheckRow "Internet connection" "ERROR" "Cannot reach the internet"
    throw "No internet connection detected. Connect to the internet and try again."
  }

  # Tool inventory -- just informational, installs happen in next step
  Write-Host ""
  Write-Host "  INSTALLED TOOLS:" -ForegroundColor DarkGray
  $s_winget  = if (Test-CommandExists "winget") { "OK" } else { "MISSING" }
  $s_git     = if (Test-CommandExists "git")    { "OK" } else { "MISSING" }
  $s_gitver  = try { (git --version 2>&1) -replace 'git version ','' } catch { "" }
  $s_node    = if (Test-CommandExists "node")   { "OK" } else { "MISSING" }
  $s_nodever = try { node -v 2>&1 } catch { "" }
  $s_gh      = if (Test-CommandExists "gh")     { "OK" } else { "MISSING" }
  $s_ghd     = if (Test-GitHubDesktopInstalled) { "OK" } else { "MISSING" }
  $s_code    = if (Test-CommandExists "code")   { "OK" } else { "MISSING" }
  $s_docker  = if (Test-CommandExists "docker") { "OK" } else { "MISSING" }
  $s_wsl = if ([bool](Get-Command "wsl" -ErrorAction SilentlyContinue)) { "OK" } else { "MISSING" }
  $dyadFound2 = $false
  foreach ($dp2 in @("$Env:LocalAppData\Programs\Dyad\Dyad.exe","$Env:LocalAppData\Dyad\Dyad.exe","$Env:ProgramFiles\Dyad\Dyad.exe")) {
    if (Test-Path $dp2) { $dyadFound2 = $true; break }
  }
  $s_dyad = if ($dyadFound2) { "OK" } else { "MISSING" }
  Write-CheckRow "winget"         $s_winget  ""
  Write-CheckRow "Git"            $s_git     $s_gitver
  Write-CheckRow "Node.js"        $s_node    $s_nodever
  Write-CheckRow "GitHub CLI"     $s_gh      ""
  Write-CheckRow "GitHub Desktop" $s_ghd     ""
  Write-CheckRow "VS Code"        $s_code    ""
  Write-CheckRow "Docker"         $s_docker  ""
  Write-CheckRow "WSL2"           $s_wsl     ""
  Write-CheckRow "Dyad"           $s_dyad    ""

  Write-Host ""
  Write-Good "Pre-flight check passed. Continuing install."

  # Reserve port 9999 for dashboard (Hyper-V/Docker can steal it)
  try {
    $excluded = netsh interface ipv4 show excludedportrange protocol=tcp 2>&1 | Out-String
    if ($excluded -match "9999") {
      Write-Info "Port 9999 is in a Hyper-V excluded range. Fixing..."
      net stop winnat 2>&1 | Out-Null
      netsh int ipv4 add excludedportrange protocol=tcp startport=9999 numberofports=1 2>&1 | Out-Null
      net start winnat 2>&1 | Out-Null
      Write-Good "Port 9999 reserved for VIBESTACK Dashboard."
    }
  } catch {
    Write-WarnMsg "Could not check port reservation. Dashboard may need a restart if port 9999 is blocked."
  }

  Mark-StepDone "PREFLIGHT"
}

# ==============================================================================
# STEP 2: CORE TOOL INSTALLS
# ==============================================================================

function Ensure-CoreInstalls {
  Write-Step "INSTALLING CORE TOOLS"
  Write-Host "  Installing anything missing. Already-installed tools get updated." -ForegroundColor DarkGray
  Write-Host ""

  # Refresh winget sources first to avoid stale package errors
  Write-Host "  Refreshing winget sources..." -ForegroundColor DarkGray
  try { winget source update 2>&1 | Out-Null } catch {}

  Ensure-WSLReady
  Install-Or-UpgradeWingetPackage -WingetId "Git.Git"            -DisplayName "Git"           -CommandToCheck "git"
  # Prevent "dubious ownership" errors when installer runs as Admin but IDE runs as user
  try { git config --global --add safe.directory '*' 2>&1 | Out-Null; Write-Good "Git safe.directory configured." } catch {}
  Install-Or-UpgradeWingetPackage -WingetId "OpenJS.NodeJS.LTS"  -DisplayName "Node.js LTS"   -CommandToCheck "node"
  Install-Or-UpgradeWingetPackage -WingetId "GitHub.cli"         -DisplayName "GitHub CLI"    -CommandToCheck "gh"
  Ensure-GitHubDesktop
  Ensure-VSCode
  Ensure-Dyad
  Install-Or-UpgradeWingetPackage -WingetId "Docker.DockerDesktop" -DisplayName "Docker Desktop" -CommandToCheck "docker"
  Ensure-GitHubAuth
  Ensure-DockerRunning

  Write-Host ""
  Write-Host "  Confirmed versions:" -ForegroundColor DarkGray
  try { $nv = node -v 2>&1; Write-Good "Node.js $nv" } catch { Write-WarnMsg "node not yet in PATH -- restart terminal after install" }
  try { $npmv = npm -v 2>&1; Write-Good "npm $npmv" } catch {}
  try { $gv = git --version 2>&1; Write-Good "$gv" } catch {}

  Write-Good "All core tools are ready."
  Mark-StepDone "CORE_INSTALLS"
}

# ==============================================================================
# STEP 3: BUILD VIBESTACK FOLDER STRUCTURE
# ==============================================================================

function Build-VibeStackStructure {
  Write-Step "BUILDING VIBESTACK FOLDER STRUCTURE"

  if (Test-StepDone "VIBESTACK_STRUCTURE") {
    Show-SkipStep "VIBESTACK folder structure"
    # Still ensure Athena is updated even on skip
    if (Test-Path "$VibeRoot\TOOLS\Athena-Public\.git") {
      Write-Host "  Updating Athena-Public..." -ForegroundColor DarkGray
      git -C "$VibeRoot\TOOLS\Athena-Public" pull 2>&1 | Out-Null
    }
    return
  }

  $folders = @(
    "$VibeRoot",
    "$VibeRoot\CORE",
    "$VibeRoot\PROJECTS",
    "$VibeRoot\TOOLS",
    "$VibeRoot\TOOLS\DATABASE",
    "$VibeRoot\TOOLS\Athena-Public",
    "$VibeRoot\TOOLS\ui-kit",
    "$VibeRoot\TOOLS\ui-kit\components",
    "$VibeRoot\TOOLS\ui-kit\styles",
    "$VibeRoot\TOOLS\ui-kit\patterns",
    "$VibeRoot\TOOLS\layout-kit",
    "$VibeRoot\TOOLS\layout-kit\dashboard-layout",
    "$VibeRoot\TOOLS\layout-kit\auth-layout",
    "$VibeRoot\TOOLS\layout-kit\admin-layout",
    "$VibeRoot\TOOLS\auth-kit",
    "$VibeRoot\TOOLS\auth-kit\patterns",
    "$VibeRoot\TOOLS\data-kit",
    "$VibeRoot\TOOLS\data-kit\patterns",
    "$VibeRoot\TOOLS\utils",
    "$VibeRoot\TOOLS\utils\patterns",
    "$VibeRoot\logs",
    "$VibeRoot\DASHBOARD",
    "$VibeRoot\DASHBOARD\public"
  )
  foreach ($folder in $folders) { Ensure-Dir $folder }

  $portRegistryPath = Join-Path $VibeRoot "TOOLS\DATABASE\port-registry.json"
  if (-not (Test-Path $portRegistryPath)) {
    Write-Utf8NoBom -Path $portRegistryPath -Content '{"nextBase":55000,"projects":{}}'
  }

  $sharedFiles = @{
    "$VibeRoot\TOOLS\ui-kit\README.md"      = "# ui-kit`n`nShared UI rules and styling patterns.`n`n- Dark mode first.`n- Brutalist / clean utility-first.`n- App-local dependencies only.`n"
    "$VibeRoot\TOOLS\layout-kit\README.md"  = "# layout-kit`n`nShared layout patterns.`n`n- dashboard-layout for signed-in experiences`n- auth-layout for login/signup`n- admin-layout for management tools`n"
    "$VibeRoot\TOOLS\auth-kit\README.md"    = "# auth-kit`n`nSupabase auth guidance.`n`n- email/password baseline`n- role-based route protection`n- owner/admin checks`n"
    "$VibeRoot\TOOLS\data-kit\README.md"    = "# data-kit`n`nData access and CRUD guidance.`n`n- stable table naming`n- migration-first schema changes`n- admin CRUD scaffolds`n"
    "$VibeRoot\TOOLS\utils\README.md"       = "# utils`n`nShared utility guidance.`n`n- cn helper`n- environment loading`n- date formatting`n"
    "$VibeRoot\TOOLS\ui-kit\styles\design-tokens.md" = "# Design tokens`n`n- Background: near-black`n- Foreground: zinc-100`n- Accent: cyan`n- Borders: zinc-800/zinc-900`n- Radius: xl/2xl`n"
  }
  foreach ($path in $sharedFiles.Keys) {
    if (-not (Test-Path $path)) { Write-Utf8NoBom -Path $path -Content $sharedFiles[$path] }
  }

  if (Test-Path "$VibeRoot\TOOLS\Athena-Public\.git") {
    Write-Host "  Updating Athena-Public..." -ForegroundColor DarkGray
    try {
      git -C "$VibeRoot\TOOLS\Athena-Public" pull 2>&1 | Out-Null
      Write-Good "Athena-Public updated."
    } catch {
      Write-WarnMsg "Athena-Public update skipped (network or auth issue). Continuing."
    }
  } else {
    $athenaDir = "$VibeRoot\TOOLS\Athena-Public"
    $hasFiles = (Get-ChildItem $athenaDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
    if (-not $hasFiles) {
      Write-Host "  Cloning Athena-Public memory repo..." -ForegroundColor DarkGray
      git clone https://github.com/winstonkoh87/Athena-Public "$VibeRoot\TOOLS\Athena-Public" | Out-Host
    } else {
      Write-WarnMsg "Athena-Public folder exists and is not empty. Skipping clone."
    }
  }
  Ensure-Dir "$VibeRoot\TOOLS\Athena-Public\PROJECTS"

  Write-Good "VIBESTACK folder structure created at $VibeRoot"

  # Grant the current (non-admin) user full control of VIBESTACK
  # The installer runs as Admin, but IDEs like Dyad run as the regular user.
  # Without this, pnpm/npm in Dyad gets EPERM on admin-owned folders.
  $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  try {
    Write-Info "Setting folder permissions for $currentUser..."
    icacls "$VibeRoot" /grant "${currentUser}:(OI)(CI)F" /T /Q 2>&1 | Out-Null
    Write-Good "Folder permissions set."
  } catch {
    Write-WarnMsg "Could not set folder permissions. IDEs may have trouble writing files."
  }

  Mark-StepDone "VIBESTACK_STRUCTURE"
}

# ==============================================================================
# STEP 4: WRITE CREATE-PROJECT.JS
# ==============================================================================

function Write-CreateProjectScript {
  Write-Step "WRITING PROJECT GENERATOR"

  $createProjectScript = @'
"use strict"
const fs   = require("fs")
const path = require("path")
const readline = require("readline")
const { execSync } = require("child_process")

const shell = process.env.ComSpec || "cmd.exe"
const ROOT                = path.resolve(__dirname, "..")
const PROJECTS_DIR        = path.join(ROOT, "PROJECTS")
const TOOLS_DIR           = path.join(ROOT, "TOOLS")
const DATABASE_DIR        = path.join(TOOLS_DIR, "DATABASE")
const PORT_REGISTRY_PATH  = path.join(DATABASE_DIR, "port-registry.json")
const ATHENA_PATH         = path.join(TOOLS_DIR, "Athena-Public")
const ATHENA_PROJECTS_PATH= path.join(ATHENA_PATH, "PROJECTS")
const UI_KIT_PATH         = path.join(TOOLS_DIR, "ui-kit")
const LAYOUT_KIT_PATH     = path.join(TOOLS_DIR, "layout-kit")
const AUTH_KIT_PATH       = path.join(TOOLS_DIR, "auth-kit")
const DATA_KIT_PATH       = path.join(TOOLS_DIR, "data-kit")
const UTILS_PATH          = path.join(TOOLS_DIR, "utils")

const rawProjectName = process.argv[2]
if (!rawProjectName) {
  console.error("Usage: node create-project.js PROJECT_NAME")
  process.exit(1)
}

// -- Utilities ----------------------------------------------------------------

function slugify(name) {
  return name.trim().toLowerCase().replace(/[^a-z0-9-_]+/g,"-").replace(/^-+|-+$/g,"")
}
function ensureDir(p) { fs.mkdirSync(p,{recursive:true}) }
function stripBom(t) { return t ? t.replace(/^\uFEFF/,"") : t }
function safeReadJson(p,fallback) {
  try { const r=stripBom(fs.readFileSync(p,"utf8")).trim(); if(!r) return fallback; return JSON.parse(r) }
  catch { return fallback }
}
function writeProjectFile(projectDir,rel,content) {
  const full=path.join(projectDir,rel)
  ensureDir(path.dirname(full))
  fs.writeFileSync(full,content,"utf8")
}
function run(cmd,cwd,stdio="inherit") {
  return execSync(cmd,{cwd,stdio,shell,encoding:stdio==="pipe"?"utf8":undefined,env:process.env})
}
function tryRun(cmd,cwd) { try{run(cmd,cwd);return true}catch{return false} }
function escBt(v) { return v.replace(/`/g,"\\`") }
function box(lines,color="\x1b[36m") {
  const R="\x1b[0m"
  console.log("")
  console.log(color+"  "+"=".repeat(52)+R)
  for(const l of lines) console.log(color+"  "+l+R)
  console.log(color+"  "+"=".repeat(52)+R)
  console.log("")
}

// -- Port registry -------------------------------------------------------------

function loadRegistry() {
  ensureDir(DATABASE_DIR)
  if (!fs.existsSync(PORT_REGISTRY_PATH))
    fs.writeFileSync(PORT_REGISTRY_PATH,JSON.stringify({nextBase:55000,projects:{}},null,2),"utf8")
  const reg=safeReadJson(PORT_REGISTRY_PATH,{nextBase:55000,projects:{}})
  if(!reg.projects||typeof reg.projects!=="object") reg.projects={}
  if(!reg.nextBase||isNaN(Number(reg.nextBase))) reg.nextBase=55000
  return reg
}
function saveRegistry(reg) {
  fs.writeFileSync(PORT_REGISTRY_PATH,JSON.stringify(reg,null,2),"utf8")
}
function allocatePorts(key) {
  const reg=loadRegistry()
  if(reg.projects[key]) return reg.projects[key]

  // Find a base that isn't already used by any registered project
  let base=Number(reg.nextBase||55000)
  const usedBases=Object.values(reg.projects).map(p=>Number(p.db))
  while(usedBases.includes(base)){
    base+=40
    console.log("Port "+base+" already registered, skipping to "+base+"...")
  }

  const ports={db:base,api:base-1,studio:base+1,mail:base+2,pooler:base+3,analytics:base+4,dev:base+10}
  reg.projects[key]=ports
  reg.nextBase=base+40
  saveRegistry(reg)
  return ports
}

// -- Docker check --------------------------------------------------------------

function ensureDockerRunning() {
  try { execSync("docker info",{cwd:ROOT,shell,stdio:"ignore",env:process.env}) }
  catch {
    console.error("\n  [ERROR] Docker is not running.")
    console.error("  Open Docker Desktop, wait until the whale icon stops animating, then try again.\n")
    process.exit(1)
  }
}

// -- Prompt wizard -------------------------------------------------------------

async function openPromptEditor(projectDir, projectName) {
  const promptPath = path.join(projectDir, "PROMPT.md")
  const shell = process.env.ComSpec || "cmd.exe"

  // Template with clear DELETE-ME instructions at the top
  const template = [
    "====================================================",
    "  INSTRUCTIONS - DELETE THIS ENTIRE BLOCK WHEN DONE",
    "====================================================",
    "Notepad just opened this file for you.",
    "",
    "WHAT TO DO:",
    "  1. Press Ctrl+A to select all this text",
    "  2. Press Delete to clear it",
    "  3. Paste or type your full app idea",
    "     (one sentence, bullets, or a full spec - anything works)",
    "  4. Press Ctrl+S to save",
    "  5. Close Notepad",
    "  6. Come back to the terminal and press Enter",
    "====================================================",
    "",
    "",
    "# " + projectName + " - App Idea",
    "",
    "[REPLACE THIS WITH YOUR APP IDEA]",
    "",
    "Describe what your app does, who uses it, and what the",
    "main features are. You can paste a full spec here.",
    "Your AI will read everything in this file before building.",
    "",
  ].join("\n")

  fs.writeFileSync(promptPath, template, "utf8")

  console.log("")
  console.log("\x1b[36m  ====================================================\x1b[0m")
  console.log("\x1b[36m  OPENING NOTEPAD FOR YOUR APP IDEA\x1b[0m")
  console.log("\x1b[36m  ====================================================\x1b[0m")
  console.log("")
  console.log("  Notepad is about to open. Here is what to do:")
  console.log("  1. Press Ctrl+A to select all the placeholder text")
  console.log("  2. Press Delete to clear it")
  console.log("  3. Paste or type your full app idea")
  console.log("     (one sentence, bullets, or a full spec - anything works)")
  console.log("  4. Press Ctrl+S to save")
  console.log("  5. Close Notepad - setup will continue automatically")
  console.log("")
  console.log("  TIP: You can paste an entire ChatGPT or Claude spec.")
  console.log("  No length limit. Paste as much as you want.")
  console.log("")
  console.log("  Waiting for you to close Notepad...")
  console.log("")

  // execSync blocks until Notepad is closed - no Enter prompt needed
  try {
    execSync(`notepad "${promptPath}"`, { shell, stdio: "ignore", env: process.env })
  } catch {}

  console.log("  Notepad closed. Continuing setup...")
  console.log("")

  const saved = fs.readFileSync(promptPath, "utf8")
  if (saved.includes("INSTRUCTIONS") || saved.includes("[REPLACE THIS WITH YOUR APP IDEA]")) {
    console.log("\x1b[33m  [WARN] PROMPT.md still has placeholder text.\x1b[0m")
    console.log("  No problem - edit it before opening in Dyad or VS Code.")
    console.log("  File: " + promptPath)
  } else {
    console.log("  \x1b[32m[OK]\x1b[0m PROMPT.md saved with your app idea.")
  }
}


// -- Main ----------------------------------------------------------------------

async function main() {
  const packageName = slugify(rawProjectName)
  const projectName = rawProjectName.trim()
  const projectDir  = path.join(PROJECTS_DIR,projectName)

  if (!packageName) {
    console.error("  Project name is invalid. Use letters, numbers, and dashes only.")
    process.exit(1)
  }
  if (fs.existsSync(projectDir)) {
    console.error(`  Project already exists: ${projectDir}`)
    process.exit(1)
  }

  ensureDockerRunning()

  const ports=allocatePorts(packageName)

  console.log("")
  console.log("\x1b[36m  Creating project: "+projectName+"\x1b[0m")
  console.log("  Location: "+projectDir)
  console.log("  Ports -- DB:"+ports.db+"  API:"+ports.api+"  Studio:"+ports.studio+"  App:"+ports.dev)
  console.log("")

  // Create project folder first so we can open PROMPT.md in an editor
  ensureDir(projectDir)
  ensureDir(path.join(projectDir,"ATHENA_EXPORT"))

  // Open PROMPT.md for the user to fill in -- handles any size input, no terminal paste issues
  await openPromptEditor(projectDir, projectName)

  // Folders (rest of them)
  ensureDir(path.join(projectDir,"app"))
  ensureDir(path.join(projectDir,"components","ui"))
  ensureDir(path.join(projectDir,"lib","supabase"))
  ensureDir(path.join(projectDir,"scripts"))
  ensureDir(path.join(projectDir,"public"))


  // package.json -- pinned versions
  const pkg={
    name:packageName,version:"1.0.0",private:true,
    scripts:{
      dev:"node scripts/dev-startup.js && next dev -p "+ports.dev,
      "dev:web":"next dev -p "+ports.dev,
      build:"next build",start:"next start",
      "db:start":"node scripts/db-start.js",
      "db:stop":"npx supabase stop",
      "db:status":"npx supabase status",
      "db:reset":"npx supabase db reset",
      "athena:sync":"node scripts/sync-athena.js"
    },
    dependencies:{
      "@hookform/resolvers":"^3.10.0",
      "@supabase/supabase-js":"^2.57.4",
      "class-variance-authority":"^0.7.1",
      "clsx":"^2.1.1",
      "framer-motion":"^12.23.24",
      "lucide-react":"^0.542.0",
      "next":"^15.1.0",
      "react":"^19.0.0",
      "react-dom":"^19.0.0",
      "recharts":"^3.1.2",
      "react-hook-form":"^7.62.0",
      "tailwind-merge":"^3.3.1",
      "zod":"^4.1.5"
    },
    devDependencies:{
      "autoprefixer":"^10.4.20",
      "chokidar":"^4.0.3",
      "postcss":"^8.4.49",
      "supabase":"^2.58.0",
      "tailwindcss":"^3.4.17"
    }
  }
  writeProjectFile(projectDir,"package.json",JSON.stringify(pkg,null,2))

  // .npmrc -- ensures pnpm uses flat hoisted layout (matches npm).
  // Critical for Dyad which uses pnpm. npm prints a harmless warning.
  writeProjectFile(projectDir,".npmrc",
`shamefully-hoist=true
`)

  writeProjectFile(projectDir,"jsconfig.json",JSON.stringify({
    compilerOptions:{baseUrl:".",paths:{"@/*":["./*"]}}
  },null,2))

  writeProjectFile(projectDir,"next.config.mjs",
`/** @type {import('next').NextConfig} */
const nextConfig = {}
export default nextConfig
`)

  writeProjectFile(projectDir,"postcss.config.mjs",
`export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
`)

  writeProjectFile(projectDir,"tailwind.config.js",
`/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './lib/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        background: '#000000',
        foreground: '#f4f4f5',
        cyan: {
          400: '#00e5cc',
          500: '#00b8a3',
        },
      },
    },
  },
  plugins: [],
}
`)

  writeProjectFile(projectDir,".gitignore",
`node_modules
.next
.env.local
.env
dist
.DS_Store
npm-debug.log*
`)

  const envBase=
`NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:${ports.api}
NEXT_PUBLIC_SUPABASE_ANON_KEY=REPLACED_ON_FIRST_DB_START
SUPABASE_SERVICE_ROLE_KEY=REPLACED_ON_FIRST_DB_START
SUPABASE_DB_URL=postgresql://postgres:postgres@127.0.0.1:${ports.db}/postgres
SUPABASE_JWT_SECRET=REPLACED_ON_FIRST_DB_START
SUPABASE_DB_PORT=${ports.db}
SUPABASE_API_PORT=${ports.api}
SUPABASE_STUDIO_PORT=${ports.studio}
SUPABASE_MAIL_PORT=${ports.mail}
SUPABASE_ANALYTICS_PORT=${ports.analytics}
DEV_PORT=${ports.dev}
ATHENA_PATH=${ATHENA_PATH}
ATHENA_PROJECTS_PATH=${ATHENA_PROJECTS_PATH}
UI_KIT_PATH=${UI_KIT_PATH}
LAYOUT_KIT_PATH=${LAYOUT_KIT_PATH}
AUTH_KIT_PATH=${AUTH_KIT_PATH}
DATA_KIT_PATH=${DATA_KIT_PATH}
UTILS_PATH=${UTILS_PATH}
`
  writeProjectFile(projectDir,".env.example",envBase)
  writeProjectFile(projectDir,".env.local",envBase)

  writeProjectFile(projectDir,"README.md",
`# ${projectName}

Generated by VIBESTACK.

## Quick start

Double-click **START-APP.cmd** in this folder.

Or from terminal:
\`\`\`powershell
npm run dev
\`\`\`

## Available commands

| Command | What it does |
|---|---|
| \`npm run dev\` | Start the app + database |
| \`npm run db:start\` | Start database only |
| \`npm run db:stop\` | Stop database |
| \`npm run db:reset\` | Reset database (deletes all data) |
| \`npm run db:status\` | Check database status |
| \`npm run athena:sync\` | Sync memory to shared Athena repo |
| \`npm run build\` | Build for production |

## Local ports (reserved for this project)

- App:    http://localhost:${ports.dev}
- DB:     ${ports.db}
- API:    ${ports.api}
- Studio: ${ports.studio}
- Mail:   ${ports.mail}

## Double-click launchers

- **START-APP.cmd** -- start the dev server
- **STOP-DB.cmd** -- stop the database
- **RESET-DB.cmd** -- reset the database (with confirmation)
- **OPEN-STUDIO.cmd** -- open Supabase Studio in your browser

## AI workflow

1. Open this folder in Dyad or VS Code
2. Give your AI this first prompt:
   > Read PROMPT.md and AI_RULES.md completely. Build the master plan.
   > Write it to ATHENA_EXPORT/MASTERPLAN.md. Update PROGRESS.md,
   > NEXT_STEPS.md, and DECISIONS.md. Then begin implementation.
3. After milestones, sync Athena: \`npm run athena:sync\`
`)

  writeProjectFile(projectDir,"AI_RULES.md",
`# AI_RULES.md

## Purpose
This is a generated VIBESTACK app. Read this file before making any changes.

## Reading order
1. Read PROMPT.md first -- it describes the product.
2. Read this AI_RULES.md second -- it defines the rules.
3. Respect the architecture already in place.
4. Preserve local Supabase support.
5. Preserve Athena memory workflow.

## Tech stack
- Next.js App Router (^15.1.0)
- React (^19.0.0)
- Tailwind CSS v3 (stable, no native module deps)
- Supabase local development with Docker
- Shared VIBESTACK kits (reference only, not shared node_modules)
- Athena memory (local export + sync model)

## Database keep-alive
The local Supabase database runs in Docker. If Docker Desktop pauses containers
(Resource Saver mode), the database stops responding and the AI cannot write data.
VIBESTACK disables Docker Resource Saver automatically during install.
If containers pause anyway, the user should run 'START-APP.cmd' which restarts
the database. Do NOT loop endlessly if database calls fail - stop and report
the connection error so the user knows to restart the database.

## How the dev environment works -- READ THIS CAREFULLY
Running 'npm run dev' starts TWO processes simultaneously:
1. The Next.js dev server (localhost:${ports.dev})
2. The migration watcher (scripts/migration-watcher.js)

THE MIGRATION WATCHER IS CRITICAL:
- It watches supabase/migrations/ for any .sql file changes
- The moment you save a new or modified migration file, it automatically runs 'supabase migration up'
- You NEVER need to tell the user to run 'npx supabase migration up' manually
- You NEVER need to tell the user to run 'npx supabase db push' manually
- Just write the migration file and save it. The watcher handles the rest.

NEVER ask the user to run terminal commands manually.
NEVER tell the user to run 'npx supabase db push'.
NEVER tell the user to run 'npx supabase migration up'.
NEVER tell the user to run 'npm install'.
NEVER tell the user to run 'supabase start' or 'supabase stop'.
If something needs to happen in the database, write a migration file.
The watcher will apply it automatically within a few seconds.

Available npm scripts (for reference only -- do not ask user to run these):
- 'npm run dev' -- starts everything (already running if user is talking to you)
- 'npm run db:start' -- starts the database only
- 'npm run db:status' -- checks database status
- 'npm run athena:sync' -- syncs memory to shared repo

## Shared tool locations
- Athena:         ${ATHENA_PATH}
- Athena projects:${ATHENA_PROJECTS_PATH}
- ui-kit:         ${UI_KIT_PATH}
- layout-kit:     ${LAYOUT_KIT_PATH}
- auth-kit:       ${AUTH_KIT_PATH}
- data-kit:       ${DATA_KIT_PATH}
- utils:          ${UTILS_PATH}

## Local ports for this project
- App:    http://localhost:${ports.dev}
- DB:     ${ports.db}
- API:    ${ports.api}
- Studio: ${ports.studio}
- Mail:   ${ports.mail}

## Athena memory rules
- Do NOT write outside this project workspace.
- Write Athena files inside ATHENA_EXPORT/ only:
  - ATHENA_EXPORT/MASTERPLAN.md
  - ATHENA_EXPORT/PROGRESS.md
  - ATHENA_EXPORT/NEXT_STEPS.md
  - ATHENA_EXPORT/DECISIONS.md
- Update them after: master plan changes, feature rollouts, schema changes, milestones.

## Non-negotiable rules
- All schema changes go through supabase/migrations.
- Keep auth centered on Supabase.
- Extend existing files -- do not replace the project structure.
- Do not remove Next.js App Router.
- Do not switch away from Tailwind v3.
- Keep route names stable and human-readable.
- Do not hardcode production secrets.
- Use .env.local for all local-only runtime values.

## TAILWIND v3 -- READ THIS CAREFULLY
This project uses Tailwind CSS v3 with the standard postcss plugin.
The ONLY valid way to import Tailwind in globals.css is:
  @tailwind base;
  @tailwind components;
  @tailwind utilities;

DO NOT use Tailwind v4 syntax (it WILL break the build):
  @import "tailwindcss";              <- WRONG (v4 syntax)
  @import "tailwindcss/base";         <- WRONG
  @import "tailwindcss/components";   <- WRONG

The tailwind.config.js file controls which paths Tailwind scans.
If you create a new top-level folder for components, add it to the
content array in tailwind.config.js.

If you see a CSS error mentioning "mini-css-extract-plugin", it means
globals.css has Tailwind v4 syntax. Fix it by replacing the @import line
with the three @tailwind directives shown above.

## ABSOLUTE HARD STOPS -- never do these under any circumstances
- NEVER overwrite or modify an existing migration file (e.g. 0001_initial_schema.sql).
  Supabase tracks which migrations have been applied by filename.
  If you change a file that was already applied, the changes are SILENTLY IGNORED.
  ALWAYS create a NEW migration file with the next number (0002, 0003, etc.).
  Example: supabase/migrations/0002_add_posts_table.sql
- NEVER switch to yarn or bun. This project works with npm and pnpm (Dyad uses pnpm).
  If you need to install a package, use: npm install <package>
- NEVER modify postcss.config.mjs. It is correct. Do not touch it.
- NEVER modify tailwind.config.js structure (only add to content array if needed).
- NEVER modify next.config.mjs unless explicitly asked.
- NEVER delete or modify .npmrc. It is required for pnpm compatibility.
- NEVER upgrade Tailwind to v4. v3 is intentional and stable.
- NEVER upgrade or downgrade Next.js or React versions.
- NEVER delete or regenerate package-lock.json or pnpm-lock.yaml.
- NEVER generate more than 5 new files in a single pass.
  Build incrementally: schema first, one route, test, then continue.
  Generating 20+ files at once creates cascading failures that are impossible to debug.
- If you see a CSS or PostCSS error, DO NOT change postcss.config.mjs.
  Check globals.css for v4 syntax instead.

## First prompt (PLANNING ONLY -- no code yet)
Read PROMPT.md and AI_RULES.md completely. Do NOT write any application code yet.
Your only job right now is PLANNING:
1. Write the master implementation plan to ATHENA_EXPORT/MASTERPLAN.md
2. Break it into small phases (3-5 files per phase max)
3. Update ATHENA_EXPORT/PROGRESS.md, NEXT_STEPS.md, and DECISIONS.md
4. List Phase 1 scope clearly
Do NOT touch any files in app/, components/, or lib/. Planning only.

## Second prompt (begin Phase 1)
After the plan is written and reviewed, say:
"Begin Phase 1 from ATHENA_EXPORT/MASTERPLAN.md. Build only Phase 1. Max 5 files."

## Incremental build rule
NEVER generate more than 5 files in a single pass.
After each pass: stop, let the developer test, then continue.
This prevents cascading failures that are impossible to debug.
`)

  // Athena stubs
  writeProjectFile(projectDir,"ATHENA_EXPORT/MASTERPLAN.md","# MASTERPLAN\n\nHave your AI create and maintain the master implementation plan here.\n")
  writeProjectFile(projectDir,"ATHENA_EXPORT/PROGRESS.md","# PROGRESS\n\nTrack completed work and milestone updates here.\n")
  writeProjectFile(projectDir,"ATHENA_EXPORT/NEXT_STEPS.md","# NEXT STEPS\n\nTrack immediate next actions here.\n")
  writeProjectFile(projectDir,"ATHENA_EXPORT/DECISIONS.md","# DECISIONS\n\nTrack architecture decisions and tradeoffs here.\n")

  // lib
  writeProjectFile(projectDir,"lib/utils.js",
`import { clsx } from "clsx"
import { twMerge } from "tailwind-merge"
export function cn(...inputs) { return twMerge(clsx(inputs)) }
`)
  writeProjectFile(projectDir,"lib/athena.js",
`export const athena = {
  root: process.env.ATHENA_PATH || "",
  projectRoot: process.env.ATHENA_PROJECTS_PATH || "",
  exportFolder: "ATHENA_EXPORT",
  notes: "Write to ATHENA_EXPORT/ locally, then sync to shared Athena repo."
}
`)
  writeProjectFile(projectDir,"lib/supabase/client.js",
`"use client"
import { createClient } from "@supabase/supabase-js"
let browserClient = null
export function getSupabaseBrowserClient() {
  if (browserClient) return browserClient
  try {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL
    const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
    if (!url || !anon || anon === "REPLACED_ON_FIRST_DB_START") return null
    browserClient = createClient(url, anon)
    return browserClient
  } catch (e) {
    console.warn("Supabase client init skipped:", e.message)
    return null
  }
}
`)

  // UI components
  writeProjectFile(projectDir,"components/ui/button.jsx",
`import { cva } from "class-variance-authority"
import { cn } from "@/lib/utils"
const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-xl border text-sm font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-400 disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        default:"border-cyan-400 bg-cyan-400 text-black hover:bg-cyan-300",
        outline:"border-zinc-700 bg-zinc-950 text-zinc-100 hover:bg-zinc-900",
        ghost:"border-transparent bg-transparent text-zinc-100 hover:bg-zinc-900"
      },
      size: { default:"h-10 px-4 py-2", sm:"h-9 px-3", lg:"h-11 px-6" }
    },
    defaultVariants:{ variant:"default", size:"default" }
  }
)
export function Button({ className, variant, size, ...props }) {
  return <button className={cn(buttonVariants({variant,size}),className)} {...props} />
}
`)

  writeProjectFile(projectDir,"components/ui/card.jsx",
`import { cn } from "@/lib/utils"
export function Card({ className,...props }) {
  return <div className={cn("rounded-2xl border border-zinc-800 bg-zinc-950/80",className)} {...props} />
}
export function CardHeader({ className,...props }) {
  return <div className={cn("p-6 pb-2",className)} {...props} />
}
export function CardTitle({ className,...props }) {
  return <h3 className={cn("text-lg font-semibold text-zinc-50",className)} {...props} />
}
export function CardDescription({ className,...props }) {
  return <p className={cn("text-sm text-zinc-400",className)} {...props} />
}
export function CardContent({ className,...props }) {
  return <div className={cn("p-6 pt-2",className)} {...props} />
}
`)

  writeProjectFile(projectDir,"components/app-shell.jsx",
`import Link from "next/link"
import { Home, LogIn, UserPlus, LayoutDashboard, UserCircle2, Shield } from "lucide-react"
const links=[
  {href:"/",label:"Home",icon:Home},
  {href:"/login",label:"Login",icon:LogIn},
  {href:"/signup",label:"Signup",icon:UserPlus},
  {href:"/dashboard",label:"Dashboard",icon:LayoutDashboard},
  {href:"/profile",label:"Profile",icon:UserCircle2},
  {href:"/admin",label:"Admin",icon:Shield},
]
export function AppShell({title,description,children}) {
  return (
    <div className="min-h-screen bg-black text-zinc-100">
      <div className="mx-auto grid min-h-screen max-w-7xl grid-cols-1 md:grid-cols-[260px_minmax(0,1fr)]">
        <aside className="border-b border-zinc-900 bg-zinc-950 p-6 md:border-b-0 md:border-r">
          <div className="mb-8">
            <div className="text-xs uppercase tracking-[0.25em] text-cyan-400">VIBESTACK</div>
            <div className="mt-2 text-xl font-semibold">{title}</div>
            <p className="mt-2 text-sm text-zinc-400">{description}</p>
          </div>
          <nav className="space-y-2">
            {links.map(item=>{
              const Icon=item.icon
              return (
                <Link key={item.href} href={item.href}
                  className="flex items-center gap-3 rounded-xl border border-zinc-900 px-3 py-2 text-sm text-zinc-300 transition hover:border-cyan-500/40 hover:bg-zinc-900 hover:text-white">
                  <Icon className="h-4 w-4"/>
                  <span>{item.label}</span>
                </Link>
              )
            })}
          </nav>
        </aside>
        <main className="p-6 md:p-10">{children}</main>
      </div>
    </div>
  )
}
`)

  writeProjectFile(projectDir,"app/globals.css",
`@tailwind base;
@tailwind components;
@tailwind utilities;

:root { color-scheme: dark; }
html, body { min-height: 100%; margin: 0; padding: 0; }
body { background: #000; color: #f4f4f5; font-family: Arial, Helvetica, sans-serif; }

/* Fallback styles in case Tailwind fails to load */
.vs-fallback { padding: 40px; max-width: 800px; margin: 0 auto; }
.vs-fallback h1 { color: #00e5cc; font-size: 24px; margin-bottom: 16px; }
.vs-fallback p { color: #a1a1aa; line-height: 1.6; margin-bottom: 12px; }
.vs-fallback code { background: #1a1a1a; padding: 2px 8px; border-radius: 4px; color: #00e5cc; }
`)
  writeProjectFile(projectDir,"app/layout.js",
`import "./globals.css"
export const metadata={title:"${escBt(projectName)}",description:"Generated by VIBESTACK"}
export default function RootLayout({children}) {
  return (
    <html lang="en">
      <body style={{background:'#000',color:'#f4f4f5',fontFamily:'Arial,Helvetica,sans-serif',minHeight:'100vh'}}>
        {children}
      </body>
    </html>
  )
}
`)
  writeProjectFile(projectDir,"app/error.js",
`"use client"
export default function Error({error,reset}) {
  return (
    <div style={{padding:'40px',maxWidth:'800px',margin:'0 auto',fontFamily:'Arial,sans-serif'}}>
      <h1 style={{color:'#00e5cc',fontSize:'24px',marginBottom:'16px'}}>Something went wrong</h1>
      <p style={{color:'#a1a1aa',marginBottom:'16px'}}>The app hit an error. This usually means the database is not running yet.</p>
      <p style={{color:'#a1a1aa',marginBottom:'16px'}}>
        <strong style={{color:'#f4f4f5'}}>To fix:</strong> Open the VIBESTACK Dashboard, click START DB on your project, then click START APP.
      </p>
      <pre style={{background:'#111',padding:'16px',borderRadius:'8px',color:'#ef4444',fontSize:'13px',overflow:'auto',marginBottom:'16px'}}>{error?.message||'Unknown error'}</pre>
      <button onClick={()=>reset()} style={{background:'#00e5cc',color:'#000',border:'none',padding:'10px 24px',borderRadius:'8px',fontWeight:'bold',cursor:'pointer'}}>Try Again</button>
    </div>
  )
}
`)
  writeProjectFile(projectDir,"app/loading.js",
`export default function Loading() {
  return (
    <div style={{display:'flex',alignItems:'center',justifyContent:'center',minHeight:'100vh',background:'#000'}}>
      <div style={{textAlign:'center',fontFamily:'Arial,sans-serif'}}>
        <div style={{color:'#00e5cc',fontSize:'14px',letterSpacing:'0.1em',textTransform:'uppercase'}}>VIBESTACK</div>
        <div style={{color:'#525252',fontSize:'13px',marginTop:'8px'}}>Loading...</div>
      </div>
    </div>
  )
}
`)
  writeProjectFile(projectDir,"app/page.js",
`import { AppShell } from "@/components/app-shell"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
export default function HomePage() {
  const dbReady = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY !== "REPLACED_ON_FIRST_DB_START"
  return (
    <AppShell title="${escBt(projectName)}" description="AI-ready Next.js + Supabase starter">
      {!dbReady && (
        <div className="mb-6 rounded-xl border border-yellow-500/30 bg-yellow-500/10 p-4 text-sm text-yellow-300">
          Database keys not synced yet. Run <strong>START APP</strong> from the VIBESTACK Dashboard to connect.
        </div>
      )}
      <div className="grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader><CardTitle>Welcome</CardTitle><CardDescription>Your app is ready to build.</CardDescription></CardHeader>
          <CardContent className="text-sm text-zinc-300">Open PROMPT.md and give your AI the planning prompt from the VIBESTACK Dashboard Guide tab.</CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle>Supabase</CardTitle><CardDescription>Local database</CardDescription></CardHeader>
          <CardContent className="text-sm text-zinc-300">
            DB: ${ports.db} | API: ${ports.api} | Studio: ${ports.studio}<br/>
            App: <a href="http://localhost:${ports.dev}" className="text-cyan-400 underline">localhost:${ports.dev}</a><br/>
            Status: {dbReady ? <span className="text-green-400">Connected</span> : <span className="text-yellow-400">Not connected</span>}
          </CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle>Athena Memory</CardTitle><CardDescription>AI context management</CardDescription></CardHeader>
          <CardContent className="text-sm text-zinc-300">Click SYNC on the VIBESTACK Dashboard to save AI memory. Auto-syncs when you stop the database.</CardContent>
        </Card>
      </div>
    </AppShell>
  )
}
`)
  writeProjectFile(projectDir,"app/login/page.js",
`"use client"
import { useState } from "react"
import { useRouter } from "next/navigation"
import { AppShell } from "@/components/app-shell"
import { Button } from "@/components/ui/button"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
export default function LoginPage() {
  const router=useRouter()
  const [email,setEmail]=useState("")
  const [password,setPassword]=useState("")
  const [message,setMessage]=useState("")
  async function onSubmit(e) {
    e.preventDefault();setMessage("")
    const sb=getSupabaseBrowserClient()
    if(!sb){setMessage("Supabase keys not ready. Run npm run dev first.");return}
    const{error}=await sb.auth.signInWithPassword({email,password})
    if(error){setMessage(error.message);return}
    router.push("/dashboard")
  }
  return (
    <AppShell title="${escBt(projectName)}" description="Login">
      <Card className="mx-auto max-w-xl">
        <CardHeader><CardTitle>Login</CardTitle><CardDescription>Sign in with your account.</CardDescription></CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2"><label className="text-sm text-zinc-300">Email</label>
              <input className="w-full rounded-xl border border-zinc-800 bg-black px-4 py-3 outline-none focus:border-cyan-500"
                value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" type="email" required/></div>
            <div className="space-y-2"><label className="text-sm text-zinc-300">Password</label>
              <input className="w-full rounded-xl border border-zinc-800 bg-black px-4 py-3 outline-none focus:border-cyan-500"
                value={password} onChange={e=>setPassword(e.target.value)} placeholder="********" type="password" required/></div>
            {message?<p className="text-sm text-amber-400">{message}</p>:null}
            <Button type="submit">Sign in</Button>
          </form>
        </CardContent>
      </Card>
    </AppShell>
  )
}
`)
  writeProjectFile(projectDir,"app/signup/page.js",
`"use client"
import { useState } from "react"
import { AppShell } from "@/components/app-shell"
import { Button } from "@/components/ui/button"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
export default function SignupPage() {
  const [email,setEmail]=useState("")
  const [password,setPassword]=useState("")
  const [message,setMessage]=useState("")
  async function onSubmit(e) {
    e.preventDefault();setMessage("")
    const sb=getSupabaseBrowserClient()
    if(!sb){setMessage("Supabase keys not ready. Run npm run dev first.");return}
    const{error}=await sb.auth.signUp({email,password})
    if(error){setMessage(error.message);return}
    setMessage("Account created.")
  }
  return (
    <AppShell title="${escBt(projectName)}" description="Sign up">
      <Card className="mx-auto max-w-xl">
        <CardHeader><CardTitle>Create account</CardTitle><CardDescription>Start here.</CardDescription></CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2"><label className="text-sm text-zinc-300">Email</label>
              <input className="w-full rounded-xl border border-zinc-800 bg-black px-4 py-3 outline-none focus:border-cyan-500"
                value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com" type="email" required/></div>
            <div className="space-y-2"><label className="text-sm text-zinc-300">Password</label>
              <input className="w-full rounded-xl border border-zinc-800 bg-black px-4 py-3 outline-none focus:border-cyan-500"
                value={password} onChange={e=>setPassword(e.target.value)} placeholder="********" type="password" required/></div>
            {message?<p className="text-sm text-amber-400">{message}</p>:null}
            <Button type="submit">Create account</Button>
          </form>
        </CardContent>
      </Card>
    </AppShell>
  )
}
`)
  writeProjectFile(projectDir,"app/dashboard/page.js",
`import { AppShell } from "@/components/app-shell"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
export default function DashboardPage() {
  return (
    <AppShell title="${escBt(projectName)}" description="Dashboard">
      <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
        {[["Users","Starter metric"],["Revenue","Replace or remove"],["Tasks","Starter operational"],["Alerts","Starter status"]].map(([t,d])=>(
          <Card key={t}>
            <CardHeader><CardTitle>{t}</CardTitle><CardDescription>{d}</CardDescription></CardHeader>
            <CardContent className="text-3xl font-semibold text-cyan-400">--</CardContent>
          </Card>
        ))}
      </div>
    </AppShell>
  )
}
`)
  writeProjectFile(projectDir,"app/profile/page.js",
`"use client"
import { useEffect,useState } from "react"
import { AppShell } from "@/components/app-shell"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
import { getSupabaseBrowserClient } from "@/lib/supabase/client"
export default function ProfilePage() {
  const [message,setMessage]=useState("Loading...")
  const [profile,setProfile]=useState(null)
  useEffect(()=>{
    let cancelled=false
    async function load() {
      const sb=getSupabaseBrowserClient()
      if(!sb){setMessage("Supabase keys not ready.");return}
      const{data:a,error:ae}=await sb.auth.getUser()
      if(ae||!a?.user){setMessage("No signed-in user yet.");return}
      const{data,error}=await sb.from("profiles").select("*").eq("id",a.user.id).maybeSingle()
      if(cancelled) return
      if(error){setMessage(error.message);return}
      setProfile(data);setMessage("")
    }
    load()
    return()=>{cancelled=true}
  },[])
  return (
    <AppShell title="${escBt(projectName)}" description="Profile">
      <Card className="max-w-2xl">
        <CardHeader><CardTitle>Profile</CardTitle><CardDescription>From public.profiles.</CardDescription></CardHeader>
        <CardContent>
          {message?<p className="text-sm text-zinc-300">{message}</p>:
            <pre className="overflow-auto rounded-xl border border-zinc-800 bg-black p-4 text-sm text-zinc-200">{JSON.stringify(profile,null,2)}</pre>}
        </CardContent>
      </Card>
    </AppShell>
  )
}
`)
  writeProjectFile(projectDir,"app/admin/page.js",
`import { AppShell } from "@/components/app-shell"
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card"
export default function AdminPage() {
  return (
    <AppShell title="${escBt(projectName)}" description="Admin panel">
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader><CardTitle>Admin panel</CardTitle><CardDescription>Manage users, data, and settings.</CardDescription></CardHeader>
          <CardContent className="text-sm text-zinc-300">Add role checks, management tables, and analytics as the app grows.</CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle>Next steps</CardTitle><CardDescription>Starter checklist</CardDescription></CardHeader>
          <CardContent className="space-y-2 text-sm text-zinc-300">
            <div>-- Add role checks to profiles</div>
            <div>-- Add admin-only route guards</div>
            <div>-- Add management tables</div>
            <div>-- Extend analytics cards</div>
          </CardContent>
        </Card>
      </div>
    </AppShell>
  )
}
`)

  // Scripts
  writeProjectFile(projectDir,"scripts/db-start.js",
`const{execSync}=require("child_process")
const path=require("path")
const root=path.resolve(__dirname,"..")
const shell=process.env.ComSpec||"cmd.exe"
const IS_FIRST_START=process.argv[2]==="--first-start"

function run(cmd,stdio="inherit"){
  return execSync(cmd,{cwd:root,shell,stdio,encoding:stdio==="pipe"?"utf8":undefined,env:process.env})
}
function tryRun(cmd){try{run(cmd);return true}catch{return false}}

// Docker check
try{execSync("docker info",{cwd:root,shell,stdio:"ignore",env:process.env})}
catch{console.error("Docker is not running. Open Docker Desktop and wait for it to be ready.");process.exit(1)}

// Already running?
let started=false
try{run("npx supabase status","pipe");console.log("Supabase is already running.");started=true}catch{started=false}

if(!started){
  console.log("Starting Supabase local stack...")
  console.log("(First run downloads ~2 GB of Docker images -- this can take 10-30 minutes on slow connections)")
  console.log("The screen may look frozen. That is normal. Do NOT close this window.")

  // On first project creation, stop all other stacks first to avoid port conflicts
  // (User can restart other projects after this one is set up)
  if(IS_FIRST_START){
    console.log("Clearing any conflicting Supabase stacks before first start...")
    tryRun("npx supabase stop --all")
    execSync("ping -n 3 127.0.0.1 > nul",{shell,stdio:"ignore",env:process.env})
  }

  const first=tryRun("npx supabase start")
  if(first){
    started=true
  } else {
    // On retry: aggressively clean up before trying again
    console.log("Start failed. Cleaning up and retrying...")
    tryRun("npx supabase stop")
    // Force-remove any zombie containers for this project
    const slug=path.basename(root).toLowerCase().replace(/[^a-z0-9\-_]+/g,"-").replace(/^-+|-+$/g,"")
    try{
      const names=execSync('docker ps -a --format "{{.Names}}"',{cwd:root,shell,stdio:"pipe",encoding:"utf8",env:process.env})
      names.split(/\\r?\\n/).filter(n=>n.includes(slug)).forEach(n=>{
        try{execSync('docker rm -f '+n.trim(),{cwd:root,shell,stdio:"ignore",env:process.env})}catch(e){}
      })
      console.log("Cleaned up zombie containers.")
    }catch(e){}
    execSync("ping -n 4 127.0.0.1 > nul",{shell,stdio:"ignore",env:process.env})

    const second=tryRun("npx supabase start")
    if(second){
      started=true
    } else {
      console.error("")
      console.error("Supabase failed to start.")
      console.error("")
      console.error("To fix manually:")
      console.error("  1. Make sure Docker Desktop is running (whale icon in taskbar)")
      console.error("  2. Open a terminal in this project folder")
      console.error("  3. Run: npx supabase stop --all")
      console.error("  4. Run: npm run db:start")
      process.exit(1)
    }
  }
}

console.log("Syncing Supabase env...")
run("node scripts/sync-supabase-env.js")
console.log("Supabase is ready.")
`)

  writeProjectFile(projectDir,"scripts/setup-local.js",
`const{execSync}=require("child_process")
const fs=require("fs"),path=require("path")
const root=path.resolve(__dirname,"..")
const shell=process.env.ComSpec||"cmd.exe"
// Clean env
const env=Object.assign({},process.env)
for(const k of Object.keys(env)){
  if(/(npm.globalconfig|verify.deps.before.run|_jsr.registry)/i.test(k)) delete env[k]
}
// Safety net: install deps if missing
if(!fs.existsSync(path.join(root,"node_modules","next"))){
  console.log("Installing dependencies...")
  execSync("npm install",{cwd:root,shell,stdio:"inherit",env})
}
// Quick check: is supabase already running? If yes, just sync env and go.
try{
  const status=execSync("npx supabase status",{cwd:root,shell,stdio:"pipe",encoding:"utf8",timeout:5000,env})
  if(status.includes("HEALTHY")||status.includes("127.0.0.1")){
    console.log("Supabase is already running.")
    execSync("node scripts/sync-supabase-env.js",{cwd:root,shell,stdio:"inherit",env})
    console.log("Supabase is ready.")
    process.exit(0)
  }
}catch{}
// Not running - do full startup
execSync("node scripts/db-start.js",{cwd:root,shell,stdio:"inherit",env})
`)

  writeProjectFile(projectDir,"scripts/sync-supabase-env.js",
`const fs=require("fs"),path=require("path"),{execSync}=require("child_process")
const root=path.resolve(__dirname,".."),envPath=path.join(root,".env.local")
const shell=process.env.ComSpec||"cmd.exe"
function parseEnv(text){
  const o={}
  for(const line of text.split(/\\r?\\n/)){
    const t=line.trim();if(!t||t.startsWith("#")) continue
    const i=t.indexOf("=");if(i===-1) continue
    o[t.slice(0,i).trim()]=t.slice(i+1).trim()
  }
  return o
}
function stringifyEnv(o){return Object.entries(o).map(([k,v])=>\`\${k}=\${v}\`).join("\\n")+"\\n"}
let env={}
if(fs.existsSync(envPath)) env=parseEnv(fs.readFileSync(envPath,"utf8"))
let out=""
try{out=execSync("npx supabase status -o env",{cwd:root,shell,encoding:"utf8",stdio:"pipe",env:process.env})}
catch{console.log("Could not export Supabase env. Leaving .env.local as-is.");process.exit(0)}
const s=parseEnv(out)
if(s.API_URL) env.NEXT_PUBLIC_SUPABASE_URL=s.API_URL
if(s.ANON_KEY) env.NEXT_PUBLIC_SUPABASE_ANON_KEY=s.ANON_KEY
if(s.SERVICE_ROLE_KEY) env.SUPABASE_SERVICE_ROLE_KEY=s.SERVICE_ROLE_KEY
if(s.JWT_SECRET) env.SUPABASE_JWT_SECRET=s.JWT_SECRET
if(s.DB_URL) env.SUPABASE_DB_URL=s.DB_URL
fs.writeFileSync(envPath,stringifyEnv(env),"utf8")
console.log(".env.local synced from Supabase.")
`)

  writeProjectFile(projectDir,"scripts/migration-watcher.js",
`const chokidar=require("chokidar"),{execSync}=require("child_process"),path=require("path"),fs=require("fs")
const root=path.resolve(__dirname,".."),shell=process.env.ComSpec||"cmd.exe"
const migDir=path.join(root,"supabase","migrations")
const supabaseBin=path.join(root,"node_modules",".bin","supabase.cmd")
let timeout=null
// Clean env
const env=Object.assign({},process.env)
for(const k of Object.keys(env)){
  if(/(npm.globalconfig|verify.deps.before.run|_jsr.registry)/i.test(k)) delete env[k]
}
function push(label){
  if(timeout) clearTimeout(timeout)
  timeout=setTimeout(()=>{
    console.log("[migration-watcher] "+label+" -- applying...")
    try{
      if(!fs.existsSync(supabaseBin)){
        console.log("[migration-watcher] supabase CLI not found in node_modules/.bin. Restart the app to rebuild deps.")
        return
      }
      const out=execSync('"'+supabaseBin+'" migration up',{cwd:root,shell,stdio:"pipe",encoding:"utf8",env,timeout:60000,windowsHide:true})
      if(out.trim()) console.log(out.trim())
      console.log("[migration-watcher] Done.")
    }catch(e){
      const msg=(e.stdout||"")+(e.stderr||"")
      console.log("[migration-watcher] Migration failed."+(msg?(" "+msg.trim()):" Fix the SQL and save again."))
    }
  },800)
}
console.log("[migration-watcher] Watching supabase/migrations/ ...")
chokidar.watch(path.join(migDir,"*.sql"),{ignoreInitial:true,usePolling:true,interval:4000})
  .on("add",f=>push("New file: "+path.basename(f)))
  .on("change",f=>push("Changed: "+path.basename(f)))
`)

  writeProjectFile(projectDir,"scripts/dev-startup.js",
`const {spawn,execSync}=require("child_process"),path=require("path"),fs=require("fs")
const root=path.resolve(__dirname,"..")
const shell=process.env.ComSpec||"cmd.exe"
// Clean env
const env=Object.assign({},process.env)
for(const k of Object.keys(env)){
  if(/(npm.globalconfig|verify.deps.before.run|_jsr.registry)/i.test(k)) delete env[k]
}
// DE-PNPM: Dyad uses pnpm on import, which creates a symlinked node_modules
// that breaks Next.js PostCSS resolution and supabase.cmd shims on Windows.
// If we detect pnpm artifacts, nuke node_modules and rebuild with npm flat.
function rmrf(p){
  try{
    if(!fs.existsSync(p)) return
    if(fs.rmSync){fs.rmSync(p,{recursive:true,force:true,maxRetries:5});return}
    execSync('rmdir /s /q "'+p+'"',{shell,stdio:"ignore"})
  }catch(e){}
}
const nmDir=path.join(root,"node_modules")
const pnpmDir=path.join(nmDir,".pnpm")
const pnpmLock=path.join(root,"pnpm-lock.yaml")
if(fs.existsSync(pnpmDir)||fs.existsSync(pnpmLock)){
  console.log("[startup] Detected pnpm layout from Dyad import. Converting to clean npm layout...")
  console.log("[startup] This takes 1-2 minutes the first time. Subsequent starts will be instant.")
  rmrf(nmDir)
  rmrf(pnpmLock)
  execSync("npm install",{cwd:root,shell,stdio:"inherit",env})
  console.log("[startup] Clean npm install complete.")
}
// Install deps if missing (safety net for fresh checkouts)
const supabaseBin=path.join(root,"node_modules",".bin","supabase.cmd")
if(!fs.existsSync(path.join(root,"node_modules","next"))||!fs.existsSync(supabaseBin)){
  console.log("[startup] Installing dependencies...")
  execSync("npm install",{cwd:root,shell,stdio:"inherit",env})
}
// Sync env (fast, silent fail if DB not running)
try{execSync("node scripts/sync-supabase-env.js",{cwd:root,shell,stdio:"pipe",timeout:5000,env})}catch{}
// Apply any unapplied migrations on every startup (direct binary, not npx)
try{
  const migDir=path.join(root,"supabase","migrations")
  const files=fs.existsSync(migDir)?fs.readdirSync(migDir).filter(f=>f.endsWith(".sql")):[]
  if(files.length>0&&fs.existsSync(supabaseBin)){
    console.log("[startup] Applying "+files.length+" migration(s)...")
    const out=execSync('"'+supabaseBin+'" migration up',{cwd:root,shell,stdio:"pipe",encoding:"utf8",env,timeout:60000,windowsHide:true})
    if(out.trim()) console.log(out.trim())
    console.log("[startup] Migrations applied.")
  }
}catch(e){
  const msg=(e.stdout||"")+(e.stderr||"")
  if(msg) console.log("[startup] Migration note: "+msg.trim())
}
// Kill any stale migration watcher lockfile
try{
  const lockPath=path.join(root,".migration-watcher.lock")
  if(fs.existsSync(lockPath)) fs.unlinkSync(lockPath)
}catch{}
// Background migration watcher -- log to file so it survives dev-startup exit
try{
  const logPath=path.join(root,".migration-watcher.log")
  const outFd=fs.openSync(logPath,"a")
  const errFd=fs.openSync(logPath,"a")
  const w=spawn(process.execPath,[path.join(__dirname,"migration-watcher.js")],{
    cwd:root,stdio:["ignore",outFd,errFd],env,detached:true,windowsHide:true
  })
  w.unref()
}catch(e){console.log("[startup] Could not spawn migration watcher: "+e.message)}
`)

  writeProjectFile(projectDir,"scripts/sync-athena.js",
`const fs=require("fs"),path=require("path")
const root=path.resolve(__dirname,"..")
const exportDir=path.join(root,"ATHENA_EXPORT")

// Load ATHENA_PROJECTS_PATH from .env.local (not auto-loaded outside Next.js)
function loadEnv(){
  const envPath=path.join(root,".env.local")
  if(!fs.existsSync(envPath)) return {}
  const vars={}
  fs.readFileSync(envPath,"utf8").split(/\\r?\\n/).forEach(line=>{
    const t=line.trim()
    if(!t||t.startsWith("#")) return
    const i=t.indexOf("=")
    if(i>0) vars[t.slice(0,i).trim()]=t.slice(i+1).trim()
  })
  return vars
}

const env=loadEnv()
const athenaPath=process.env.ATHENA_PROJECTS_PATH||env.ATHENA_PROJECTS_PATH||"C:\\\\VIBESTACK\\\\TOOLS\\\\Athena-Public\\\\PROJECTS"
const targetDir=path.join(athenaPath,path.basename(root))

if(!fs.existsSync(exportDir)){console.error("ATHENA_EXPORT folder not found.");process.exit(1)}
fs.mkdirSync(targetDir,{recursive:true})
let synced=0
for(const file of["MASTERPLAN.md","PROGRESS.md","NEXT_STEPS.md","DECISIONS.md"]){
  const src=path.join(exportDir,file)
  if(fs.existsSync(src)){
    const dest=path.join(targetDir,file)
    fs.copyFileSync(src,dest)
    console.log("Synced "+file)
    synced++
  }
}
if(synced===0) console.log("No Athena files to sync yet. AI will create them during development.")
else console.log("Athena sync complete: "+synced+" file(s) synced to "+targetDir)
`)

  // -- npm install ------------------------------------------------------------
  console.log("")
  console.log("  Installing project dependencies...")
  run("npm install",projectDir)

  // -- supabase init -- hard fail -----------------------------------------------
  console.log("")
  console.log("  Initializing Supabase project...")
  const initOk=tryRun("npx supabase init",projectDir)
  if(!initOk){
    console.error("  [ERROR] supabase init failed. Cannot continue.")
    console.error("  Check that npm install completed without errors and try again.")
    process.exit(1)
  }

  // -- supabase config.toml with assigned ports -------------------------------
  writeProjectFile(projectDir,"supabase/config.toml",
`project_id = "${packageName}"

[api]
enabled = true
port = ${ports.api}

[db]
port = ${ports.db}
shadow_port = ${ports.db + 10}
major_version = 17

[studio]
enabled = true
port = ${ports.studio}

[inbucket]
enabled = true
port = ${ports.mail}

[analytics]
enabled = true
port = ${ports.analytics}
`)

  ensureDir(path.join(projectDir,"supabase","migrations"))
  writeProjectFile(projectDir,"supabase/seed.sql","-- Optional seed data.\n")
  writeProjectFile(projectDir,"supabase/migrations/0001_initial_schema.sql",
`create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  full_name text,
  role text not null default 'user' check (role in ('user','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,email) values(new.id,new.email)
  on conflict(id) do update set email=excluded.email;
  return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at=now();return new;end;$$;
drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop policy if exists "Profiles are viewable by owner" on public.profiles;
create policy "Profiles are viewable by owner" on public.profiles for select to authenticated using(auth.uid()=id);
drop policy if exists "Profiles are editable by owner" on public.profiles;
create policy "Profiles are editable by owner" on public.profiles for update to authenticated using(auth.uid()=id);
drop policy if exists "Profiles are insertable by owner" on public.profiles;
create policy "Profiles are insertable by owner" on public.profiles for insert to authenticated with check(auth.uid()=id);
`)

  // -- Supabase first-run warning ---------------------------------------------
  console.log("")
  console.log("\x1b[33m  ================================================\x1b[0m")
  console.log("\x1b[33m  STARTING DATABASE -- PLEASE READ\x1b[0m")
  console.log("\x1b[33m  ================================================\x1b[0m")
  console.log("")
  console.log("  If this is your FIRST TIME running Supabase:")
  console.log("  Docker needs to download about 2 GB of database images.")
  console.log("  This can take 10-30 minutes on a slow connection.")
  console.log("  The screen may look completely frozen -- THAT IS NORMAL.")
  console.log("  DO NOT close this window. Just wait.")
  console.log("")

  run("node scripts/db-start.js --first-start",projectDir)

  // -- Per-project double-click launchers ------------------------------------
  writeProjectFile(projectDir,"START-APP.cmd",
`@echo off
title VIBESTACK - ${projectName}
cls
echo.
echo  ================================================
echo  VIBESTACK - ${projectName}
echo  ================================================
echo.
echo  This window runs your app's dev server.
echo  DO NOT CLOSE THIS WINDOW while you are coding.
echo.
echo  Your app:     http://localhost:${ports.dev} (may use next free port)
echo  Supabase DB:  Port ${ports.db}
echo  Studio:       http://localhost:${ports.studio}
echo.
echo  What is happening:
echo    - Starting your database (if not already running)
echo    - Starting the Next.js dev server (auto-finds free port)
echo    - Watching for database migration changes (auto-applies)
echo.
echo  To stop: Press Ctrl+C or close this window.
echo  ================================================
echo.
cd /d "${projectDir}"
npm run dev
echo.
echo  Dev server stopped.
pause
`)

  writeProjectFile(projectDir,"STOP-DB.cmd",
`@echo off
title Stop DB - ${projectName}
cls
echo.
echo  Stopping Supabase database for ${projectName}...
echo.
cd /d "${projectDir}"
npm run db:stop
echo.
echo  Database stopped.
pause
`)

  writeProjectFile(projectDir,"RESET-DB.cmd",
`@echo off
title Reset DB - ${projectName}
cls
echo.
echo  ================================================
echo  WARNING: RESET DATABASE
echo  ================================================
echo.
echo  This will DELETE ALL DATA in the database for:
echo  ${projectName}
echo.
set /p CONFIRM=  Type YES to confirm reset, or anything else to cancel: 
if /i "%CONFIRM%"=="YES" (
  echo.
  echo  Resetting database...
  cd /d "${projectDir}"
  npm run db:reset
  echo.
  echo  Database reset complete.
) else (
  echo.
  echo  Reset cancelled. No data was changed.
)
echo.
pause
`)

  writeProjectFile(projectDir,"OPEN-STUDIO.cmd",
`@echo off
title Supabase Studio - ${projectName}
echo Opening Supabase Studio for ${projectName}...
echo Studio runs at: http://localhost:${ports.studio}
echo Make sure the database is running first (START-APP.cmd or npm run db:start)
start http://localhost:${ports.studio}
`)

  // -- Fix permissions for IDE compatibility ------------------------------------
  // The installer runs as Admin, so all created files are admin-owned.
  // Dyad's pnpm (running as regular user) gets EPERM on admin-owned binaries.
  // Fix: grant Everyone full control of the project folder (local dev, no security concern).
  console.log("")
  console.log("  Setting file permissions for IDE compatibility...")
  try {
    execSync('icacls "'+projectDir+'" /grant *S-1-1-0:(OI)(CI)F /T /Q',{shell,stdio:"pipe",timeout:30000})
    console.log("  \x1b[32m[OK]\x1b[0m Permissions set.")
  } catch(e) {
    console.log("  \x1b[33m[WARN]\x1b[0m Could not set permissions: "+e.message)
    console.log("  If Dyad has trouble, right-click the project folder > Properties > Security > grant your user Full Control")
  }

  // -- Final success screen ---------------------------------------------------
  console.log("")
  console.log("\x1b[32m  "+"=".repeat(52)+"\x1b[0m")
  console.log("\x1b[32m  PROJECT READY: "+projectName+"\x1b[0m")
  console.log("\x1b[32m  "+"=".repeat(52)+"\x1b[0m")
  console.log("")
  console.log("  Location: "+projectDir)
  console.log("")
  console.log("\x1b[33m  NEXT STEPS:\x1b[0m")
  console.log("")
  console.log("  1. Open your project in Dyad or VS Code:")
  console.log("     Dyad: Open Dyad > Open Folder > "+projectDir)
  console.log("     VS Code: File > Open Folder > "+projectDir)
  console.log("")
  console.log("\x1b[33m     DYAD USERS: UNCHECK 'Copy to the dyad-apps folder'!\x1b[0m")
  console.log("     If you leave it checked, Dyad makes a broken copy.")
  console.log("     Always import directly from the VIBESTACK folder.")
  console.log("")
  console.log("  2. Give your AI the PLANNING prompt first (no coding yet):")
  console.log("")
  console.log("\x1b[36m     Read PROMPT.md and AI_RULES.md completely. Do NOT write any code yet.")
  console.log("     Write the master plan to ATHENA_EXPORT/MASTERPLAN.md.")
  console.log("     Break it into small phases. Update PROGRESS.md, NEXT_STEPS.md, DECISIONS.md.")
  console.log("     Planning only. Do NOT touch app/, components/, or lib/.\x1b[0m")
  console.log("")
  console.log("  3. AFTER the plan is done, say: Begin Phase 1 from the master plan.")
  console.log("")
  console.log("  3. Manage all your projects from the Dashboard:")
  console.log("     Double-click VIBESTACK Dashboard on your Desktop")
  console.log("     Or run: C:\\VIBESTACK\\VIBESTACK-DASHBOARD.cmd")
  console.log("")
}

main().catch(err=>{
  console.error("\n  [ERROR] "+err.message)
  process.exit(1)
})
'@

  Write-Utf8NoBom -Path "$VibeRoot\CORE\create-project.js" -Content $createProjectScript
  Write-Good "create-project.js written."
  }

# ==============================================================================
# STEP 5: LAUNCHERS
# ==============================================================================

function Write-LauncherFiles {
  Write-Step "WRITING LAUNCHERS"

  $cmdLauncher = @'
@echo off
setlocal
cls
echo.
echo  ================================================
echo  VIBESTACK - Create New App
echo  ================================================
echo.
echo  What do you want to call your app?
echo  Use lowercase letters and dashes only.
echo  Examples:  my-store-app   task-manager   blog-v2
echo.
set /p APPNAME=  App name: 
if "%APPNAME%"=="" (
  echo.
  echo  No name entered. Please try again.
  pause
  exit /b 1
)
echo.
echo  Creating app: %APPNAME%
echo  This will take a few minutes on first run (Docker images download).
echo  Do not close this window.
echo.
node "C:\VIBESTACK\CORE\create-project.js" "%APPNAME%"
echo.
echo  ================================================
echo  DONE. Press any key to close this window.
echo  ================================================
pause > nul
'@

  $psLauncher = @'
Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  VIBESTACK - Create New App" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  What do you want to call your app?" -ForegroundColor White
Write-Host "  Use lowercase letters and dashes only." -ForegroundColor DarkGray
Write-Host "  Examples:  my-store-app   task-manager   blog-v2" -ForegroundColor DarkGray
Write-Host ""
$appName = Read-Host "  App name"
if ([string]::IsNullOrWhiteSpace($appName)) {
  Write-Host "  No name entered. Please try again." -ForegroundColor Red
  Read-Host "  Press Enter to close"
  exit 1
}
Write-Host ""
Write-Host "  Creating: $appName" -ForegroundColor Cyan
Write-Host "  First run may take 10-30 minutes (Docker image download)." -ForegroundColor Yellow
Write-Host "  Do not close this window." -ForegroundColor Yellow
Write-Host ""
node "C:\VIBESTACK\CORE\create-project.js" $appName
Read-Host "  Press Enter to close"
'@

  Write-Utf8NoBom -Path "$VibeRoot\Create-New-VibeStack-App.cmd" -Content $cmdLauncher
  Write-Utf8NoBom -Path "$VibeRoot\Create-New-VibeStack-App.ps1"  -Content $psLauncher
  Write-Good "Launchers written."
  }

# ==============================================================================
# STEP 6: UPDATER
# ==============================================================================

function Write-UpdateScript {
  Write-Step "WRITING UPDATER SCRIPT"

  if (Test-StepDone "UPDATER") { Show-SkipStep "Updater script"; return }

  $updateScript = @'
# VIBESTACK-UPDATE.ps1
# Updates your project generator, launchers, and scripts.
# Your existing PROJECTS will NOT be changed.
$ErrorActionPreference = "Stop"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host ""
  Write-Host "  Run this as Administrator." -ForegroundColor Red
  Write-Host "  Right-click Start > Terminal (Admin)" -ForegroundColor Yellow
  Read-Host "  Press Enter to close"
  exit 1
}
$installerPath = "C:\VIBESTACK\CORE\vibestack-installer.ps1"
if (-not (Test-Path $installerPath)) {
  Write-Host "  Installer not found at $installerPath" -ForegroundColor Red
  Write-Host "  Re-run the original installer from your Desktop first." -ForegroundColor Yellow
  Read-Host "  Press Enter to close"
  exit 1
}
Write-Host ""
Write-Host "  Running VIBESTACK updater..." -ForegroundColor Cyan
Write-Host "  Your projects will NOT be touched." -ForegroundColor DarkGray
Write-Host "  Progress will be reset so all steps run fresh." -ForegroundColor DarkGray
Write-Host ""
# Remove progress file so everything reruns cleanly
$progressPath = "C:\VIBESTACK\CORE\install-progress.json"
if (Test-Path $progressPath) { Remove-Item $progressPath -Force }
Set-ExecutionPolicy -Scope Process Bypass
& $installerPath
'@

  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-UPDATE.ps1" -Content $updateScript
  Write-Good "VIBESTACK-UPDATE.ps1 written."
  Mark-StepDone "UPDATER"
}

# ==============================================================================
# STEP 7: STATUS SCRIPT
# ==============================================================================

function Write-StatusScript {
  Write-Step "WRITING STATUS SCRIPT"

  $statusScript = @'
# VIBESTACK-STATUS.ps1
# See all your projects, ports, and database states at a glance.
# No admin needed. Just double-click.

$VibeRoot = "C:\VIBESTACK"
$RegistryPath = "$VibeRoot\TOOLS\DATABASE\port-registry.json"
$ProjectsDir  = "$VibeRoot\PROJECTS"

Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  VIBESTACK STATUS" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan

# Docker
Write-Host ""
Write-Host "  DOCKER" -ForegroundColor Yellow
$dockerRunning = $false
try { docker info 2>&1 | Out-Null; $dockerRunning = ($LASTEXITCODE -eq 0) } catch {}
if ($dockerRunning) {
  Write-Host "  [ON]  Docker Desktop is running." -ForegroundColor Green
} else {
  Write-Host "  [OFF] Docker Desktop is NOT running." -ForegroundColor Red
  Write-Host "        Open Docker Desktop before starting any app." -ForegroundColor DarkGray
}

# Registry
$registry = $null
if (Test-Path $RegistryPath) {
  try {
    $raw = [System.IO.File]::ReadAllText($RegistryPath).TrimStart([char]0xFEFF)
    $registry = $raw | ConvertFrom-Json
  } catch {}
}

# Projects
Write-Host ""
Write-Host "  PROJECTS" -ForegroundColor Yellow

if (-not (Test-Path $ProjectsDir)) {
  Write-Host "  No projects folder found. Run Create-New-VibeStack-App.cmd to create your first app." -ForegroundColor DarkGray
  Write-Host ""
  Read-Host "  Press Enter to close"
  exit 0
}

$projects = Get-ChildItem $ProjectsDir -Directory -ErrorAction SilentlyContinue
if (-not $projects -or $projects.Count -eq 0) {
  Write-Host "  No projects yet. Run Create-New-VibeStack-App.cmd to make one." -ForegroundColor DarkGray
  Write-Host ""
  Read-Host "  Press Enter to close"
  exit 0
}

Write-Host ""
$hdr = "  {0,-26} {1,-7} {2,-7} {3,-7} {4,-10} {5}" -f "PROJECT","DB","API","STUDIO","STATUS","MODIFIED"
Write-Host $hdr -ForegroundColor DarkGray
Write-Host "  $("-" * 76)" -ForegroundColor DarkGray

foreach ($proj in ($projects | Sort-Object Name)) {
  $name    = $proj.Name
  $lastMod = $proj.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
  $slug    = $name.ToLower() -replace '[^a-z0-9\-_]','-' -replace '^-+|-+$',''

  $dbPort = "?"; $apiPort = "?"; $studioPort = "?"
  if ($registry -and $registry.projects -and $registry.projects.PSObject.Properties[$slug]) {
    $p = $registry.projects.$slug
    $dbPort = $p.db; $apiPort = $p.api; $studioPort = $p.studio
  }

  $status = "unknown"
  if ($dockerRunning) {
    try {
      $containers = docker ps --format "{{.Names}}" 2>&1 | Out-String
      if ($containers -match "supabase_db_$slug" -or $containers -match "supabase-db-$slug") {
        $status = "running"
      } else { $status = "stopped" }
    } catch { $status = "unknown" }
  } else { $status = "docker off" }

  $color = switch ($status) {
    "running"    { "Green" }
    "stopped"    { "DarkGray" }
    "docker off" { "Yellow" }
    default      { "DarkGray" }
  }

  $row = "  {0,-26} {1,-7} {2,-7} {3,-7} {4,-10} {5}" -f $name,$dbPort,$apiPort,$studioPort,$status,$lastMod
  Write-Host $row -ForegroundColor $color
}

Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Start an app:     double-click START-APP.cmd inside the project folder" -ForegroundColor DarkGray
Write-Host "  Create new app:   C:\VIBESTACK\Create-New-VibeStack-App.cmd" -ForegroundColor DarkGray
Write-Host "  Open Studio:      double-click OPEN-STUDIO.cmd inside the project folder" -ForegroundColor DarkGray
Write-Host "  Run diagnostics:  C:\VIBESTACK\VIBESTACK-DOCTOR.ps1" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to close"
'@

  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-STATUS.ps1" -Content $statusScript
  Write-Good "VIBESTACK-STATUS.ps1 written."
  }

# ==============================================================================
# STEP 8: HELP DOCS + DOCTOR SCRIPT
# ==============================================================================

function Write-HelpDocs {
  Write-Step "WRITING HELP DOCS AND DOCTOR SCRIPT"

  # -- VIBESTACK-HELP.txt -----------------------------------------------------
  $helpText = @'
================================================================
VIBESTACK -- HELP GUIDE
================================================================
Plain English. No jargon. Everything you need to know.
================================================================


WHAT IS VIBESTACK?
------------------
VIBESTACK is an AI app factory for your Windows PC.
It sets up your machine, creates app projects for you,
and connects everything so your AI coding tool can build
real apps with a local database -- all for free.

Your apps run completely on your own computer.
No cloud costs. No limits. No monthly bills.
Move to a real host only when you're ready to launch.


WHERE ARE MY APPS?
------------------
All your apps live here:

    C:\VIBESTACK\PROJECTS\

Each app is its own folder. Open one in Dyad or VS Code
to start building.


HOW DO I CREATE A NEW APP?
---------------------------
1. Double-click:  C:\VIBESTACK\Create-New-VibeStack-App.cmd
2. Type a name for your app (use dashes, no spaces)
   Example: my-store-app
3. Answer the questions about your app idea
4. Wait for everything to install (first run takes longer)
5. Open the project folder in Dyad or VS Code
6. Give your AI the first instruction (see below)


FIRST INSTRUCTION TO GIVE YOUR AI
------------------------------------
When you open a project, copy and paste this into your AI:

    Read PROMPT.md and AI_RULES.md completely.
    Build the master plan. Write it to ATHENA_EXPORT/MASTERPLAN.md.
    Update PROGRESS.md, NEXT_STEPS.md, and DECISIONS.md.
    Then begin implementation.

That tells the AI everything it needs to start building your app.


HOW DO I START AN APP?
-----------------------
Inside the app folder, double-click:

    START-APP.cmd

Or open a terminal in the app folder and type:

    npm run dev

Your app opens in your browser at its own unique port.
Check the Dashboard project card for the APP port number.


DOUBLE-CLICK SHORTCUTS (inside each project folder)
-----------------------------------------------------
START-APP.cmd    -- Start the app and database
STOP-DB.cmd      -- Stop the database
RESET-DB.cmd     -- Reset the database (WARNING: deletes all data)
OPEN-STUDIO.cmd  -- Open the database viewer in your browser


VIBESTACK TOOLS (at C:\VIBESTACK\)
-------------------------------------
VIBESTACK-DASHBOARD.cmd       -- Open the Dashboard (or use Desktop shortcut)
Create-New-VibeStack-App.cmd  -- Create a new app
VIBESTACK-STATUS.ps1          -- See all apps + database status
VIBESTACK-DOCTOR.ps1          -- Diagnose problems
VIBESTACK-UPDATE.ps1          -- Update VIBESTACK (run as Admin)
VIBESTACK-WIPE.cmd            -- Nuclear reset (wipe all databases, start fresh)


SOMETHING ISN'T WORKING?
--------------------------
Run the doctor first:

    C:\VIBESTACK\VIBESTACK-DOCTOR.ps1

It will tell you exactly what's wrong and how to fix it.


COMMON PROBLEMS AND FIXES
--------------------------

Problem: "Docker is not running"
Fix: Open Docker Desktop from the Start menu.
     Wait until the whale icon in your taskbar stops animating.
     Then try again.

Problem: App won't start / can't connect to database
Fix: Make sure Docker is running first.
     Then double-click START-APP.cmd in the project folder.

Problem: "Port already in use"
Fix: Run STOP-DB.cmd to stop any running database,
     then try START-APP.cmd again.

Problem: Database is broken or empty
Fix: Double-click RESET-DB.cmd in the project folder.
     WARNING: This deletes all data. Only do this if you are
     sure you want to start the database fresh.

Problem: The installer stopped partway through
Fix: Just run the installer again from your Desktop.
     It picks up where it left off automatically.

Problem: Something downloaded then Windows wanted to restart
Fix: Restart your computer, then run the installer again.
     It will skip what's already done and continue.

Problem: Dyad can't find the app / "unsafe path" error
Fix: In Dyad, click Open Folder and choose the project folder:
     C:\VIBESTACK\PROJECTS\YOUR-APP-NAME
     Do not try to open C:\VIBESTACK directly.

Problem: Ghost project folders or port conflicts
Fix: Double-click VIBESTACK-WIPE.cmd in C:\VIBESTACK\
     This removes all Docker databases and resets ports to zero.
     Your project code is NOT deleted.
     After wiping, create a new project to start fresh.

Problem: AI is going off script / replacing too much code
Fix: Open AI_RULES.md in the project and remind your AI:
     "Read AI_RULES.md again and follow the rules."


HOW TO UPDATE VIBESTACK
------------------------
Right-click the Start button > Terminal (Admin)
Then double-click:  C:\VIBESTACK\VIBESTACK-UPDATE.ps1

Your apps will NOT be affected.


HOW DOES THE DATABASE WORK?
-----------------------------
Each app has its own local database running in Docker.
It works just like a real production database -- but
it runs on your machine, not in the cloud.

The first time you start a project, Docker downloads
the database images. This takes 10-30 minutes.
After that, it starts in a few seconds.

Supabase Studio (the database viewer) runs at:
http://localhost:YOUR_STUDIO_PORT
(shown in your project's README.md)


WHAT IS ATHENA?
----------------
Athena is the memory system for your projects.

When you build an app over many sessions, the AI can
forget what it already built. Athena files solve that.

Your AI writes notes about the plan, progress, and
decisions into the ATHENA_EXPORT/ folder in your project.

You can sync those notes to a shared memory repo with:
    npm run athena:sync

This keeps your projects organized even after many sessions.


STILL STUCK?
------------
Run:  C:\VIBESTACK\VIBESTACK-DOCTOR.ps1
It diagnoses the most common problems automatically.

================================================================
'@

  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-HELP.txt" -Content $helpText
  Write-Good "VIBESTACK-HELP.txt written."

  # -- VIBESTACK-DOCTOR.ps1 --------------------------------------------------
  $doctorScript = @'
# VIBESTACK-DOCTOR.ps1
# Diagnoses your setup and tells you exactly what to fix.
# No admin needed. Double-click to run.

$VibeRoot     = "C:\VIBESTACK"
$RegistryPath = "$VibeRoot\TOOLS\DATABASE\port-registry.json"
$ProjectsDir  = "$VibeRoot\PROJECTS"
$issues       = @()

function OK($msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function WARN($msg) { Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function ERR($msg)  { Write-Host "  [X]   $msg" -ForegroundColor Red; $script:issues += $msg }
function INFO($msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  VIBESTACK DOCTOR -- SYSTEM DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan

# -- Windows -------------------------------------------------------------------
Write-Host ""
Write-Host "  WINDOWS" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -ge 19041) { OK "Windows version OK (Build $build)" }
else { ERR "Windows build $build is too old. Update Windows." }

$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
if ($ramGB -ge 8)    { OK "RAM: ${ramGB} GB" }
elseif ($ramGB -ge 4){ WARN "RAM: ${ramGB} GB -- 8 GB+ recommended for Docker + dev server" }
else                  { ERR "RAM: ${ramGB} GB -- too low for reliable Docker performance" }

$disk = Get-PSDrive C -ErrorAction SilentlyContinue
if ($disk) {
  $freeGB = [math]::Round($disk.Free / 1GB, 1)
  if ($freeGB -ge 10)    { OK "Disk space: ${freeGB} GB free" }
  elseif ($freeGB -ge 5) { WARN "Disk space: ${freeGB} GB free -- 10 GB+ recommended" }
  else                    { ERR "Disk space: ${freeGB} GB free -- too low, Docker will likely fail" }
}

# -- Core tools ----------------------------------------------------------------
Write-Host ""
Write-Host "  CORE TOOLS" -ForegroundColor Yellow

if ([bool](Get-Command "git" -ErrorAction SilentlyContinue)) {
  $gv = git --version 2>&1
  OK "Git: $gv"
} else { ERR "Git is not installed. Run VIBESTACK-UPDATE.ps1 as Admin." }

if ([bool](Get-Command "node" -ErrorAction SilentlyContinue)) {
  $nv = node -v 2>&1
  OK "Node.js: $nv"
} else { ERR "Node.js is not installed. Run VIBESTACK-UPDATE.ps1 as Admin." }

if ([bool](Get-Command "npm" -ErrorAction SilentlyContinue)) {
  $npmv = npm -v 2>&1
  OK "npm: $npmv"
} else { ERR "npm is not available. Try restarting your terminal or reinstalling Node.js." }

# GitHub Desktop
$deskPaths = @(
  "$Env:LocalAppData\GitHubDesktop\GitHubDesktop.exe",
  "$Env:ProgramFiles\GitHub Desktop\GitHubDesktop.exe"
)
$deskFound = $false
foreach ($dp in $deskPaths) { if (Test-Path $dp) { $deskFound = $true; break } }
if ($deskFound) { OK "GitHub Desktop: installed" }
else { WARN "GitHub Desktop not found. Install from https://desktop.github.com" }

# VS Code
if ([bool](Get-Command "code" -ErrorAction SilentlyContinue)) { OK "VS Code: installed" }
else { WARN "VS Code not found or 'code' not in PATH. May need terminal restart after install." }

# Dyad
$dyadPaths = @(
  "$Env:LocalAppData\Programs\Dyad\Dyad.exe",
  "$Env:LocalAppData\Dyad\Dyad.exe",
  "$Env:ProgramFiles\Dyad\Dyad.exe"
)
$dyadFound = $false
foreach ($dp in $dyadPaths) { if (Test-Path $dp) { $dyadFound = $true; break } }
if ($dyadFound) { OK "Dyad: installed" }
else { WARN "Dyad not found. Install from https://dyad.sh" }

# Docker
if ([bool](Get-Command "docker" -ErrorAction SilentlyContinue)) {
  $dockerOk = $false
  try { docker info 2>&1 | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
  if ($dockerOk) { OK "Docker Desktop: installed and RUNNING" }
  else {
    WARN "Docker Desktop is installed but NOT running."
    INFO "Open Docker Desktop from the Start menu and wait for the whale icon to be steady."
  }
} else { ERR "Docker is not installed. Run VIBESTACK-UPDATE.ps1 as Admin." }

# WSL
if ([bool](Get-Command "wsl" -ErrorAction SilentlyContinue)) {
  $wslStatus = wsl --status 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($wslStatus)) {
    OK "WSL2 kernel: ready"
  } else { WARN "WSL2 kernel may need updating. Run VIBESTACK-UPDATE.ps1 as Admin." }
} else { WARN "WSL not available. Run VIBESTACK-UPDATE.ps1 as Admin." }

# -- VIBESTACK structure -------------------------------------------------------
Write-Host ""
Write-Host "  VIBESTACK STRUCTURE" -ForegroundColor Yellow

if (Test-Path $VibeRoot)                               { OK "C:\VIBESTACK exists" }
else                                                    { ERR "C:\VIBESTACK not found. Run the installer." }

if (Test-Path "$VibeRoot\CORE\create-project.js")      { OK "Project generator: present" }
else                                                    { ERR "create-project.js missing. Run VIBESTACK-UPDATE.ps1." }

if (Test-Path $RegistryPath) {
  try {
    $reg = [System.IO.File]::ReadAllText($RegistryPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $count = ($reg.projects.PSObject.Properties | Measure-Object).Count
    OK "Port registry: $count project(s) registered"
  } catch { WARN "Port registry exists but could not be read." }
} else { WARN "Port registry not found -- will be created on first project." }

if (Test-Path "$VibeRoot\TOOLS\Athena-Public\.git")    { OK "Athena-Public: connected (git repo)" }
elseif (Test-Path "$VibeRoot\TOOLS\Athena-Public")     { WARN "Athena-Public folder exists but is not a git repo." }
else                                                    { ERR "Athena-Public not found. Run VIBESTACK-UPDATE.ps1." }

# -- Projects ------------------------------------------------------------------
Write-Host ""
Write-Host "  PROJECTS" -ForegroundColor Yellow

if (Test-Path $ProjectsDir) {
  $projects = Get-ChildItem $ProjectsDir -Directory -ErrorAction SilentlyContinue
  if (-not $projects -or $projects.Count -eq 0) {
    Write-Host "  No projects yet. Create one with Create-New-VibeStack-App.cmd" -ForegroundColor DarkGray
  } else {
    $dockerOk2 = $false
    try { docker info 2>&1 | Out-Null; $dockerOk2 = ($LASTEXITCODE -eq 0) } catch {}

    foreach ($proj in ($projects | Sort-Object Name)) {
      $slug = $proj.Name.ToLower() -replace '[^a-z0-9\-_]','-' -replace '^-+|-+$',''
      $hasPrompt   = Test-Path (Join-Path $proj.FullName "PROMPT.md")
      $hasAiRules  = Test-Path (Join-Path $proj.FullName "AI_RULES.md")
      $hasSupabase = Test-Path (Join-Path $proj.FullName "supabase\config.toml")
      $hasPackage  = Test-Path (Join-Path $proj.FullName "package.json")

      $flags = @()
      if (-not $hasPrompt)   { $flags += "missing PROMPT.md" }
      if (-not $hasAiRules)  { $flags += "missing AI_RULES.md" }
      if (-not $hasSupabase) { $flags += "missing supabase/config.toml" }
      if (-not $hasPackage)  { $flags += "missing package.json" }

      $supaStatus = "unknown"
      if ($dockerOk2) {
        try {
          $ct = docker ps --format "{{.Names}}" 2>&1 | Out-String
          $supaStatus = if ($ct -match "supabase_db_$slug" -or $ct -match "supabase-db-$slug") { "DB running" } else { "DB stopped" }
        } catch {}
      } else { $supaStatus = "Docker off" }

      if ($flags.Count -eq 0) {
        OK "$($proj.Name) -- $supaStatus"
      } else {
        WARN "$($proj.Name) -- $supaStatus -- issues: $($flags -join ', ')"
      }
    }
  }
} else {
  Write-Host "  Projects folder not found." -ForegroundColor DarkGray
}

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
  Write-Host "  ALL CHECKS PASSED -- your system looks healthy." -ForegroundColor Green
} else {
  Write-Host "  $($issues.Count) ISSUE(S) FOUND:" -ForegroundColor Red
  Write-Host ""
  foreach ($issue in $issues) {
    Write-Host "  - $issue" -ForegroundColor Yellow
  }
  Write-Host ""
  Write-Host "  Most issues are fixed by running VIBESTACK-UPDATE.ps1 as Admin." -ForegroundColor DarkGray
  Write-Host "  For Docker issues: open Docker Desktop and wait for it to say 'running'." -ForegroundColor DarkGray
}
Write-Host ""
Read-Host "  Press Enter to close"
'@

  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-DOCTOR.ps1" -Content $doctorScript
  Write-Good "VIBESTACK-DOCTOR.ps1 written."

  # Write double-clickable .cmd wrappers for every PS1 tool
  $ps1Tools = @(
    @{ name = "VIBESTACK-START-DBS";  label = "VIBESTACK - Start Databases" },
    @{ name = "VIBESTACK-STATUS";     label = "VIBESTACK - View Project Status" },
    @{ name = "VIBESTACK-DOCTOR";     label = "VIBESTACK - Run Diagnostics" },
    @{ name = "VIBESTACK-UPDATE";     label = "VIBESTACK - Update (needs Admin)" },
    @{ name = "VIBESTACK-WIPE";       label = "VIBESTACK - Nuclear Wipe (reset to zero)" }
  )
  foreach ($tool in $ps1Tools) {
    $wrapper = "@echo off`r`ntitle $($tool.label)`r`npowershell -ExecutionPolicy Bypass -File `"C:\VIBESTACK\$($tool.name).ps1`"`r`n"
    Write-Utf8NoBom -Path "$VibeRoot\$($tool.name).cmd" -Content $wrapper
  }
  Write-Good "Double-click .cmd wrappers created for all PS1 tools."
  }

# ==============================================================================
# STEP 9: SAVE INSTALLER TO CORE
# ==============================================================================

function Save-InstallerToCore {
  Write-Step "SAVING INSTALLER FOR FUTURE UPDATES"
  $selfPath = $PSCommandPath
  if ($selfPath -and (Test-Path $selfPath)) {
    Copy-Item $selfPath "$VibeRoot\CORE\vibestack-installer.ps1" -Force
    Write-Good "Installer saved to C:\VIBESTACK\CORE\vibestack-installer.ps1"
  } else {
    Write-WarnMsg "Could not auto-save installer (script path unavailable). Copy it manually if needed."
  }
}

# ==============================================================================
# STEP 10: FINAL SUCCESS SCREEN
# ==============================================================================

function Show-FinalSuccess {
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host "  VIBESTACK IS READY" -ForegroundColor Green
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host ""
  Write-Good "All tools installed and verified."
  Write-Good "Dashboard installed and ready."
  Write-Good "Desktop shortcut created."
  Write-Good "Project generator ready."
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Cyan
  Write-Host "  LAUNCHING THE VIBESTACK DASHBOARD NOW..." -ForegroundColor Cyan
  Write-Host "  ================================================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  The Dashboard is your home base for everything:" -ForegroundColor White
  Write-Host "    - Create new apps" -ForegroundColor DarkGray
  Write-Host "    - Start/stop databases" -ForegroundColor DarkGray
  Write-Host "    - Open projects in Dyad or VS Code" -ForegroundColor DarkGray
  Write-Host "    - AFK Recovery (restart paused databases)" -ForegroundColor DarkGray
  Write-Host ""

  # Auto-launch the dashboard
  try {
    $dashCmd = "$VibeRoot\VIBESTACK-DASHBOARD.cmd"
    if (Test-Path $dashCmd) {
      Write-Host "  Launching dashboard..." -ForegroundColor DarkGray
      Start-Process -FilePath $dashCmd -WorkingDirectory $VibeRoot
      Write-Good "Dashboard launching -- check your taskbar."
    }
  } catch {
    Write-WarnMsg "Could not auto-launch. Double-click VIBESTACK-DASHBOARD.cmd on your Desktop."
  }

  Write-Host ""
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "      HOW TO OPEN THE DASHBOARD NEXT TIME:" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "      Double-click VIBESTACK-DASHBOARD.cmd on your Desktop" -ForegroundColor Cyan
  Write-Host "      Or in: C:\VIBESTACK\VIBESTACK-DASHBOARD.cmd" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host ""
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host "  IMPORTANT: DOCKER SLEEP MODE" -ForegroundColor Yellow
  Write-Host "  ================================================" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Docker pauses your databases after 60 min of inactivity." -ForegroundColor White
  Write-Host "  If your AI stops working after going AFK, your DB paused." -ForegroundColor White
  Write-Host ""
  Write-Host "  FIX: Click AFK RECOVERY on the Dashboard." -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  TO DISABLE SLEEP MODE ENTIRELY:" -ForegroundColor Yellow
  Write-Host "  1. Open Docker Desktop" -ForegroundColor White
  Write-Host "  2. Click the gear icon (Settings)" -ForegroundColor White
  Write-Host "  3. Click Resources" -ForegroundColor White
  Write-Host "  4. Click Resource Saver" -ForegroundColor White
  Write-Host "  5. Toggle it OFF" -ForegroundColor White
  Write-Host ""
  Write-Host "  OTHER TOOLS IN C:\VIBESTACK\:" -ForegroundColor DarkGray
  Write-Host "    VIBESTACK-DOCTOR.cmd   -- Diagnose problems" -ForegroundColor DarkGray
  Write-Host "    VIBESTACK-WIPE.cmd     -- Reset everything to zero" -ForegroundColor DarkGray
  Write-Host "    VIBESTACK-HELP.txt     -- Plain English guide" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host "  INSTALL COMPLETE. You can close this window." -ForegroundColor Green
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host ""
  Read-Host "  Press Enter to close"
}


# ==============================================================================
# STEP: WRITE PATCH SCRIPT (desktop shortcut to update core files only)
# ==============================================================================

function Write-PatchScript {
  $patchScript = @'
@echo off
cls
echo.
echo  ================================================
echo  VIBESTACK PATCH - Updating core files
echo  ================================================
echo.
echo  This updates create-project.js and all launchers.
echo  Your existing projects will NOT be touched.
echo  Docker and Supabase keep running.
echo  No Admin required.
echo.

if not exist "C:\VIBESTACK\CORE\vibestack-installer.ps1" (
  echo  [ERROR] Installer not found at C:\VIBESTACK\CORE\
  echo  Run the full installer from your Desktop first.
  pause
  exit /b 1
)

powershell -ExecutionPolicy Bypass -Command "& 'C:\VIBESTACK\CORE\vibestack-installer.ps1' -PatchOnly"
echo.
echo  ================================================
echo  DONE. create-project.js and launchers updated.
echo  ================================================
pause > nul
'@
  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-PATCH.cmd" -Content $patchScript
  Write-Good "VIBESTACK-PATCH.cmd written at $VibeRoot\"
}


# ==============================================================================
# WRITE START-DBS SCRIPT
# ==============================================================================

function Write-StartDbsScript {
  $startDbsContent = @'
# VIBESTACK-START-DBS.ps1
# Restart databases after Docker Resource Saver paused them.
# Supports: R (recent 3), A (all stopped), 2,4,5 (comma-separated), Q (quit)

$VibeRoot = "C:\VIBESTACK"
$ProjectsDir = "$VibeRoot\PROJECTS"

Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  VIBESTACK - RESTART DATABASES" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Use this when your AI stops working after going AFK." -ForegroundColor White
Write-Host "  Docker may have paused your databases. This restarts them." -ForegroundColor DarkGray
Write-Host ""

# Docker check
$dockerOk = $false
try { docker info 2>&1 | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
if (-not $dockerOk) {
  Write-Host "  [ERROR] Docker is not running." -ForegroundColor Red
  Write-Host "  Open Docker Desktop and wait for it to be ready, then run this again." -ForegroundColor Yellow
  Write-Host ""
  Read-Host "  Press Enter to close"
  exit 1
}

# Get all projects
if (-not (Test-Path $ProjectsDir)) {
  Write-Host "  No projects found." -ForegroundColor DarkGray
  Read-Host "  Press Enter to close"
  exit 0
}

$projects = Get-ChildItem $ProjectsDir -Directory -ErrorAction SilentlyContinue
if (-not $projects -or $projects.Count -eq 0) {
  Write-Host "  No projects found." -ForegroundColor DarkGray
  Read-Host "  Press Enter to close"
  exit 0
}

# Check status + sort stopped-first by last-modified
$containers = ""
try { $containers = docker ps --format "{{.Names}}" 2>&1 | Out-String } catch {}

$projectList = @()
foreach ($proj in $projects) {
  $slug = $proj.Name.ToLower() -replace '[^a-z0-9\-_]','-' -replace '^-+|-+$',''
  $running = ($containers -match "supabase_db_$slug" -or $containers -match "supabase-db-$slug")
  $projectList += [PSCustomObject]@{
    Name = $proj.Name
    FullName = $proj.FullName
    Running = $running
    LastWrite = $proj.LastWriteTime
  }
}

# Sort: stopped first (by last-modified desc), then running
$stopped = @($projectList | Where-Object { -not $_.Running } | Sort-Object LastWrite -Descending)
$running = @($projectList | Where-Object { $_.Running } | Sort-Object LastWrite -Descending)
$sorted = @($stopped) + @($running)

Write-Host "  YOUR PROJECTS:" -ForegroundColor Yellow
Write-Host ""
$idx = 0
foreach ($p in $sorted) {
  $idx++
  $status = if ($p.Running) { "running" } else { "stopped" }
  $color = if ($p.Running) { "Green" } else { "Yellow" }
  $mark = if ($p.Running) { "" } else { " <-- needs restart" }
  Write-Host "  [$idx] $($p.Name.PadRight(30)) $status$mark" -ForegroundColor $color
}

$stoppedCount = ($sorted | Where-Object { -not $_.Running }).Count

Write-Host ""
Write-Host "  OPTIONS:" -ForegroundColor White
Write-Host "  R     = Start your 3 most recent stopped projects (AFK recovery)" -ForegroundColor Cyan
Write-Host "  A     = Start ALL stopped databases" -ForegroundColor Cyan
Write-Host "  2,4,5 = Start specific projects by number (comma-separated)" -ForegroundColor Cyan
Write-Host "  Q     = Quit" -ForegroundColor DarkGray
Write-Host ""
$choice = Read-Host "  Enter your choice"

if ($choice -eq "Q" -or $choice -eq "q" -or [string]::IsNullOrWhiteSpace($choice)) {
  exit 0
}

$toRestart = @()
if ($choice -eq "R" -or $choice -eq "r") {
  $toRestart = @($stopped | Select-Object -First 3)
  if ($toRestart.Count -eq 0) {
    Write-Host "  All databases are already running." -ForegroundColor Green
    Read-Host "  Press Enter to close"
    exit 0
  }
} elseif ($choice -eq "A" -or $choice -eq "a") {
  $toRestart = @($stopped)
  if ($toRestart.Count -eq 0) {
    Write-Host "  All databases are already running." -ForegroundColor Green
    Read-Host "  Press Enter to close"
    exit 0
  }
} else {
  # Parse comma-separated numbers
  $nums = $choice -split ',' | ForEach-Object { $_.Trim() -as [int] } | Where-Object { $_ -ge 1 -and $_ -le $sorted.Count }
  if ($nums.Count -eq 0) {
    Write-Host "  Invalid choice." -ForegroundColor Red
    Read-Host "  Press Enter to close"
    exit 1
  }
  $toRestart = @($nums | ForEach-Object { $sorted[$_ - 1] })
}

Write-Host ""
foreach ($p in $toRestart) {
  Write-Host "  Starting database for: $($p.Name)" -ForegroundColor Cyan
  $dbStartScript = Join-Path $p.FullName "scripts\db-start.js"
  if (Test-Path $dbStartScript) {
    try {
      $result = & cmd /c "cd /d `"$($p.FullName)`" && node scripts\db-start.js 2>&1"
      Write-Host "  [OK] $($p.Name) database started." -ForegroundColor Green
    } catch {
      Write-Host "  [WARN] Could not start $($p.Name). Try START-APP.cmd in the project folder." -ForegroundColor Yellow
    }
  } else {
    Write-Host "  [WARN] No db-start.js found in $($p.Name)." -ForegroundColor Yellow
  }
  Write-Host ""
}

Write-Host "  ================================================" -ForegroundColor Green
Write-Host "  Done. Your selected databases are restarting." -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Go back to your AI tool and continue working." -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to close (or click X)"
'@
  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-START-DBS.ps1" -Content $startDbsContent
  Write-Good "VIBESTACK-START-DBS.ps1 written."
}


# ==============================================================================
# WRITE DASHBOARD FILES
# ==============================================================================

function Write-DashboardFiles {
  Write-Step "INSTALLING VIBESTACK DASHBOARD"

  Ensure-Dir "$VibeRoot\DASHBOARD"
  Ensure-Dir "$VibeRoot\DASHBOARD\public"

  # -- server.js --------------------------------------------------------------
  $serverJs = @'
'use strict';

const express = require('express');
const { execSync, exec } = require('child_process');
const fs   = require('fs');
const path = require('path');

const app           = express();
const PORT          = 9999;
const VIBE_ROOT     = 'C:\\VIBESTACK';
const PROJECTS_DIR  = path.join(VIBE_ROOT, 'PROJECTS');
const REGISTRY_PATH = path.join(VIBE_ROOT, 'TOOLS', 'DATABASE', 'port-registry.json');
const PROGRESS_PATH = path.join(VIBE_ROOT, 'CORE', 'install-progress.json');

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// -- Helpers ----------------------------------------------------------------
let _dockerCache = { val: null, ts: 0 };
function getDockerRunning() {
  const now = Date.now();
  if (_dockerCache.val !== null && (now - _dockerCache.ts) < 3000) return _dockerCache.val;
  let ok = false;
  try { execSync('docker info', { stdio: 'pipe', timeout: 5000 }); ok = true; } catch (e) {}
  _dockerCache = { val: ok, ts: now };
  return ok;
}

// Batch port check: one netstat call, cached 3s, instead of per-project
let _portCache = { ports: new Set(), ts: 0 };
function getListeningPorts() {
  const now = Date.now();
  if ((now - _portCache.ts) < 3000) return _portCache.ports;
  try {
    const out = execSync('netstat -ano | findstr LISTENING', { stdio: 'pipe', timeout: 5000 }).toString();
    const ports = new Set();
    out.split(/\r?\n/).forEach(line => {
      const m = line.match(/:(\d+)\s/);
      if (m) ports.add(parseInt(m[1]));
    });
    _portCache = { ports, ts: now };
    return ports;
  } catch (e) { return _portCache.ports; }
}

function isPortListening(port) {
  if (!port) return false;
  return getListeningPorts().has(port);
}

function getRunningContainerNames() {
  try {
    return execSync('docker ps --format "{{.Names}}"', { stdio: 'pipe', timeout: 5000 })
      .toString().split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  } catch (e) { return []; }
}

function projectSlug(name) {
  return name.toLowerCase().replace(/[^a-z0-9\-_]/g, '-').replace(/^-+|-+$/, '');
}

function getDbStatus(name, runningContainers) {
  const slug = projectSlug(name);
  const isRunning = runningContainers.some(c =>
    c.includes(`supabase_db_${slug}`) || c.includes(`supabase-db-${slug}`)
  );
  return isRunning ? 'running' : 'stopped';
}

function getPortRegistry() {
  try {
    if (fs.existsSync(REGISTRY_PATH))
      return JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf8').replace(/^\uFEFF/, ''));
  } catch (e) {}
  return {};
}

function getPortsForProject(name) {
  const reg = getPortRegistry();
  const projects = reg.projects || reg;
  const slug = projectSlug(name);
  const entry = projects[slug] || projects[name] || projects[name.toUpperCase()] || projects[name.toLowerCase()];
  if (entry) {
    const dbP = entry.db || entry.dbPort || entry.db_port || null;
    return {
      dbPort:     dbP,
      apiPort:    entry.api || entry.apiPort || entry.api_port || null,
      studioPort: entry.studio || entry.studioPort || entry.studio_port || null,
      devPort:    entry.dev || entry.devPort || (dbP ? dbP + 10 : null),
    };
  }
  const configPath = path.join(PROJECTS_DIR, name, 'supabase', 'config.toml');
  if (fs.existsSync(configPath)) {
    try {
      const txt = fs.readFileSync(configPath, 'utf8');
      const grab = (re) => { const m = txt.match(re); return m ? parseInt(m[1]) : null; };
      const dbP = grab(/\[db\][\s\S]*?port\s*=\s*(\d+)/m);
      return {
        dbPort:     dbP,
        apiPort:    grab(/\[api\][\s\S]*?port\s*=\s*(\d+)/m),
        studioPort: grab(/\[studio\][\s\S]*?port\s*=\s*(\d+)/m),
        devPort:    dbP ? dbP + 10 : null,
      };
    } catch (e) {}
  }
  // Third fallback: docker container ports
  try {
    const out = execSync(`docker ps --filter "name=${slug}" --format "{{.Names}} {{.Ports}}"`,
      { stdio: 'pipe', timeout: 5000 }).toString();
    const findPort = (svc) => {
      const line = out.split(/\r?\n/).find(l => l.includes(`supabase_${svc}_${slug}`));
      if (!line) return null;
      const m = line.match(/0\.0\.0\.0:(\d+)->/);
      return m ? parseInt(m[1]) : null;
    };
    const db = findPort('db'), api = findPort('kong'), studio = findPort('studio');
    if (db || api || studio) return { dbPort: db, apiPort: api, studioPort: studio, devPort: db ? db + 10 : null };
  } catch (e) {}
  return { dbPort: null, apiPort: null, studioPort: null, devPort: null };
}

function getProjectList() {
  try {
    if (!fs.existsSync(PROJECTS_DIR)) return [];
    return fs.readdirSync(PROJECTS_DIR)
      .filter(n => fs.statSync(path.join(PROJECTS_DIR, n)).isDirectory())
      .sort();
  } catch (e) { return []; }
}

function getLastModified(name) {
  try {
    const candidates = [
      path.join(PROJECTS_DIR, name, 'package.json'),
      path.join(PROJECTS_DIR, name, 'ATHENA_EXPORT', 'PROGRESS.md'),
      path.join(PROJECTS_DIR, name),
    ];
    for (const p of candidates) {
      if (fs.existsSync(p)) return fs.statSync(p).mtime.toISOString();
    }
  } catch (e) {}
  return null;
}

function getVibestackVersion() {
  try {
    if (fs.existsSync(PROGRESS_PATH)) {
      const p = JSON.parse(fs.readFileSync(PROGRESS_PATH, 'utf8').replace(/^\uFEFF/, ''));
      return p.version || '1.5.1';
    }
  } catch (e) {}
  return '1.4';
}

function getToolVersion(cmd) {
  try { return execSync(cmd, { stdio: 'pipe', timeout: 5000 }).toString().trim().split(/\r?\n/)[0]; }
  catch (e) { return null; }
}

// -- Routes -----------------------------------------------------------------
app.get('/api/status', (req, res) => {
  res.json({ docker: getDockerRunning(), version: getVibestackVersion(), timestamp: new Date().toISOString() });
});

app.get('/api/projects', (req, res) => {
  const dockerRunning = getDockerRunning();
  const containers    = dockerRunning ? getRunningContainerNames() : [];
  const projects = getProjectList().map(name => {
    const ports = getPortsForProject(name);
    return {
      name,
      status:       dockerRunning ? getDbStatus(name, containers) : 'docker-offline',
      appStatus:    isPortListening(ports.devPort) ? 'running' : 'stopped',
      ports,
      path:         path.join(PROJECTS_DIR, name),
      lastModified: getLastModified(name),
    };
  });
  res.json({ projects, dockerRunning });
});

app.get('/api/dependencies', (req, res) => {
  const tools = [
    { name: 'Node.js',         cmd: 'node -v',         id: 'node' },
    { name: 'npm',             cmd: 'npm -v',           id: 'npm' },
    { name: 'Git',             cmd: 'git --version',    id: 'git' },
    { name: 'Docker',          cmd: 'docker --version', id: 'docker' },
    { name: 'GitHub CLI',      cmd: 'gh --version',     id: 'gh' },
    { name: 'VS Code',         cmd: 'code --version',   id: 'vscode' },
    { name: 'Supabase CLI',    cmd: 'npx supabase --version', id: 'supabase' },
  ];
  const results = tools.map(t => {
    const ver = getToolVersion(t.cmd);
    return { name: t.name, id: t.id, version: ver, installed: !!ver };
  });
  // Check Dyad separately (not a CLI tool)
  let dyadInstalled = false;
  try { dyadInstalled = !!getToolVersion('where dyad'); } catch (e) {}
  if (!dyadInstalled) {
    const dyadPaths = [
      path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Dyad', 'Dyad.exe'),
      path.join(process.env.LOCALAPPDATA || '', 'Dyad', 'Dyad.exe'),
    ];
    for (const p of dyadPaths) { if (fs.existsSync(p)) { dyadInstalled = true; break; } }
  }
  results.push({ name: 'Dyad', id: 'dyad', version: dyadInstalled ? 'Installed' : null, installed: dyadInstalled });
  // Docker running status
  results.push({ name: 'Docker Engine', id: 'docker-engine', version: getDockerRunning() ? 'Running' : 'Not running', installed: getDockerRunning() });
  res.json({ tools: results });
});

app.post('/api/projects/:name/start', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const dbStart = path.join(projPath, 'scripts', 'db-start.js');
  if (!fs.existsSync(dbStart)) return res.status(400).json({ error: 'No db-start.js found' });
  exec('node scripts\\db-start.js', { cwd: projPath, timeout: 120000, maxBuffer: 10 * 1024 * 1024 }, (err, stdout) => {
    if (err) return res.json({ success: false, error: err.message });
    res.json({ success: true });
  });
});

app.post('/api/projects/:name/stop', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const slug = projectSlug(req.params.name);
  // Auto-sync Athena memory before stopping
  const syncScript = path.join(projPath, 'scripts', 'sync-athena.js');
  if (fs.existsSync(syncScript)) {
    try { execSync('node scripts\\sync-athena.js', { cwd: projPath, timeout: 10000, stdio: 'pipe', env: process.env }); } catch(e) {}
  }
  exec('npx supabase stop', { cwd: projPath, timeout: 30000 }, (err1) => {
    if (!err1) return res.json({ success: true });
    exec(`docker ps -q --filter "name=${slug}"`, { timeout: 10000 }, (err2, stdout) => {
      const ids = (stdout || '').trim().split(/\r?\n/).filter(Boolean);
      if (!ids.length) return res.json({ success: true, note: 'No containers found' });
      exec(`docker stop ${ids.join(' ')}`, { timeout: 60000 }, (err3) => {
        res.json({ success: !err3, error: err3 ? err3.message : null });
      });
    });
  });
});

app.post('/api/projects/:name/open-studio', (req, res) => {
  const ports = getPortsForProject(req.params.name);
  if (!ports.studioPort) return res.status(400).json({ error: 'Studio port not found' });
  exec(`start http://localhost:${ports.studioPort}`);
  res.json({ success: true, url: `http://localhost:${ports.studioPort}` });
});

app.post('/api/projects/:name/open-dyad', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  let dyadPath = null;
  try { dyadPath = execSync('where dyad', { stdio: 'pipe', timeout: 3000 }).toString().trim().split(/\r?\n/)[0]; } catch (e) {}
  if (!dyadPath) {
    const candidates = [
      path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Dyad', 'Dyad.exe'),
      path.join(process.env.LOCALAPPDATA || '', 'Dyad', 'Dyad.exe'),
      path.join(process.env.PROGRAMFILES || '', 'Dyad', 'Dyad.exe'),
    ];
    for (const c of candidates) { if (fs.existsSync(c)) { dyadPath = c; break; } }
  }
  if (dyadPath) { exec(`"${dyadPath}" "${projPath}"`); res.json({ success: true }); }
  else { res.json({ success: false, error: 'Dyad not found. Install from https://dyad.sh' }); }
});

app.post('/api/projects/:name/open-vscode', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  exec(`code "${projPath}"`, (err) => { res.json({ success: !err }); });
});

app.post('/api/projects/:name/open-folder', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Not found' });
  exec(`explorer "${projPath}"`);
  res.json({ success: true });
});

app.post('/api/projects/:name/start-app', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const ports = getPortsForProject(req.params.name);
  const devPort = ports.devPort || 3000;
  // Check if port is already in use (Dyad preview may be running it)
  try {
    const netstat = execSync(`netstat -ano | findstr :${devPort} | findstr LISTENING`, { stdio: 'pipe', timeout: 5000 }).toString();
    if (netstat.trim()) {
      return res.json({ success: true, alreadyRunning: true, devPort, message: 'App already running on port ' + devPort + ' (Dyad preview may be using it). Open http://localhost:' + devPort });
    }
  } catch(e) { /* port is free, continue */ }
  // Open a visible terminal running npm run dev
  const studioPort = ports.studioPort || '';
  const dbPort = ports.dbPort || '';
  const brandCmd = [
    `title VIBESTACK - ${req.params.name}`,
    'cls',
    'echo.',
    'echo  ================================================',
    `echo  VIBESTACK - ${req.params.name}`,
    'echo  ================================================',
    'echo.',
    `echo  App:      http://localhost:${devPort}`,
    studioPort ? `echo  Studio:   http://localhost:${studioPort}` : '',
    dbPort ? `echo  DB Port:  ${dbPort}` : '',
    'echo.',
    'echo  This window runs your dev server.',
    'echo  DO NOT CLOSE this window while coding.',
    'echo  Press Ctrl+C to stop the server.',
    'echo  ================================================',
    'echo.',
    `cd /d \\"${projPath}\\"`,
    'npm run dev'
  ].filter(Boolean).join(' && ');
  exec(`powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/k ${brandCmd}' -WorkingDirectory '${projPath}'"`, { timeout: 5000 });
  res.json({ success: true, devPort });
});

app.post('/api/projects/:name/stop-app', (req, res) => {
  const ports = getPortsForProject(req.params.name);
  const devPort = ports.devPort;
  if (!devPort) return res.status(400).json({ error: 'Dev port not found' });
  try {
    const out = execSync('netstat -ano | findstr :' + devPort + ' | findstr LISTENING', { stdio: 'pipe', timeout: 5000 }).toString();
    const pids = [...new Set(out.split(/\r?\n/).map(l => l.trim().split(/\s+/).pop()).filter(p => p && p !== '0'))];
    for (const pid of pids) {
      try { execSync('taskkill /PID ' + pid + ' /T /F', { stdio: 'pipe', timeout: 5000 }); } catch(e) {}
    }
    res.json({ success: true, killed: pids.length });
  } catch(e) {
    res.json({ success: true, note: 'No process found on port ' + devPort });
  }
});

app.post('/api/projects/:name/push-db', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const supabaseBin = path.join(projPath, 'node_modules', '.bin', 'supabase.cmd');
  if (!fs.existsSync(supabaseBin)) {
    return res.json({ success: false, error: 'supabase CLI not found at node_modules\\.bin\\supabase.cmd. The project may still have a pnpm layout from Dyad. Stop the app, then click START APP -- dev-startup will rebuild node_modules cleanly.' });
  }
  exec('"' + supabaseBin + '" migration up', { cwd: projPath, timeout: 60000, maxBuffer: 10 * 1024 * 1024, windowsHide: true }, (err, stdout, stderr) => {
    const output = ((stdout || '') + (stderr || '')).trim();
    if (err) return res.json({ success: false, error: output || err.message });
    res.json({ success: true, output: output });
  });
});

app.post('/api/projects/:name/sync-athena', (req, res) => {
  const projPath = path.join(PROJECTS_DIR, req.params.name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const syncScript = path.join(projPath, 'scripts', 'sync-athena.js');
  if (!fs.existsSync(syncScript)) return res.status(400).json({ error: 'No sync-athena.js found' });
  exec('node scripts\\sync-athena.js', { cwd: projPath, timeout: 15000, env: process.env }, (err, stdout) => {
    if (err) return res.json({ success: false, error: err.message });
    res.json({ success: true, output: (stdout || '').trim() });
  });
});

app.post('/api/projects/:name/delete', (req, res) => {
  const name = req.params.name;
  const projPath = path.join(PROJECTS_DIR, name);
  if (!fs.existsSync(projPath)) return res.status(404).json({ error: 'Project not found' });
  const slug = projectSlug(name);
  const steps = [];
  // 1. Stop and remove Docker containers
  try {
    const names = execSync('docker ps -a --format "{{.Names}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    const matching = names.split(/\r?\n/).filter(n => n.includes(slug)).map(n => n.trim()).filter(Boolean);
    for (const c of matching) { try { execSync('docker rm -f ' + c, { stdio: 'pipe', timeout: 10000 }); } catch(e){} }
    steps.push('Removed ' + matching.length + ' containers');
  } catch(e) { steps.push('Container cleanup: ' + (e.message || 'skipped')); }
  // 2. Remove Docker volumes
  try {
    const vols = execSync('docker volume ls --format "{{.Name}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    const matching = vols.split(/\r?\n/).filter(v => v.includes(slug)).map(v => v.trim()).filter(Boolean);
    for (const v of matching) { try { execSync('docker volume rm -f ' + v, { stdio: 'pipe', timeout: 10000 }); } catch(e){} }
    steps.push('Removed ' + matching.length + ' volumes');
  } catch(e) { steps.push('Volume cleanup: ' + (e.message || 'skipped')); }
  // 3. Remove from port registry
  try {
    const reg = JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf8').replace(/^\uFEFF/, ''));
    if (reg.projects && reg.projects[slug]) {
      delete reg.projects[slug];
      fs.writeFileSync(REGISTRY_PATH, JSON.stringify(reg, null, 2), 'utf8');
      steps.push('Removed from port registry');
    }
  } catch(e) { steps.push('Registry cleanup: ' + (e.message || 'skipped')); }
  // 4. Delete project folder
  try {
    fs.rmSync(projPath, { recursive: true, force: true });
    steps.push('Deleted project folder');
  } catch(e) { steps.push('Folder delete: ' + (e.message || 'failed')); }
  _dockerCache = { val: null, ts: 0 };
  res.json({ success: true, steps });
});

app.post('/api/create-project', (req, res) => {
  const launcher = path.join('C:\\VIBESTACK', 'Create-New-VibeStack-App.cmd');
  if (!fs.existsSync(launcher)) return res.status(404).json({ error: 'Launcher not found' });
  // Use PowerShell Start-Process to force window to foreground
  exec(`powershell -NoProfile -Command "Start-Process -FilePath '${launcher.replace(/'/g,"''")}' -WorkingDirectory 'C:\\VIBESTACK'"`, { timeout: 5000 });
  res.json({ success: true });
});

app.post('/api/wipe', (req, res) => {
  if (req.body.confirm !== 'WIPE') return res.status(400).json({ error: 'Send {confirm:"WIPE"}' });
  const steps = [];
  try {
    // Stop all containers
    try { const ids = execSync('docker ps -q', { stdio: 'pipe', timeout: 10000 }).toString().trim();
      if (ids) { execSync(`docker stop ${ids.split(/\r?\n/).join(' ')}`, { stdio: 'pipe', timeout: 60000 }); }
      steps.push('Stopped all containers');
    } catch (e) { steps.push('Stop containers: ' + (e.message || 'skipped')); }
    // Remove supabase containers
    try { const names = execSync('docker ps -a --format "{{.Names}}"', { stdio: 'pipe', timeout: 10000 }).toString();
      const sc = names.split(/\r?\n/).filter(n => n.includes('supabase'));
      for (const c of sc) { try { execSync(`docker rm -f ${c.trim()}`, { stdio: 'pipe', timeout: 10000 }); } catch(e2){} }
      steps.push(`Removed ${sc.length} containers`);
    } catch (e) { steps.push('Remove containers: ' + (e.message || 'skipped')); }
    // Remove volumes
    try { const vols = execSync('docker volume ls --format "{{.Name}}"', { stdio: 'pipe', timeout: 10000 }).toString();
      const sv = vols.split(/\r?\n/).filter(v => v.includes('supabase'));
      for (const v of sv) { try { execSync(`docker volume rm -f ${v.trim()}`, { stdio: 'pipe', timeout: 10000 }); } catch(e2){} }
      steps.push(`Removed ${sv.length} volumes`);
    } catch (e) { steps.push('Remove volumes: ' + (e.message || 'skipped')); }
    // Reset port registry
    try {
      fs.writeFileSync(REGISTRY_PATH, '{"nextBase":55000,"projects":{}}', 'utf8');
      steps.push('Port registry reset');
    } catch (e) { steps.push('Registry reset: ' + (e.message || 'failed')); }
    // Clean ghost folders
    try { if (fs.existsSync(PROJECTS_DIR)) {
        const dirs = fs.readdirSync(PROJECTS_DIR).filter(n => fs.statSync(path.join(PROJECTS_DIR, n)).isDirectory());
        let ghosts = 0;
        for (const d of dirs) {
          const dp = path.join(PROJECTS_DIR, d);
          if (!fs.existsSync(path.join(dp, 'package.json')) && !fs.existsSync(path.join(dp, 'app'))) {
            fs.rmSync(dp, { recursive: true, force: true }); ghosts++;
          }
        }
        steps.push(`Cleaned ${ghosts} ghost folders`);
      }
    } catch (e) { steps.push('Ghost cleanup: ' + (e.message || 'skipped')); }
    try { execSync('docker network prune -f', { stdio: 'pipe', timeout: 10000 }); } catch(e){}
    _dockerCache = { val: null, ts: 0 };
    res.json({ success: true, steps });
  } catch (e) { res.json({ success: false, error: e.message, steps }); }
});

app.get('/api/port-registry', (req, res) => { res.json(getPortRegistry()); });

app.get('/api/docker-info', (req, res) => {
  const dockerRunning = getDockerRunning();
  if (!dockerRunning) return res.json({ running: false, containers: [], volumes: [], orphans: [] });
  const projectFolders = getProjectList().map(n => projectSlug(n));
  // Get containers
  let containers = [];
  try {
    const out = execSync('docker ps -a --format "{{.Names}}|{{.Status}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    containers = out.split(/\r?\n/).map(l => l.trim()).filter(l => l.includes('supabase')).map(l => {
      const [name, status] = l.split('|');
      const slugMatch = name.replace(/^supabase_\w+_/, '');
      return { name: name.trim(), status: (status||'').trim(), project: slugMatch, orphan: !projectFolders.some(p => name.includes(p)) };
    });
  } catch(e) {}
  // Get volumes
  let volumes = [];
  try {
    const out = execSync('docker volume ls --format "{{.Name}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    volumes = out.split(/\r?\n/).map(v => v.trim()).filter(v => v.includes('supabase')).map(v => {
      const slugMatch = v.replace(/^supabase_\w+_/, '');
      return { name: v, project: slugMatch, orphan: !projectFolders.some(p => v.includes(p)) };
    });
  } catch(e) {}
  const orphans = {
    containers: containers.filter(c => c.orphan).map(c => c.name),
    volumes: volumes.filter(v => v.orphan).map(v => v.name)
  };
  res.json({ running: true, containers, volumes, orphans, orphanCount: orphans.containers.length + orphans.volumes.length });
});

app.post('/api/docker/clean-orphans', (req, res) => {
  const steps = [];
  const projectFolders = getProjectList().map(n => projectSlug(n));
  // Remove orphan containers
  try {
    const out = execSync('docker ps -a --format "{{.Names}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    const orphans = out.split(/\r?\n/).map(n => n.trim()).filter(n => n.includes('supabase') && !projectFolders.some(p => n.includes(p)));
    for (const c of orphans) { try { execSync('docker rm -f ' + c, { stdio: 'pipe', timeout: 10000 }); } catch(e){} }
    steps.push('Removed ' + orphans.length + ' orphan containers');
  } catch(e) { steps.push('Container cleanup: ' + (e.message || 'skipped')); }
  // Remove orphan volumes
  try {
    const out = execSync('docker volume ls --format "{{.Name}}"', { stdio: 'pipe', timeout: 10000 }).toString();
    const orphans = out.split(/\r?\n/).map(v => v.trim()).filter(v => v.includes('supabase') && !projectFolders.some(p => v.includes(p)));
    for (const v of orphans) { try { execSync('docker volume rm -f ' + v, { stdio: 'pipe', timeout: 10000 }); } catch(e){} }
    steps.push('Removed ' + orphans.length + ' orphan volumes');
  } catch(e) { steps.push('Volume cleanup: ' + (e.message || 'skipped')); }
  _dockerCache = { val: null, ts: 0 };
  res.json({ success: true, steps });
});

app.post('/api/docker/stop-all', (req, res) => {
  try {
    const ids = execSync('docker ps -q', { stdio: 'pipe', timeout: 10000 }).toString().trim();
    if (ids) { execSync('docker stop ' + ids.split(/\r?\n/).join(' '), { stdio: 'pipe', timeout: 60000 }); }
    _dockerCache = { val: null, ts: 0 };
    res.json({ success: true });
  } catch(e) { res.json({ success: false, error: e.message }); }
});

app.post('/api/docker/prune-networks', (req, res) => {
  try {
    execSync('docker network prune -f', { stdio: 'pipe', timeout: 10000 });
    res.json({ success: true });
  } catch(e) { res.json({ success: false, error: e.message }); }
});

const server = app.listen(PORT, '127.0.0.1', () => {
  console.log('  [OK] Dashboard server ready.');
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.log('');
    console.log('  [OK] Dashboard is already running.');
    console.log('');
    process.exit(0);
  } else {
    console.error('  [ERROR] Server error:', err.message);
    process.exit(1);
  }
});

'@
  Write-Utf8NoBom -Path "$VibeRoot\DASHBOARD\server.js" -Content $serverJs
  Write-Good "DASHBOARD\server.js written."

  # -- package.json -----------------------------------------------------------
  $dashPkg = '{"name":"vibestack-dashboard","version":"1.5.1","main":"server.js","scripts":{"start":"node server.js"},"dependencies":{"express":"^4.18.2"}}'
  Write-Utf8NoBom -Path "$VibeRoot\DASHBOARD\package.json" -Content $dashPkg
  Write-Good "DASHBOARD\package.json written."

  # -- public/index.html ------------------------------------------------------
  $indexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VIBESTACK DASHBOARD</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@300;400;500;600&display=swap');
  :root {
    --bg:#080808;--bg-card:#111111;--bg-hover:#191919;--bg-sel:#0d1a18;
    --border:#2a2a2a;--border-hi:#3a3a3a;--border-sel:#00e5cc44;
    --cyan:#00e5cc;--cyan-dim:rgba(0,229,204,0.12);
    --green:#22c55e;--green-dim:rgba(34,197,94,0.14);
    --yellow:#f59e0b;--yellow-dim:rgba(245,158,11,0.14);
    --red:#ef4444;--red-dim:rgba(239,68,68,0.14);
    --gray:#525252;--text:#e5e5e5;--text-dim:#a3a3a3;--text-xdim:#737373;
    --mono:'Space Mono',monospace;--sans:'DM Sans',sans-serif;
  }
  [data-theme="light"] {
    --bg:#f5f5f4;--bg-card:#ffffff;--bg-hover:#e7e5e4;--bg-sel:#e0f7f4;
    --border:#d6d3d1;--border-hi:#a8a29e;--border-sel:#00b8a366;
    --cyan:#0d9488;--cyan-dim:rgba(13,148,136,0.1);
    --green:#16a34a;--green-dim:rgba(22,163,74,0.1);
    --yellow:#d97706;--yellow-dim:rgba(217,119,6,0.1);
    --red:#dc2626;--red-dim:rgba(220,38,38,0.1);
    --gray:#78716c;--text:#1c1917;--text-dim:#57534e;--text-xdim:#78716c;
  }
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:var(--sans);font-size:14px;line-height:1.5;min-height:100vh}

  /* Header */
  .header{position:sticky;top:0;z-index:100;background:var(--bg);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);padding:0 28px;height:56px;display:flex;align-items:center;gap:16px}
  :root .header{background:rgba(8,8,8,0.96)}
  [data-theme="light"] .header{background:rgba(245,245,244,0.96)}
  .logo{font-family:var(--mono);font-size:13px;font-weight:700;letter-spacing:.12em;color:var(--cyan);text-transform:uppercase;display:flex;align-items:center;gap:8px}
  .logo-b{color:var(--text-xdim);font-weight:400}
  .header-sep{flex:1}
  .docker-badge{display:flex;align-items:center;gap:7px;padding:5px 12px;border:1px solid var(--border);border-radius:3px;font-family:var(--mono);font-size:10px;letter-spacing:.1em;text-transform:uppercase;transition:all .3s}
  .docker-badge.running{border-color:rgba(34,197,94,.4);color:var(--green);background:var(--green-dim)}
  .docker-badge.stopped{border-color:rgba(239,68,68,.4);color:var(--red);background:var(--red-dim)}
  .docker-dot{width:7px;height:7px;border-radius:50%;background:currentColor}
  .vtag{font-family:var(--mono);font-size:10px;color:var(--text-xdim);letter-spacing:.08em}
  .theme-toggle{width:34px;height:34px;display:flex;align-items:center;justify-content:center;border:1px solid var(--border);border-radius:3px;background:transparent;color:var(--text-dim);font-size:16px;cursor:pointer;transition:all .15s;line-height:1}
  .theme-toggle:hover{border-color:var(--cyan);color:var(--cyan);background:var(--cyan-dim)}

  /* Tabs */
  .tabs{display:flex;gap:0;padding:0 28px;border-bottom:1px solid var(--border);background:var(--bg)}
  .tab{padding:12px 24px;font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--text-dim);cursor:pointer;border-bottom:2px solid transparent;transition:all .15s;user-select:none}
  .tab:hover{color:var(--text);background:var(--bg-hover)}
  .tab.active{color:var(--cyan);border-bottom-color:var(--cyan)}
  .tab-panel{display:none}
  .tab-panel.active{display:block}

  /* Toolbar */
  .toolbar{padding:16px 28px 12px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .tlabel{font-family:var(--mono);font-size:11px;color:var(--text-dim);letter-spacing:.1em;text-transform:uppercase}
  .tcount{font-family:var(--mono);font-size:11px;color:var(--text-xdim)}
  .tsep{flex:1}

  /* Buttons */
  .btn{display:inline-flex;align-items:center;gap:6px;padding:7px 14px;border-radius:2px;font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;transition:all .15s;border:1px solid transparent;user-select:none}
  .btn:disabled{opacity:.35;cursor:not-allowed}
  .btn-new{padding:8px 18px;background:var(--cyan);color:#000;border:none;border-radius:2px;font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;cursor:pointer;transition:all .15s;display:inline-flex;align-items:center;gap:6px}
  .btn-new:hover{background:#00fff5;transform:translateY(-1px);box-shadow:0 4px 16px rgba(0,229,204,.3)}
  .btn-afk{padding:8px 16px;background:var(--yellow-dim);color:var(--yellow);border:1px solid rgba(245,158,11,.4);border-radius:2px;font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;transition:all .15s;display:none;align-items:center;gap:6px}
  .btn-afk:hover{background:rgba(245,158,11,.22);border-color:rgba(245,158,11,.7)}
  .btn-start{background:var(--green-dim);color:var(--green);border-color:rgba(34,197,94,.35)}
  .btn-start:hover:not(:disabled){background:rgba(34,197,94,.25);border-color:rgba(34,197,94,.6)}
  .btn-stop{background:var(--red-dim);color:var(--red);border-color:rgba(239,68,68,.35)}
  .btn-stop:hover:not(:disabled){background:rgba(239,68,68,.25);border-color:rgba(239,68,68,.6)}
  .btn-ghost{background:transparent;color:var(--text-dim);border-color:var(--border)}
  .btn-ghost:hover:not(:disabled){background:var(--bg-hover);color:var(--text);border-color:var(--border-hi)}
  .btn-studio{background:var(--cyan-dim);color:var(--cyan);border-color:rgba(0,229,204,.3)}
  .btn-studio:hover:not(:disabled){background:rgba(0,229,204,.2);border-color:rgba(0,229,204,.6)}
  .btn-refresh{padding:8px 16px;background:transparent;color:var(--text-dim);border:1px solid var(--border);border-radius:2px;font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;transition:all .15s}
  .btn-refresh:hover{background:var(--bg-hover);color:var(--cyan);border-color:var(--cyan)}
  .btn-refresh.spinning{animation:spin .6s linear}
  @keyframes spin{to{transform:rotate(360deg)}}
  .btn-danger{padding:10px 24px;background:var(--red-dim);color:var(--red);border:1px solid rgba(239,68,68,.5);border-radius:2px;font-family:var(--mono);font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;transition:all .15s}
  .btn-danger:hover:not(:disabled){background:rgba(239,68,68,.25);border-color:var(--red)}

  /* Bulk bar */
  .bulk-bar{padding:10px 28px;background:var(--bg-sel);border-bottom:1px solid var(--border-sel);display:none;align-items:center;gap:12px;animation:sd .15s ease}
  .bulk-bar.on{display:flex}
  @keyframes sd{from{opacity:0;transform:translateY(-6px)}to{opacity:1;transform:translateY(0)}}
  .blabel{font-family:var(--mono);font-size:11px;color:var(--cyan);letter-spacing:.06em}
  .bsep{flex:1}
  .btn-desel{background:transparent;color:var(--text-xdim);border-color:var(--border)}
  .btn-desel:hover{color:var(--text-dim);border-color:var(--border-hi)}
  .btn-ssel{background:var(--green-dim);color:var(--green);border-color:rgba(34,197,94,.5)}
  .btn-ssel:hover:not(:disabled){background:rgba(34,197,94,.25);border-color:rgba(34,197,94,.8)}

  /* Banner */
  .banner{margin:0 28px 16px;padding:14px 18px;background:var(--red-dim);border:1px solid rgba(239,68,68,.4);border-radius:3px;font-family:var(--mono);font-size:11px;color:var(--red);letter-spacing:.06em;display:none;align-items:center;gap:10px}
  .banner.on{display:flex}

  /* Grid */
  .grid{padding:0 28px 48px;display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:16px}
  .card{background:var(--bg-card);border:1px solid var(--border);border-radius:4px;overflow:hidden;transition:border-color .2s,box-shadow .2s;animation:cin .3s ease both;position:relative}
  .card:hover{border-color:var(--border-hi);box-shadow:0 0 0 1px rgba(255,255,255,.03),0 8px 32px rgba(0,0,0,.4)}
  .card.selected{border-color:var(--border-sel)!important;background:var(--bg-sel);box-shadow:0 0 0 1px rgba(0,229,204,.1)}
  @keyframes cin{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
  .card.allup{border-top:2px solid var(--green)}
  .card.dbonly{border-top:2px solid var(--yellow)}
  .card.stopped{border-top:2px solid var(--border)}
  .card.loading{border-top:2px solid var(--yellow)}
  .card.offline{border-top:2px solid var(--border)}
  .cbx{position:absolute;top:12px;left:14px;z-index:10;width:16px;height:16px;border:1.5px solid var(--border-hi);border-radius:2px;background:var(--bg-card);cursor:pointer;transition:all .15s;display:flex;align-items:center;justify-content:center}
  .cbx:hover{border-color:var(--cyan)}
  .card.selected .cbx{background:var(--cyan);border-color:var(--cyan)}
  .cbx-tick{width:8px;height:8px;display:none;background:#000;clip-path:polygon(14% 44%,0 65%,50% 100%,100% 16%,80% 0%,43% 62%)}
  .card.selected .cbx-tick{display:block}
  .card-header{padding:14px 18px 10px 38px;display:flex;align-items:flex-start;gap:12px}
  .card-name{flex:1;font-family:var(--mono);font-size:12px;font-weight:700;letter-spacing:.06em;color:var(--text);word-break:break-all}
  .card-ports{padding:0 18px 12px;display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
  .pcell{background:var(--bg);border:1px solid var(--border);border-radius:3px;padding:7px 9px}
  .plabel{font-family:var(--mono);font-size:8px;color:var(--text-xdim);letter-spacing:.12em;text-transform:uppercase;margin-bottom:3px}
  .pval{font-family:var(--mono);font-size:12px;color:var(--cyan);font-weight:700}
  .pval.n{color:var(--text-xdim)}
  .cmeta{padding:0 18px 12px;font-family:var(--mono);font-size:9px;color:var(--text-xdim);letter-spacing:.06em}
  .card-actions{padding:11px 18px;border-top:1px solid var(--border);display:flex;flex-wrap:wrap;gap:6px}

  /* Service rows */
  .svc-rows{padding:0 18px 8px;display:flex;flex-direction:column;gap:6px}
  .svc-row{display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--bg);border:1px solid var(--border);border-radius:3px}
  .svc-label{font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--text-dim);width:32px;flex-shrink:0}
  .svc-pill{display:flex;align-items:center;gap:4px;padding:2px 8px;border-radius:2px;font-family:var(--mono);font-size:8px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;flex-shrink:0}
  .svc-pill.on{background:var(--green-dim);color:var(--green);border:1px solid rgba(34,197,94,.3)}
  .svc-pill.off{background:rgba(82,82,82,.1);color:var(--gray);border:1px solid rgba(82,82,82,.25)}
  .svc-pill.load{background:var(--yellow-dim);color:var(--yellow);border:1px solid rgba(245,158,11,.3)}
  .svc-pill .pd{width:4px;height:4px;border-radius:50%;background:currentColor}
  .svc-sep{flex:1}
  .svc-btn{padding:3px 8px;border-radius:2px;font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:.06em;cursor:pointer;border:1px solid transparent;transition:all .12s;background:transparent;display:inline-flex;align-items:center;gap:4px}
  .svc-btn:disabled{opacity:.3;cursor:not-allowed}
  .svc-btn.play{color:var(--green);border-color:rgba(34,197,94,.3)}
  .svc-btn.play:hover:not(:disabled){background:var(--green-dim);border-color:rgba(34,197,94,.6)}
  .svc-btn.stop{color:var(--red);border-color:rgba(239,68,68,.3)}
  .svc-btn.stop:hover:not(:disabled){background:var(--red-dim);border-color:rgba(239,68,68,.6)}
  .svc-btn.open{color:var(--cyan);border-color:rgba(0,229,204,.3)}
  .svc-btn.open:hover:not(:disabled){background:var(--cyan-dim);border-color:rgba(0,229,204,.6)}

  /* Empty state */
  .empty{grid-column:1/-1;padding:64px 0;text-align:center}
  .empty-t{font-family:var(--mono);font-size:14px;color:var(--text-dim);letter-spacing:.08em;margin-bottom:10px}
  .empty-s{font-size:13px;color:var(--text-xdim);margin-bottom:24px}

  /* Tools table */
  .tools-section{padding:24px 28px 48px}
  .tools-table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:12px}
  .tools-table th{text-align:left;padding:10px 16px;color:var(--text-dim);font-size:10px;letter-spacing:.1em;text-transform:uppercase;border-bottom:1px solid var(--border)}
  .tools-table td{padding:12px 16px;border-bottom:1px solid var(--border)}
  .tools-table tr:hover td{background:var(--bg-hover)}
  .tools-table .tool-name{color:var(--text);font-weight:700}
  .tools-table .tool-ver{color:var(--cyan)}
  .tools-table .tool-miss{color:var(--red)}
  .pill-ok{display:inline-block;padding:2px 10px;border-radius:2px;font-size:9px;font-weight:700;letter-spacing:.1em;background:var(--green-dim);color:var(--green);border:1px solid rgba(34,197,94,.3)}
  .pill-miss{display:inline-block;padding:2px 10px;border-radius:2px;font-size:9px;font-weight:700;letter-spacing:.1em;background:var(--red-dim);color:var(--red);border:1px solid rgba(239,68,68,.3)}

  /* Recovery section */
  .recovery-section{padding:24px 28px 48px;max-width:700px}
  .recovery-section h2{font-family:var(--mono);font-size:14px;color:var(--cyan);letter-spacing:.1em;text-transform:uppercase;margin-bottom:16px}
  .recovery-section p{color:var(--text-dim);margin-bottom:12px;line-height:1.7}
  .recovery-section .warn-box{background:var(--red-dim);border:1px solid rgba(239,68,68,.3);border-radius:3px;padding:16px 20px;margin:20px 0;font-family:var(--mono);font-size:11px;color:var(--red);line-height:1.8}
  .recovery-section .info-box{background:var(--cyan-dim);border:1px solid rgba(0,229,204,.2);border-radius:3px;padding:16px 20px;margin:20px 0;font-family:var(--mono);font-size:11px;color:var(--cyan);line-height:1.8}
  .wipe-status{margin-top:16px;font-family:var(--mono);font-size:11px;color:var(--text-dim);white-space:pre-line}
  .recovery-section .step-list{color:var(--text-dim);padding-left:20px;margin:12px 0;line-height:2}

  /* Toast */
  .tc{position:fixed;bottom:24px;right:24px;z-index:999;display:flex;flex-direction:column;gap:8px;pointer-events:none;max-width:520px}
  .toast{padding:12px 14px 12px 16px;border-radius:4px;font-family:var(--mono);font-size:11px;letter-spacing:.04em;line-height:1.5;animation:ti .2s ease;pointer-events:auto;border:1px solid transparent;display:flex;gap:10px;align-items:flex-start;position:relative}
  .toast.ok{background:var(--green-dim);color:var(--green);border-color:rgba(34,197,94,.4)}
  .toast.info{background:var(--cyan-dim);color:var(--cyan);border-color:rgba(0,229,204,.3)}
  .toast.error{background:var(--red-dim);color:var(--red);border-color:rgba(239,68,68,.5);max-width:520px}
  .toast .tmsg{flex:1;word-break:break-word;max-height:200px;overflow-y:auto;white-space:pre-wrap}
  .toast .tactions{display:flex;flex-direction:column;gap:4px;flex-shrink:0}
  .toast .tbtn{background:transparent;border:1px solid currentColor;color:inherit;border-radius:2px;padding:3px 7px;font-family:var(--mono);font-size:9px;font-weight:700;cursor:pointer;opacity:.7;transition:opacity .15s}
  .toast .tbtn:hover{opacity:1}
  .toast.error .tmsg{max-height:300px}
  @keyframes ti{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}

  /* Error log button (bottom-left) */
  .errlog-btn{position:fixed;bottom:24px;left:24px;z-index:998;padding:8px 14px;background:var(--bg-card);border:1px solid var(--border);border-radius:3px;font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--text-dim);cursor:pointer;display:none;align-items:center;gap:6px;transition:all .15s}
  .errlog-btn.on{display:inline-flex}
  .errlog-btn:hover{border-color:var(--red);color:var(--red);background:var(--red-dim)}
  .errlog-count{background:var(--red);color:#000;border-radius:10px;padding:0 6px;font-size:9px;min-width:16px;text-align:center}

  /* Error log modal */
  .errlog-modal{display:none;position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,.7);backdrop-filter:blur(4px);align-items:center;justify-content:center;padding:24px}
  .errlog-modal.on{display:flex}
  .errlog-box{background:var(--bg-card);border:1px solid var(--border-hi);border-radius:6px;max-width:800px;width:100%;max-height:80vh;display:flex;flex-direction:column;box-shadow:0 20px 60px rgba(0,0,0,.5)}
  .errlog-head{padding:16px 20px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px}
  .errlog-head h3{flex:1;font-family:var(--mono);font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--red)}
  .errlog-body{flex:1;overflow-y:auto;padding:12px 20px}
  .errlog-entry{padding:12px 14px;margin-bottom:8px;background:var(--bg);border:1px solid var(--border);border-left:3px solid var(--red);border-radius:3px;font-family:var(--mono);font-size:11px;line-height:1.5}
  .errlog-entry .et-time{color:var(--text-xdim);font-size:9px;margin-bottom:4px}
  .errlog-entry .et-msg{color:var(--text);white-space:pre-wrap;word-break:break-word;max-height:200px;overflow-y:auto}
  .errlog-entry .et-copy{margin-top:8px;background:transparent;border:1px solid var(--border);color:var(--text-dim);border-radius:2px;padding:4px 10px;font-family:var(--mono);font-size:9px;font-weight:700;cursor:pointer;letter-spacing:.08em}
  .errlog-entry .et-copy:hover{color:var(--cyan);border-color:var(--cyan)}
  .errlog-empty{padding:40px 20px;text-align:center;color:var(--text-dim);font-family:var(--mono);font-size:11px}

  /* Footer */
  .footer{padding:16px 28px;border-top:1px solid var(--border);display:flex;align-items:center;gap:16px;font-family:var(--mono);font-size:10px;color:var(--text-xdim);letter-spacing:.06em}
  .fsep{flex:1}

  /* Persistent Info Bar */
  .info-bar{border-bottom:1px solid var(--border);background:var(--bg-card);overflow:hidden;transition:max-height .25s ease}
  .info-bar.collapsed{max-height:0;border-bottom:none}
  .info-bar-toggle{display:flex;align-items:center;gap:8px;padding:8px 28px;background:var(--bg);border-bottom:1px solid var(--border);cursor:pointer;user-select:none;transition:all .15s}
  .info-bar-toggle:hover{background:var(--bg-hover)}
  .info-bar-toggle span{font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--text-dim)}
  .info-bar-toggle .arrow{color:var(--cyan);font-size:12px;transition:transform .2s}
  .info-bar-toggle.open .arrow{transform:rotate(90deg)}
  .info-bar-inner{display:grid;grid-template-columns:1fr 1fr;gap:0;min-height:0}
  @media(max-width:800px){.info-bar-inner{grid-template-columns:1fr}}
  .info-bar-col{padding:16px 28px}
  .info-bar-col:first-child{border-right:1px solid var(--border)}
  @media(max-width:800px){.info-bar-col:first-child{border-right:none;border-bottom:1px solid var(--border)}}
  .info-bar-col h3{font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--cyan);margin-bottom:10px}
  .info-bar-steps{display:grid;grid-template-columns:auto 1fr;gap:3px 10px;font-size:12px;color:var(--text-dim);line-height:1.7}
  .info-bar-steps .sn{color:var(--cyan);font-family:var(--mono);font-weight:700;font-size:11px}
  .info-bar-steps strong{color:var(--text)}
  .prompt-pill{display:flex;align-items:center;gap:8px;padding:8px 12px;background:var(--bg);border:1px solid var(--border);border-radius:3px;margin-bottom:6px;cursor:pointer;transition:all .15s;overflow:hidden}
  .prompt-pill:hover{border-color:var(--cyan);background:var(--bg-hover)}
  .prompt-pill .pp-label{font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:.06em;color:var(--cyan);white-space:nowrap;flex-shrink:0}
  .prompt-pill .pp-preview{font-family:var(--mono);font-size:10px;color:var(--text-xdim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
  .prompt-pill .pp-copy{font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:.1em;color:var(--text-dim);background:var(--bg-hover);border:1px solid var(--border);border-radius:2px;padding:3px 8px;flex-shrink:0;cursor:pointer;transition:all .15s;text-transform:uppercase}
  .prompt-pill .pp-copy:hover{color:var(--cyan);border-color:var(--cyan)}
  .prompt-pill .pp-copy.copied{color:var(--green);border-color:rgba(34,197,94,.4);background:var(--green-dim)}
  .prompt-popup{display:none;position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:200;background:var(--bg-card);border:1px solid var(--border-hi);border-radius:6px;padding:24px;max-width:600px;width:90vw;max-height:70vh;overflow-y:auto;box-shadow:0 20px 60px rgba(0,0,0,.5)}
  .prompt-popup.show{display:block}
  .prompt-overlay{display:none;position:fixed;inset:0;z-index:199;background:rgba(0,0,0,.5);backdrop-filter:blur(3px)}
  .prompt-overlay.show{display:block}
  .prompt-popup h4{font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--cyan);margin-bottom:12px}
  .prompt-popup pre{font-family:var(--mono);font-size:12px;color:var(--text);line-height:1.8;white-space:pre-wrap;word-break:break-all;margin-bottom:16px}
  .prompt-popup .pp-actions{display:flex;gap:8px;justify-content:flex-end}

  /* Guide section */
  .guide-section{padding:24px 28px 48px;max-width:800px}
  .guide-section h2{font-family:var(--mono);font-size:14px;color:var(--cyan);letter-spacing:.1em;text-transform:uppercase;margin:32px 0 16px}
  .guide-section h2:first-child{margin-top:0}
  .guide-section p{color:var(--text-dim);margin-bottom:12px;line-height:1.7}
  .copy-block{position:relative;background:var(--bg-hover);border:1px solid var(--border);border-radius:3px;padding:16px 50px 16px 18px;margin:12px 0 20px;font-family:var(--mono);font-size:12px;color:var(--cyan);line-height:1.8;white-space:pre-wrap;word-break:break-all}
  .copy-block .copy-btn{position:absolute;top:8px;right:8px;padding:5px 12px;background:var(--bg-hover);border:1px solid var(--border);border-radius:2px;color:var(--text-dim);font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;cursor:pointer;transition:all .15s}
  .copy-block .copy-btn:hover{background:var(--cyan-dim);color:var(--cyan);border-color:rgba(0,229,204,.3)}
  .copy-block .copy-btn.copied{background:var(--green-dim);color:var(--green);border-color:rgba(34,197,94,.3)}
  .guide-section .highlight{background:var(--cyan-dim);border:1px solid rgba(0,229,204,.2);border-radius:3px;padding:16px 20px;margin:12px 0 20px}
  .guide-section .highlight p{color:var(--cyan);margin:0}
  .ide-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px;margin:12px 0 20px}
  .ide-link{display:flex;align-items:center;gap:10px;padding:12px 16px;background:var(--bg-card);border:1px solid var(--border);border-radius:3px;color:var(--text);font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.06em;text-decoration:none;transition:all .15s;cursor:pointer}
  .ide-link:hover{border-color:var(--cyan);background:var(--bg-hover);color:var(--cyan)}
  .ide-dot{width:8px;height:8px;border-radius:50%}
  .faq-item{margin:16px 0;padding:16px 20px;background:var(--bg-card);border:1px solid var(--border);border-radius:3px}
  .faq-q{font-family:var(--mono);font-size:12px;font-weight:700;color:var(--text);letter-spacing:.04em;margin-bottom:8px}
  .faq-a{font-size:13px;color:var(--text-dim);line-height:1.7}
</style>
</head>
<body>
<header class="header">
  <div class="logo"><span class="logo-b">[</span>VS<span class="logo-b">]</span> VIBESTACK</div>
  <div id="dkBadge" class="docker-badge stopped"><div class="docker-dot"></div><span id="dkText">CHECKING...</span></div>
  <div class="header-sep"></div>
  <button id="themeBtn" class="theme-toggle" onclick="toggleTheme()" title="Toggle light/dark mode">&#9728;</button>
  <div id="vtag" class="vtag">v--</div>
</header>

<nav class="tabs">
  <div class="tab active" onclick="switchTab('projects')">Projects</div>
  <div class="tab" onclick="switchTab('guide')">Guide</div>
  <div class="tab" onclick="switchTab('tools')">Tools</div>
  <div class="tab" onclick="switchTab('docker')">Docker</div>
  <div class="tab" onclick="switchTab('recovery')">Recovery</div>
</nav>

<div id="infoToggle" class="info-bar-toggle open" onclick="toggleInfoBar()">
  <span class="arrow">&#9654;</span>
  <span>Quick Start &amp; Prompts</span>
</div>
<div id="infoBar" class="info-bar">
  <div class="info-bar-inner">
    <div class="info-bar-col">
      <h3>&#128640; Every Session</h3>
      <div class="info-bar-steps">
        <span class="sn">1.</span><span>Click <strong>START DB</strong> on your project card</span>
        <span class="sn">2.</span><span>Click <strong>START APP</strong> to launch dev server</span>
        <span class="sn">3.</span><span>Open project in <strong>Dyad / Cursor / VS Code</strong></span>
        <span class="sn">4.</span><span>Click <strong>OPEN APP</strong> to see it in browser</span>
        <span class="sn">5.</span><span>When done: <strong>SYNC</strong> then <strong>STOP DB</strong></span>
      </div>
    </div>
    <div class="info-bar-col">
      <h3>&#128203; Copy Prompts</h3>
      <div class="prompt-pill" onclick="showPrompt('plan')">
        <span class="pp-label">PLAN</span>
        <span class="pp-preview">Read PROMPT.md and AI_RULES.md. Planning only, no code...</span>
        <span class="pp-copy" onclick="event.stopPropagation();copyPrompt('plan',this)">COPY</span>
      </div>
      <div class="prompt-pill" onclick="showPrompt('phase1')">
        <span class="pp-label">BUILD</span>
        <span class="pp-preview">Begin Phase 1 from MASTERPLAN.md. Max 5 files...</span>
        <span class="pp-copy" onclick="event.stopPropagation();copyPrompt('phase1',this)">COPY</span>
      </div>
      <div class="prompt-pill" onclick="showPrompt('cont')">
        <span class="pp-label">CONTINUE</span>
        <span class="pp-preview">Continue from where you left off. Next phase...</span>
        <span class="pp-copy" onclick="event.stopPropagation();copyPrompt('cont',this)">COPY</span>
      </div>
      <div class="prompt-pill" onclick="showPrompt('fix')">
        <span class="pp-label">FIX</span>
        <span class="pp-preview">Stop building. Check for errors, fix what's broken...</span>
        <span class="pp-copy" onclick="event.stopPropagation();copyPrompt('fix',this)">COPY</span>
      </div>
    </div>
  </div>
</div>
<div id="promptOverlay" class="prompt-overlay" onclick="closePrompt()"></div>
<div id="promptPopup" class="prompt-popup">
  <h4 id="promptPopupTitle"></h4>
  <pre id="promptPopupText"></pre>
  <div class="pp-actions">
    <button class="btn btn-ghost" onclick="closePrompt()">CLOSE</button>
    <button class="btn btn-studio" id="promptPopupCopy" onclick="copyPromptFromPopup()">COPY TO CLIPBOARD</button>
  </div>
</div>

<!-- PROJECTS TAB -->
<div id="tab-projects" class="tab-panel active">
  <div id="dkBanner" class="banner">&#9888; DOCKER IS NOT RUNNING -- Start Docker Desktop, then click Refresh.</div>
  <div class="toolbar">
    <span class="tlabel">PROJECTS</span>
    <span id="tcount" class="tcount"></span>
    <div class="tsep"></div>
    <button class="btn-refresh" onclick="doRefresh()" title="Refresh project status">&#8635; REFRESH</button>
    <button id="btnAfk" class="btn-afk" onclick="afkRecovery()" title="Restart your 3 most recently-used stopped projects">&#9889; AFK RECOVERY</button>
    <button class="btn-new" onclick="createProject()">+ NEW PROJECT</button>
  </div>
  <div id="bulkBar" class="bulk-bar">
    <span id="blabel" class="blabel">0 SELECTED</span>
    <div class="bsep"></div>
    <button class="btn btn-desel" onclick="deselectAll()">&#10005; DESELECT ALL</button>
    <button id="btnSS" class="btn btn-ssel" onclick="startSelected()">&#9654; START SELECTED</button>
  </div>
  <div id="grid" class="grid"></div>
</div>

<!-- GUIDE TAB -->
<div id="tab-guide" class="tab-panel">
  <div class="guide-section">

    <h2>&#128640; YOUR DEVELOPMENT WORKFLOW</h2>
    <p>Follow these steps every time you work on a project:</p>

    <div class="info-box">
      <strong>EVERY SESSION:</strong><br><br>
      <strong>1.</strong> Open the Dashboard (Desktop shortcut)<br>
      <strong>2.</strong> Click <strong>START DB</strong> on your project card (if stopped)<br>
      <strong>3.</strong> Click <strong>START APP</strong> -- this opens a terminal running your dev server + migration watcher<br>
      <strong>4.</strong> Open your project in Dyad/Cursor/VS Code and start coding with AI<br>
      <strong>5.</strong> Your app runs at its own unique URL (shown on the project card as APP port) -- click it to open<br>
      <strong>6.</strong> When done, click <strong>SYNC</strong> to save Athena memory, then close the terminal
    </div>

    <div class="warn-box" style="background:var(--yellow-dim);border-color:rgba(245,158,11,.4);color:var(--yellow)">
      <strong>&#9888; WHY START APP MATTERS:</strong><br><br>
      When you click <strong>START APP</strong>, it runs two things:<br>
      - Your app at its own unique URL (each project gets a different port -- shown on the card)<br>
      - The <strong>migration watcher</strong> -- auto-pushes database changes the AI writes<br><br>
      <strong>Without START APP running, the AI can write migration files but they WON'T be applied to the database.</strong><br><br>
      If you forgot to start the app, you can also click <strong>PUSH DB</strong> on the card to manually push all pending migrations.
    </div>

    <h2>&#127937; Step 1: Planning Prompt (DO THIS FIRST)</h2>
    <p>After creating a project and opening it in your IDE, copy and paste this FIRST. This only plans -- no coding yet:</p>
    <div class="copy-block" id="cpPrompt">Read PROMPT.md and AI_RULES.md completely. Do NOT write any application code yet.

Your only job right now is PLANNING:
1. Write the master implementation plan to ATHENA_EXPORT/MASTERPLAN.md
2. Break it into small phases (3-5 files per phase max)
3. Update ATHENA_EXPORT/PROGRESS.md, NEXT_STEPS.md, and DECISIONS.md
4. List Phase 1 scope clearly at the end

Do NOT touch any files in app/, components/, or lib/. Planning only.<button class="copy-btn" onclick="copyBlock('cpPrompt')">COPY</button></div>

    <div class="highlight"><p><strong>WHY PLAN FIRST:</strong> If you let the AI plan AND code in one prompt, it tries to do too much, times out, and breaks things. Plan first. Review the plan. THEN start Phase 1.</p></div>

    <h2>&#128295; Step 2: Start Phase 1 (AFTER reviewing the plan)</h2>
    <p>Once the AI has written the master plan and you've reviewed it, paste this to begin building:</p>
    <div class="copy-block" id="cpPhase1">Begin Phase 1 from ATHENA_EXPORT/MASTERPLAN.md.
Build only what is listed in Phase 1 -- nothing else.
Maximum 5 files per pass. Stop after Phase 1 and confirm it works.
Update ATHENA_EXPORT/PROGRESS.md when done.<button class="copy-btn" onclick="copyBlock('cpPhase1')">COPY</button></div>

    <div class="highlight"><p><strong>TIP:</strong> After Phase 1 works, use the CONTINUE prompt below. Small phases = fewer bugs.</p></div>

    <h2>&#128260; Step 3: Continue Building</h2>
    <p>Use this after each phase completes. It picks up where the AI left off:</p>
    <div class="copy-block" id="cpCont">Continue building from where you left off.
Read ATHENA_EXPORT/PROGRESS.md and ATHENA_EXPORT/NEXT_STEPS.md to see what was completed and what comes next.
Build the next phase from ATHENA_EXPORT/MASTERPLAN.md.
Maximum 5 files per pass. Update PROGRESS.md when done.<button class="copy-btn" onclick="copyBlock('cpCont')">COPY</button></div>

    <h2>&#128027; Step 4: Fix Errors</h2>
    <p>Use this when something breaks. Stops the AI from building and focuses on fixing:</p>
    <div class="copy-block" id="cpFix">Stop building new features. Read ATHENA_EXPORT/PROGRESS.md to see current state.
Check the app for errors:
1. Look at the browser console and terminal for any error messages
2. Test each existing page/route to make sure it loads
3. Check that database queries work (no missing tables or columns)
4. Fix any broken imports, missing files, or CSS issues
5. Update PROGRESS.md with what you fixed

Do NOT add new features. Only fix what is broken.<button class="copy-btn" onclick="copyBlock('cpFix')">COPY</button></div>

    <h2>&#128187; AI Coding IDEs</h2>
    <p>Open your project folder in any of these tools, then paste the prompt above:</p>
    <div class="ide-grid">
      <a class="ide-link" href="https://dyad.sh" target="_blank"><div class="ide-dot" style="background:#00e5cc"></div>Dyad (Recommended)</a>
      <a class="ide-link" href="https://cursor.com" target="_blank"><div class="ide-dot" style="background:#a855f7"></div>Cursor</a>
      <a class="ide-link" href="https://codeium.com/windsurf" target="_blank"><div class="ide-dot" style="background:#3b82f6"></div>Windsurf</a>
      <a class="ide-link" href="https://www.trae.ai" target="_blank"><div class="ide-dot" style="background:#f59e0b"></div>Trae</a>
      <a class="ide-link" href="https://code.visualstudio.com" target="_blank"><div class="ide-dot" style="background:#22c55e"></div>VS Code + Cline/Roo</a>
      <a class="ide-link" href="https://zed.dev" target="_blank"><div class="ide-dot" style="background:#ef4444"></div>Zed</a>
    </div>

    <div class="warn-box" style="background:var(--yellow-dim);border-color:rgba(245,158,11,.4);color:var(--yellow)">
      <strong>&#9888; DYAD USERS -- IMPORTANT:</strong><br><br>
      When importing your project into Dyad, <strong>UNCHECK "Copy to the dyad-apps folder"</strong>.<br><br>
      If you leave it checked, Dyad creates a duplicate copy in a different folder. Your database, dashboard, ports, and Athena memory will NOT connect to the copy. Everything breaks silently.<br><br>
      Always import directly from <strong>C:\VIBESTACK\PROJECTS\YOUR-APP</strong> without copying.
    </div>

    <h2>&#128268; Common Commands</h2>
    <p>Copy and paste these into PowerShell when needed:</p>

    <p style="color:var(--text);font-weight:600;margin-top:20px">Open PowerShell as Admin</p>
    <p>Right-click Start button &gt; Terminal (Admin). Then run:</p>
    <div class="copy-block" id="cpAdmin">Set-ExecutionPolicy -Scope Process Bypass<button class="copy-btn" onclick="copyBlock('cpAdmin')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">Check Docker Status</p>
    <div class="copy-block" id="cpDocker">docker info<button class="copy-btn" onclick="copyBlock('cpDocker')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">See All Running Containers</p>
    <div class="copy-block" id="cpPs">docker ps -a --format "{{.Names}} | {{.Status}}"<button class="copy-btn" onclick="copyBlock('cpPs')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">Stop All Running Containers</p>
    <div class="copy-block" id="cpStopAll">docker stop $(docker ps -q)<button class="copy-btn" onclick="copyBlock('cpStopAll')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">Check Your Project Ports</p>
    <div class="copy-block" id="cpPorts">Get-Content "C:\VIBESTACK\TOOLS\DATABASE\port-registry.json"<button class="copy-btn" onclick="copyBlock('cpPorts')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">Run the VIBESTACK Installer Again</p>
    <div class="copy-block" id="cpInstall">Set-ExecutionPolicy -Scope Process Bypass
&amp; "$HOME\Desktop\vibestack-installer13.ps1"<button class="copy-btn" onclick="copyBlock('cpInstall')">COPY</button></div>

    <p style="color:var(--text);font-weight:600">Patch VIBESTACK (Update Without Full Reinstall)</p>
    <div class="copy-block" id="cpPatch">Set-ExecutionPolicy -Scope Process Bypass
&amp; "C:\VIBESTACK\CORE\vibestack-installer.ps1" -PatchOnly<button class="copy-btn" onclick="copyBlock('cpPatch')">COPY</button></div>

    <h2>&#10067; FAQ</h2>

    <div class="faq-item">
      <div class="faq-q">Dyad says "Copy to the dyad-apps folder" -- should I check this?</div>
      <div class="faq-a"><strong>NO. Always uncheck it.</strong> If checked, Dyad duplicates your project to a different folder. Your database, dashboard, Athena memory, and port assignments all point to <strong>C:\VIBESTACK\PROJECTS\YOUR-APP</strong>. The Dyad copy won't have any of those connections. Import directly from the VIBESTACK folder without copying.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">The AI wrote database changes but nothing happened in the app.</div>
      <div class="faq-a">You need to click <strong>START APP</strong> on the project card in the Dashboard. This runs the dev server AND the migration watcher. Without it, SQL files the AI writes to supabase/migrations/ just sit there unapplied. If START APP is already running, check the terminal window for errors. You can also click <strong>PUSH DB</strong> on the project card to manually force all migrations to apply.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">My AI stopped working after I went AFK. What happened?</div>
      <div class="faq-a">Docker pauses your databases after 60 minutes of inactivity to save resources. Click the <strong>AFK RECOVERY</strong> button on the Projects tab to restart your most recent databases. Or double-click <strong>VIBESTACK-START-DBS.cmd</strong> in the VIBESTACK folder.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">The AI is generating too many files at once and breaking things.</div>
      <div class="faq-a">Tell the AI: <em>"Read AI_RULES.md again and follow the rules. Build no more than 5-7 files per pass."</em> The rules file explicitly limits this, but some AI models get excited and ignore it.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">I see a ghost project folder I did not create.</div>
      <div class="faq-a">Supabase stores state in Docker volumes. If you deleted a project folder but not its Docker data, it can reappear. Go to the <strong>Recovery</strong> tab and run the Nuclear Wipe, then delete the ghost folder manually from <strong>C:\VIBESTACK\PROJECTS\</strong>.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Port already in use error when creating a project.</div>
      <div class="faq-a">Another project is using those ports. Either stop the other project first (STOP DB on the Projects tab), or run the Nuclear Wipe from the Recovery tab to clear everything and start fresh.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Docker Desktop says "WSL error" or won't start.</div>
      <div class="faq-a">Open PowerShell as Admin and run: <strong>wsl --update</strong>. Then restart Docker Desktop. If that does not work, restart your computer.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">How much does this cost?</div>
      <div class="faq-a">Everything local is free. Docker Desktop, Supabase, Node.js, Git, VS Code -- all free. The only cost is your AI API. NanoGPT runs about $8/month for 60,000+ API calls. Total: ~$8/month for unlimited local app development.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Can I deploy my app to production?</div>
      <div class="faq-a">Yes. Your app is a standard Next.js + Supabase app. When ready, push to GitHub, connect to Vercel (frontend) and Supabase Cloud (database). The transition from local to production is straightforward.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">What is Athena?</div>
      <div class="faq-a">Athena is VIBESTACK's AI memory system. It stores your project's plan, progress, decisions, and next steps in markdown files inside <strong>ATHENA_EXPORT/</strong>. This prevents the AI from forgetting what it built between sessions. Click the <strong>SYNC</strong> button on any project card to save its memory. Athena also auto-syncs whenever you stop a database from the dashboard.</div>
    </div>

    <h2>&#128218; Best Practices</h2>

    <div class="faq-item">
      <div class="faq-q">Build incrementally, not all at once</div>
      <div class="faq-a">The #1 cause of broken projects is asking the AI to generate 20+ files at once. Build in phases: database schema first, then one route, test it, then continue. The AI_RULES.md enforces this, but you need to hold the AI to it.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Never switch to yarn or bun</div>
      <div class="faq-a">VIBESTACK works with npm and pnpm (Dyad uses pnpm automatically). Never let the AI run yarn or bun. If you need to install something, use <strong>npm install</strong>.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Keep Docker Desktop running while you work</div>
      <div class="faq-a">Your database lives in Docker. If Docker is off, your app cannot read or write data. Keep the whale icon running in your taskbar while developing.</div>
    </div>

    <div class="faq-item">
      <div class="faq-q">Sync Athena after every milestone</div>
      <div class="faq-a">After major features or at the end of a session, click the <strong>SYNC</strong> button on the project card in the Dashboard. This saves the AI's memory so it can pick up where it left off next time. Athena also auto-syncs whenever you stop a database, so just clicking STOP is enough.</div>
    </div>

  </div>
</div>

<!-- TOOLS TAB (original) -->
<div id="tab-tools" class="tab-panel">
  <div class="toolbar">
    <span class="tlabel">INSTALLED TOOLS</span>
    <div class="tsep"></div>
    <button class="btn-refresh" onclick="toolsLoaded=false;loadTools()">&#8635; REFRESH</button>
  </div>
  <div class="tools-section">
    <table class="tools-table" id="toolsTable">
      <thead><tr><th>Tool</th><th>Version</th><th>Status</th></tr></thead>
      <tbody id="toolsBody"><tr><td colspan="3" style="color:var(--text-xdim)">Click Refresh to check tools...</td></tr></tbody>
    </table>
  </div>
</div>

<!-- DOCKER TAB -->
<div id="tab-docker" class="tab-panel">
  <div class="toolbar">
    <span class="tlabel">DOCKER MANAGEMENT</span>
    <div class="tsep"></div>
    <button class="btn-refresh" onclick="loadDocker()">&#8635; REFRESH</button>
  </div>
  <div class="tools-section">

    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px;margin-bottom:32px">
      <div id="dkStatCard" class="faq-item" style="margin:0;text-align:center">
        <div class="faq-q" id="dkStatLabel">DOCKER STATUS</div>
        <div id="dkStatVal" style="font-size:18px;margin-top:8px;color:var(--text-dim)">Checking...</div>
      </div>
      <div class="faq-item" style="margin:0;text-align:center">
        <div class="faq-q">CONTAINERS</div>
        <div id="dkContCount" style="font-size:18px;margin-top:8px;color:var(--cyan)">--</div>
      </div>
      <div class="faq-item" style="margin:0;text-align:center">
        <div class="faq-q">VOLUMES</div>
        <div id="dkVolCount" style="font-size:18px;margin-top:8px;color:var(--cyan)">--</div>
      </div>
      <div class="faq-item" style="margin:0;text-align:center">
        <div class="faq-q">ORPHANS</div>
        <div id="dkOrphanCount" style="font-size:18px;margin-top:8px;color:var(--yellow)">--</div>
      </div>
    </div>

    <h3 style="font-family:var(--mono);font-size:12px;color:var(--cyan);letter-spacing:.1em;margin-bottom:12px">SUPABASE CONTAINERS</h3>
    <table class="tools-table" id="dkContTable">
      <thead><tr><th>Container</th><th>Status</th><th>Project</th></tr></thead>
      <tbody id="dkContBody"><tr><td colspan="3" style="color:var(--text-xdim)">Click Refresh...</td></tr></tbody>
    </table>

    <h3 style="font-family:var(--mono);font-size:12px;color:var(--cyan);letter-spacing:.1em;margin:32px 0 12px">SUPABASE VOLUMES</h3>
    <table class="tools-table" id="dkVolTable">
      <thead><tr><th>Volume</th><th>Project</th><th>Status</th></tr></thead>
      <tbody id="dkVolBody"><tr><td colspan="3" style="color:var(--text-xdim)">Click Refresh...</td></tr></tbody>
    </table>

    <div id="orphanSection" style="display:none;margin-top:32px">
      <div class="warn-box" style="background:var(--yellow-dim);border-color:rgba(245,158,11,.4);color:var(--yellow)">
        <strong>&#9888; ORPHANED DOCKER RESOURCES FOUND</strong><br><br>
        These containers or volumes belong to projects that no longer exist in C:\VIBESTACK\PROJECTS\. They are wasting disk space and can cause ghost folder issues.<br><br>
        <span id="orphanList"></span>
      </div>
      <button class="btn-danger" style="margin-top:12px;background:var(--yellow-dim);color:var(--yellow);border-color:rgba(245,158,11,.5)" onclick="cleanOrphans()">&#128465; CLEAN ORPHANED RESOURCES</button>
      <div id="orphanStatus" class="wipe-status"></div>
    </div>

    <h3 style="font-family:var(--mono);font-size:12px;color:var(--cyan);letter-spacing:.1em;margin:32px 0 12px">QUICK ACTIONS</h3>
    <div style="display:flex;flex-wrap:wrap;gap:10px">
      <button class="btn btn-stop" onclick="stopAllContainers()">&#9632; STOP ALL CONTAINERS</button>
      <button class="btn btn-ghost" onclick="pruneNetworks()">PRUNE NETWORKS</button>
    </div>
  </div>
</div>

<!-- RECOVERY TAB -->
<div id="tab-recovery" class="tab-panel">
  <div class="recovery-section">
    <h2>&#128295; Recovery &amp; Reset</h2>
    <p>Use these tools when things go wrong -- ghost projects, port conflicts, or when you want to start completely fresh.</p>

    <div class="info-box">
      <strong>WHAT THE WIPE DOES:</strong><br>
      1. Stops all Docker containers<br>
      2. Removes all Supabase containers, volumes, and images<br>
      3. Resets port registry to starting position (55000)<br>
      4. Cleans up ghost project folders (empty ones only)<br><br>
      Your project CODE (app files, PROMPT.md, etc.) is NOT deleted.
    </div>

    <div class="warn-box">
      <strong>&#9888; WARNING:</strong> This cannot be undone. All database data will be lost.<br>
      Docker images are kept, so your next project starts in seconds.
    </div>

    <button class="btn-danger" id="btnWipe" onclick="confirmWipe()">NUCLEAR WIPE -- RESET TO ZERO</button>
    <div id="wipeStatus" class="wipe-status"></div>

    <h2 style="margin-top:40px">&#128221; Manual Reset Instructions</h2>
    <p>If the wipe button above does not work, do this:</p>
    <ol class="step-list">
      <li>Open <strong>C:\VIBESTACK\</strong> in File Explorer</li>
      <li>Double-click <strong>VIBESTACK-WIPE.cmd</strong></li>
      <li>Type <strong>WIPE</strong> and press Enter</li>
    </ol>
    <p style="color:var(--text-xdim);font-size:11px;margin-top:8px">The WIPE script stops Docker containers, removes all Supabase volumes, and resets the port registry in one shot. Your project code is not deleted.</p>

    <h2 style="margin-top:40px">&#128268; Full Reinstall</h2>
    <p>To completely reinstall VIBESTACK from scratch:</p>
    <ol class="step-list">
      <li>Run the Nuclear Wipe above</li>
      <li>Delete <strong>C:\VIBESTACK</strong> folder entirely</li>
      <li>Run the installer again from your Desktop</li>
    </ol>
  </div>
</div>

<footer class="footer">VIBESTACK DASHBOARD &mdash; http://localhost:9999<div class="fsep"></div><span id="ftime">&mdash;</span></footer>
<div class="tc" id="tc"></div>
<button id="errLogBtn" class="errlog-btn" onclick="openErrLog()"></button>
<div id="errLogModal" class="errlog-modal" onclick="if(event.target===this)closeErrLog()">
  <div class="errlog-box">
    <div class="errlog-head">
      <h3>&#9888; ERROR LOG</h3>
      <button class="btn btn-ghost" onclick="clearErrLog()">CLEAR</button>
      <button class="btn btn-ghost" onclick="closeErrLog()">CLOSE</button>
    </div>
    <div id="errLogBody" class="errlog-body"></div>
  </div>
</div>

<script>
let S={docker:null,version:'--',projects:[],loading:{},selected:new Set()};
let toolsLoaded=false;

const PROMPTS={
  plan:`Read PROMPT.md and AI_RULES.md completely. Do NOT write any application code yet.

Your only job right now is PLANNING:
1. Write the master implementation plan to ATHENA_EXPORT/MASTERPLAN.md
2. Break it into small phases (3-5 files per phase max)
3. Update ATHENA_EXPORT/PROGRESS.md, NEXT_STEPS.md, and DECISIONS.md
4. List Phase 1 scope clearly at the end

Do NOT touch any files in app/, components/, or lib/. Planning only.`,
  phase1:`Begin Phase 1 from ATHENA_EXPORT/MASTERPLAN.md.
Build only what is listed in Phase 1 -- nothing else.
Maximum 5 files per pass. Stop after Phase 1 and confirm it works.
Update ATHENA_EXPORT/PROGRESS.md when done.`,
  cont:`Continue building from where you left off.
Read ATHENA_EXPORT/PROGRESS.md and ATHENA_EXPORT/NEXT_STEPS.md to see what was completed and what comes next.
Build the next phase from ATHENA_EXPORT/MASTERPLAN.md.
Maximum 5 files per pass. Update PROGRESS.md when done.`,
  fix:`Stop building new features. Read ATHENA_EXPORT/PROGRESS.md to see current state.
Check the app for errors:
1. Look at the browser console and terminal for any error messages
2. Test each existing page/route to make sure it loads
3. Check that database queries work (no missing tables or columns)
4. Fix any broken imports, missing files, or CSS issues
5. Update PROGRESS.md with what you fixed

Do NOT add new features. Only fix what is broken.`
};
const PROMPT_TITLES={plan:'Step 1: Planning Prompt',phase1:'Step 2: Start Phase 1',cont:'Continue Building',fix:'Fix Errors & Bugs'};
let _currentPromptKey=null;

function toggleTheme(){
  const html=document.documentElement;
  const isDark=html.getAttribute('data-theme')!=='light';
  html.setAttribute('data-theme',isDark?'light':'dark');
  const btn=document.getElementById('themeBtn');
  btn.innerHTML=isDark?'&#9789;':'&#9728;';
  try{localStorage.setItem('vs-theme',isDark?'light':'dark');}catch(e){}
}
function loadTheme(){
  try{
    const saved=localStorage.getItem('vs-theme');
    if(saved==='light'){
      document.documentElement.setAttribute('data-theme','light');
      document.getElementById('themeBtn').innerHTML='&#9789;';
    }
  }catch(e){}
}

function toggleInfoBar(){
  const bar=document.getElementById('infoBar');
  const tog=document.getElementById('infoToggle');
  const open=!bar.classList.contains('collapsed');
  bar.classList.toggle('collapsed',open);
  tog.classList.toggle('open',!open);
  try{localStorage.setItem('vs-infobar',open?'collapsed':'open');}catch(e){}
}
function loadInfoBarState(){
  try{
    const saved=localStorage.getItem('vs-infobar');
    if(saved==='collapsed'){
      document.getElementById('infoBar').classList.add('collapsed');
      document.getElementById('infoToggle').classList.remove('open');
    }
  }catch(e){}
}

function showPrompt(key){
  _currentPromptKey=key;
  document.getElementById('promptPopupTitle').textContent=PROMPT_TITLES[key]||key;
  document.getElementById('promptPopupText').textContent=PROMPTS[key]||'';
  document.getElementById('promptPopup').classList.add('show');
  document.getElementById('promptOverlay').classList.add('show');
}
function closePrompt(){
  document.getElementById('promptPopup').classList.remove('show');
  document.getElementById('promptOverlay').classList.remove('show');
  _currentPromptKey=null;
}
function copyPrompt(key,btnEl){
  navigator.clipboard.writeText(PROMPTS[key]||'').then(()=>{
    if(btnEl){btnEl.textContent='COPIED!';btnEl.classList.add('copied');setTimeout(()=>{btnEl.textContent='COPY';btnEl.classList.remove('copied');},1500);}
    toast('ok','Copied to clipboard');
  }).catch(()=>toast('error','Could not copy'));
}
function copyPromptFromPopup(){
  if(!_currentPromptKey)return;
  const btn=document.getElementById('promptPopupCopy');
  navigator.clipboard.writeText(PROMPTS[_currentPromptKey]).then(()=>{
    btn.textContent='COPIED!';setTimeout(()=>{btn.textContent='COPY TO CLIPBOARD';},1500);
    toast('ok','Copied to clipboard');
  }).catch(()=>toast('error','Could not copy'));
}

async function api(m,url,b){
  const o={method:m,headers:{'Content-Type':'application/json'}};
  if(b)o.body=JSON.stringify(b);
  return (await fetch(url,o)).json();
}

function switchTab(name){
  document.querySelectorAll('.tab').forEach((t,i)=>t.classList.toggle('active',['projects','guide','tools','docker','recovery'][i]===name));
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.remove('active'));
  document.getElementById('tab-'+name).classList.add('active');
  if(name==='tools'&&!toolsLoaded)loadTools();
  if(name==='docker')loadDocker();
}

async function doRefresh(){
  const btn=document.querySelector('.btn-refresh');
  btn.classList.add('spinning');
  await fetchAll();
  setTimeout(()=>btn.classList.remove('spinning'),600);
}

async function fetchAll(){
  try{
    const[st,pr]=await Promise.all([api('GET','/api/status'),api('GET','/api/projects')]);
    S.docker=st.docker; S.version=st.version;
    const raw=pr.projects||[];
    const srt=(a,b)=>(new Date(b.lastModified||0))-(new Date(a.lastModified||0));
    S.projects=[...raw.filter(p=>p.status!=='running').sort(srt),...raw.filter(p=>p.status==='running').sort(srt)];
    const ns=new Set(S.projects.map(p=>p.name));
    for(const n of S.selected)if(!ns.has(n))S.selected.delete(n);
    render();
  }catch(e){console.warn(e);}
}

async function loadTools(){
  const body=document.getElementById('toolsBody');
  body.innerHTML='<tr><td colspan="3" style="color:var(--text-dim)">Checking tools...</td></tr>';
  try{
    const r=await api('GET','/api/dependencies');
    const rows=(r.tools||[]).map(t=>{
      const ver=t.version||'--';
      const cls=t.installed?'tool-ver':'tool-miss';
      const pill=t.installed?'<span class="pill-ok">OK</span>':'<span class="pill-miss">MISSING</span>';
      return '<tr><td class="tool-name">'+t.name+'</td><td class="'+cls+'">'+ver+'</td><td>'+pill+'</td></tr>';
    }).join('');
    body.innerHTML=rows||'<tr><td colspan="3">No tools found</td></tr>';
    toolsLoaded=true;
  }catch(e){body.innerHTML='<tr><td colspan="3" style="color:var(--red)">Error loading tools</td></tr>';}
}

async function startDb(name){
  if(S.loading[name])return;
  S.loading[name]='starting'; renderCard(name); toast('info','Starting '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/start');
    toast(r.success?'ok':'error',r.success?name+' started':(r.error||'Failed'));}
  catch{toast('error','Error starting '+name);}
  delete S.loading[name]; await fetchAll();
}
async function stopDb(name){
  if(S.loading[name])return;
  S.loading[name]='stopping'; renderCard(name); toast('info','Stopping '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/stop');
    toast(r.success?'ok':'error',r.success?name+' stopped':'Failed to stop '+name);}
  catch{toast('error','Error stopping '+name);}
  delete S.loading[name]; await fetchAll();
}
async function openStudio(name){
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/open-studio');
    toast(r.success?'ok':'error',r.success?'Opening Studio':(r.error||'Port not found'));}
  catch{toast('error','Could not open Studio');}
}
async function openDyad(name){
  try{await api('POST','/api/projects/'+encodeURIComponent(name)+'/open-dyad');toast('ok','Opening in Dyad');}
  catch{toast('error','Could not open Dyad');}
}
async function openVSCode(name){
  try{await api('POST','/api/projects/'+encodeURIComponent(name)+'/open-vscode');toast('ok','Opening in VS Code');}
  catch{toast('error','Could not open VS Code');}
}
async function openFolder(name){
  try{await api('POST','/api/projects/'+encodeURIComponent(name)+'/open-folder');toast('ok','Opening folder');}
  catch{toast('error','Could not open folder');}
}
async function startApp(name){
  toast('info','Starting dev server for '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/start-app');
    if(r.alreadyRunning){toast('ok','App already running on port '+r.devPort);await fetchAll();}
    else{toast(r.success?'ok':'error',r.success?name+' dev server launching...':'Failed to start app');
      if(r.success){setTimeout(()=>fetchAll(),5000);setTimeout(()=>fetchAll(),10000);setTimeout(()=>fetchAll(),18000);}}
  }catch{toast('error','Could not start app');}
}
async function pushDb(name){
  toast('info','Pushing migrations for '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/push-db');
    if(r.success){
      toast('ok','Migrations applied for '+name+(r.output?('\\n\\n'+r.output):''));
      await fetchAll();
    }else{
      toast('error','PUSH DB failed for '+name+'\\n\\n'+(r.error||'Unknown error'));
    }}
  catch(e){toast('error','Could not push migrations: '+(e.message||e));}
}
async function syncAthena(name){
  toast('info','Syncing Athena memory for '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/sync-athena');
    toast(r.success?'ok':'error',r.success?'Athena synced for '+name:(r.error||'Sync failed'));}
  catch{toast('error','Could not sync Athena');}
}
async function stopApp(name){
  toast('info','Stopping dev server for '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/stop-app');
    toast(r.success?'ok':'error',r.success?'Dev server stopped for '+name:'Failed to stop app');
    await fetchAll();}
  catch{toast('error','Could not stop app');}
}
async function deleteProject(name){
  if(!confirm('DELETE PROJECT: '+name+'\\n\\nThis will:\\n- Stop and remove all Docker containers\\n- Delete all Docker volumes (database data)\\n- Remove from port registry\\n- Delete the entire project folder\\n\\nThis cannot be undone. Are you sure?'))return;
  if(!confirm('FINAL CONFIRMATION\\n\\nType OK to delete '+name+' permanently.\\n\\n(Click OK to confirm)'))return;
  toast('info','Deleting '+name+'...');
  try{const r=await api('POST','/api/projects/'+encodeURIComponent(name)+'/delete');
    if(r.success){toast('ok',name+' deleted: '+(r.steps||[]).join(', '));await fetchAll();}
    else{toast('error','Delete failed: '+(r.error||'Unknown error'));}
  }catch(e){toast('error','Delete error: '+e.message);}
}
async function loadDocker(){
  const cb=document.getElementById('dkContBody');
  const vb=document.getElementById('dkVolBody');
  cb.innerHTML='<tr><td colspan="3" style="color:var(--text-dim)">Loading...</td></tr>';
  vb.innerHTML='<tr><td colspan="3" style="color:var(--text-dim)">Loading...</td></tr>';
  try{
    const r=await api('GET','/api/docker-info');
    // Status
    document.getElementById('dkStatVal').textContent=r.running?'RUNNING':'STOPPED';
    document.getElementById('dkStatVal').style.color=r.running?'var(--green)':'var(--red)';
    document.getElementById('dkContCount').textContent=r.containers?r.containers.length:'0';
    document.getElementById('dkVolCount').textContent=r.volumes?r.volumes.length:'0';
    document.getElementById('dkOrphanCount').textContent=r.orphanCount||'0';
    document.getElementById('dkOrphanCount').style.color=(r.orphanCount>0)?'var(--yellow)':'var(--green)';
    // Containers
    if(r.containers&&r.containers.length>0){
      cb.innerHTML=r.containers.map(c=>{
        const isUp=c.status&&(c.status.includes('Up')||c.status.includes('running'));
        const pill=isUp?'<span class="pill-ok">UP</span>':c.orphan?'<span class="pill-miss">ORPHAN</span>':'<span style="color:var(--text-dim)">Stopped</span>';
        const cls=c.orphan?' style="color:var(--yellow)"':'';
        return '<tr><td class="tool-name"'+cls+'>'+c.name+'</td><td>'+pill+'</td><td>'+(c.project||'--')+'</td></tr>';
      }).join('');
    }else{cb.innerHTML='<tr><td colspan="3" style="color:var(--text-xdim)">No Supabase containers found</td></tr>';}
    // Volumes
    if(r.volumes&&r.volumes.length>0){
      vb.innerHTML=r.volumes.map(v=>{
        const pill=v.orphan?'<span class="pill-miss">ORPHAN</span>':'<span class="pill-ok">OK</span>';
        const cls=v.orphan?' style="color:var(--yellow)"':'';
        return '<tr><td class="tool-name"'+cls+'>'+v.name+'</td><td>'+(v.project||'--')+'</td><td>'+pill+'</td></tr>';
      }).join('');
    }else{vb.innerHTML='<tr><td colspan="3" style="color:var(--text-xdim)">No Supabase volumes found</td></tr>';}
    // Orphans
    const os=document.getElementById('orphanSection');
    if(r.orphanCount>0){
      os.style.display='block';
      const items=[...(r.orphans.containers||[]),...(r.orphans.volumes||[])];
      document.getElementById('orphanList').innerHTML=items.map(n=>'<br>- '+n).join('');
    }else{os.style.display='none';}
  }catch(e){
    cb.innerHTML='<tr><td colspan="3" style="color:var(--red)">Error: '+e.message+'</td></tr>';
    vb.innerHTML='<tr><td colspan="3" style="color:var(--red)">Error</td></tr>';
  }
}
async function cleanOrphans(){
  if(!confirm('Clean all orphaned Docker resources?\\n\\nThis removes containers and volumes that do not belong to any existing project.'))return;
  const el=document.getElementById('orphanStatus');
  el.textContent='Cleaning...';
  try{
    const r=await api('POST','/api/docker/clean-orphans');
    el.textContent=r.success?'Done: '+(r.steps||[]).join(', '):'Failed: '+(r.error||'Unknown');
    toast(r.success?'ok':'error',r.success?'Orphans cleaned':'Cleanup failed');
    await loadDocker();
  }catch(e){el.textContent='Error: '+e.message;toast('error','Cleanup error');}
}
async function stopAllContainers(){
  if(!confirm('Stop ALL running Docker containers?'))return;
  toast('info','Stopping all containers...');
  try{
    const r=await api('POST','/api/docker/stop-all');
    toast(r.success?'ok':'error',r.success?'All containers stopped':'Failed: '+(r.error||''));
    await loadDocker(); await fetchAll();
  }catch(e){toast('error','Error: '+e.message);}
}
async function pruneNetworks(){
  try{
    const r=await api('POST','/api/docker/prune-networks');
    toast(r.success?'ok':'error',r.success?'Networks pruned':'Failed');
  }catch(e){toast('error','Error: '+e.message);}
}
async function createProject(){
  try{await api('POST','/api/create-project');
    toast('ok','Project wizard launched -- check your taskbar');
    toast('info','Dashboard will auto-refresh when the project is ready.');
    // Periodic refresh while project is being created (can take 1-10 min)
    const before=S.projects.length;
    let checks=0;
    const interval=setInterval(async()=>{
      checks++;
      await fetchAll();
      // Stop polling once a new project appears or after 5 minutes
      if(S.projects.length>before){clearInterval(interval);toast('ok','New project detected!');}
      if(checks>=20){clearInterval(interval);}
    },15000);
  }catch{toast('error','Could not launch wizard');}
}
function toggleSelect(name){
  if(S.selected.has(name))S.selected.delete(name);else S.selected.add(name);
  updateBulkBar(); renderCard(name);
}
function deselectAll(){const p=[...S.selected];S.selected.clear();updateBulkBar();p.forEach(n=>renderCard(n));}
function updateBulkBar(){
  const bar=document.getElementById('bulkBar'),lbl=document.getElementById('blabel'),c=S.selected.size;
  if(c>0){
    bar.className='bulk-bar on';
    const sc=[...S.selected].filter(n=>{const p=S.projects.find(x=>x.name===n);return p&&p.status!=='running';}).length;
    lbl.textContent=c+' SELECTED'+(sc>0?' | '+sc+' STOPPED':'');
    document.getElementById('btnSS').disabled=sc===0;
  }else{bar.className='bulk-bar';}
}
async function startSelected(){
  const ts=[...S.selected].filter(n=>{const p=S.projects.find(x=>x.name===n);return p&&p.status!=='running'&&!S.loading[n];});
  if(!ts.length)return;
  toast('info','Starting '+ts.length+' database(s)...');
  deselectAll(); ts.forEach(n=>S.loading[n]='starting'); render();
  const res=await Promise.all(ts.map(n=>api('POST','/api/projects/'+encodeURIComponent(n)+'/start').then(r=>({n,ok:r.success})).catch(()=>({n,ok:false}))));
  res.forEach(r=>delete S.loading[r.n]);
  const ok=res.filter(r=>r.ok).length,fail=res.filter(r=>!r.ok).length;
  if(ok)toast('ok',ok+' database(s) started');
  if(fail)toast('error',fail+' failed to start');
  await fetchAll();
}
async function afkRecovery(){
  const st=S.projects.filter(p=>p.status!=='running'&&!S.loading[p.name]).slice(0,3);
  if(!st.length){toast('info','All databases are already running');return;}
  toast('info','AFK Recovery: starting '+st.length+' project(s)...');
  st.forEach(p=>S.loading[p.name]='starting'); render();
  const res=await Promise.all(st.map(p=>api('POST','/api/projects/'+encodeURIComponent(p.name)+'/start').then(r=>({n:p.name,ok:r.success})).catch(()=>({n:p.name,ok:false}))));
  res.forEach(r=>delete S.loading[r.n]);
  const ok=res.filter(r=>r.ok).length,fail=res.filter(r=>!r.ok).length;
  if(ok)toast('ok',ok+' database(s) recovered');
  if(fail)toast('error',fail+' failed - try START-APP.cmd in project folder');
  await fetchAll();
}
async function confirmWipe(){
  if(!confirm('NUCLEAR WIPE\\n\\nThis will delete ALL databases, volumes, and reset ports.\\nYour project code is NOT deleted.\\n\\nAre you sure?'))return;
  const el=document.getElementById('wipeStatus');
  const btn=document.getElementById('btnWipe');
  btn.disabled=true; btn.textContent='WIPING...';
  el.textContent='Starting wipe...';
  try{
    const r=await api('POST','/api/wipe',{confirm:'WIPE'});
    if(r.success){
      el.textContent='WIPE COMPLETE:\\n'+(r.steps||[]).join('\\n')+'\\n\\nReady for fresh start. Click + NEW PROJECT.';
      toast('ok','Wipe complete');
      await fetchAll();
    }else{
      el.textContent='WIPE FAILED: '+(r.error||'Unknown error')+'\\n'+(r.steps||[]).join('\\n');
      toast('error','Wipe failed');
    }
  }catch(e){el.textContent='Error: '+e.message;toast('error','Wipe error');}
  btn.disabled=false; btn.textContent='NUCLEAR WIPE -- RESET TO ZERO';
}

function render(){
  const b=document.getElementById('dkBadge');
  b.className='docker-badge '+(S.docker?'running':'stopped');
  document.getElementById('dkText').textContent=S.docker?'DOCKER RUNNING':'DOCKER STOPPED';
  document.getElementById('vtag').textContent='v'+S.version;
  document.getElementById('dkBanner').className='banner '+(S.docker?'':'on');
  const cnt=S.projects.length,stopped=S.projects.filter(p=>p.status!=='running'&&!S.loading[p.name]).length;
  document.getElementById('tcount').textContent=cnt?'('+cnt+')':'';
  const ba=document.getElementById('btnAfk');
  ba.style.display=(stopped>0&&S.docker)?'inline-flex':'none';
  const grid=document.getElementById('grid');
  if(!cnt){
    grid.innerHTML='<div class="empty"><div class="empty-t">NO PROJECTS YET</div><div class="empty-s">Click + NEW PROJECT to create your first app</div><button class="btn btn-studio" onclick="createProject()">+ CREATE FIRST PROJECT</button></div>';
  }else{grid.innerHTML=S.projects.map(p=>chtml(p)).join('');}
  const now=new Date(),pad=n=>String(n).padStart(2,'0');
  document.getElementById('ftime').textContent='Last refresh: '+pad(now.getHours())+':'+pad(now.getMinutes())+':'+pad(now.getSeconds());
}
function renderCard(name){
  const p=S.projects.find(x=>x.name===name); if(!p)return;
  const el=document.querySelector('[data-p="'+CSS.escape(name)+'"]'); if(!el)return;
  el.outerHTML=chtml(p);
}
function chtml(p){
  const lf=S.loading[p.name],sel=S.selected.has(p.name);
  const dbr=p.status==='running',ar=p.appStatus==='running',do2=p.status==='docker-offline';
  const ports=p.ports||{};
  // Card border-top color class
  const cc=do2?'offline':lf?'loading':(dbr&&ar)?'allup':dbr?'dbonly':'stopped';
  // Port display
  const pv=v=>v?'<span class="pval">:'+v+'</span>':'<span class="pval n">&mdash;</span>';
  const appUrl=ports.devPort?'http://localhost:'+ports.devPort:null;
  const appLink=appUrl?'<a href="'+appUrl+'" target="_blank" style="color:var(--cyan);text-decoration:none;font-family:var(--mono);font-size:12px;font-weight:700">:'+ports.devPort+'</a>':'<span class="pval n">&mdash;</span>';
  const mod=p.lastModified?'MODIFIED '+new Date(p.lastModified).toLocaleString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  // DB service row
  const dbLoading=lf&&(lf==='starting'||lf==='stopping');
  const dbPill=dbLoading?'<div class="svc-pill load"><div class="pd"></div>'+(lf==='starting'?'STARTING':'STOPPING')+'</div>'
    :dbr?'<div class="svc-pill on"><div class="pd"></div>RUNNING</div>'
    :do2?'<div class="svc-pill off"><div class="pd"></div>OFFLINE</div>'
    :'<div class="svc-pill off"><div class="pd"></div>STOPPED</div>';
  const dbBtns=dbLoading?'<button class="svc-btn play" disabled>&#8943;</button>'
    :dbr?'<button class="svc-btn stop" onclick="stopDb(\''+p.name+'\')">&#9632; STOP</button>'
      +(ports.studioPort?'<button class="svc-btn open" onclick="openStudio(\''+p.name+'\')">STUDIO</button>':'')
    :(!do2?'<button class="svc-btn play" onclick="startDb(\''+p.name+'\')">&#9654; START</button>':'');
  // APP service row
  const appPill=ar?'<div class="svc-pill on"><div class="pd"></div>RUNNING</div>'
    :'<div class="svc-pill off"><div class="pd"></div>STOPPED</div>';
  const appBtns=ar?'<button class="svc-btn stop" onclick="stopApp(\''+p.name+'\')">&#9632; STOP</button>'
      +(appUrl?'<a class="svc-btn open" href="'+appUrl+'" target="_blank" style="text-decoration:none">OPEN</a>':'')
    :(dbr?'<button class="svc-btn play" onclick="startApp(\''+p.name+'\')">&#9654; START</button>':'<button class="svc-btn play" disabled title="Start DB first">&#9654; START</button>');
  return '<div class="card '+cc+(sel?' selected':'')+'" data-p="'+p.name+'">'+
    '<div class="cbx" onclick="toggleSelect(\''+p.name+'\')"><div class="cbx-tick"></div></div>'+
    '<div class="card-header"><div class="card-name">'+p.name+'</div></div>'+
    '<div class="svc-rows">'+
      '<div class="svc-row"><span class="svc-label">DB</span>'+dbPill+'<div class="svc-sep"></div>'+dbBtns+'</div>'+
      '<div class="svc-row"><span class="svc-label">APP</span>'+appPill+'<div class="svc-sep"></div>'+appBtns+'</div>'+
    '</div>'+
    '<div class="card-ports" style="grid-template-columns:repeat(4,1fr)">'+
      '<div class="pcell"><div class="plabel">APP</div>'+appLink+'</div>'+
      '<div class="pcell"><div class="plabel">DB</div>'+pv(ports.dbPort)+'</div>'+
      '<div class="pcell"><div class="plabel">API</div>'+pv(ports.apiPort)+'</div>'+
      '<div class="pcell"><div class="plabel">STUDIO</div>'+pv(ports.studioPort)+'</div>'+
    '</div>'+
    (mod?'<div class="cmeta">'+mod+'</div>':'')+
    '<div class="card-actions">'+
      (dbr?'<button class="btn btn-studio" onclick="pushDb(\''+p.name+'\')">&#8593; PUSH DB</button>':'')+
      '<button class="btn btn-ghost" onclick="openDyad(\''+p.name+'\')">DYAD</button>'+
      '<button class="btn btn-ghost" onclick="openVSCode(\''+p.name+'\')">CODE</button>'+
      '<button class="btn btn-ghost" onclick="openFolder(\''+p.name+'\')">&#128194; FOLDER</button>'+
      '<button class="btn btn-ghost" onclick="syncAthena(\''+p.name+'\')">&#128190; SYNC</button>'+
      (!dbr&&!ar?'<button class="btn btn-ghost" style="color:var(--red)" onclick="deleteProject(\''+p.name+'\')">&#128465; DELETE</button>':'')+
    '</div></div>';
}
const ERR_LOG=[];
function toast(type,msg,dur){
  const isErr=type==='error';
  if(dur===undefined)dur=isErr?0:3500; // errors don't auto-dismiss
  const el=document.createElement('div');
  el.className='toast '+type;
  const msgEl=document.createElement('div');
  msgEl.className='tmsg';
  msgEl.textContent=String(msg||'');
  el.appendChild(msgEl);
  const actions=document.createElement('div');
  actions.className='tactions';
  if(isErr){
    // Log the error
    ERR_LOG.unshift({time:new Date().toISOString(),msg:String(msg||'')});
    if(ERR_LOG.length>50)ERR_LOG.pop();
    updateErrLogBtn();
    // Copy button
    const cp=document.createElement('button');
    cp.className='tbtn';cp.textContent='COPY';
    cp.onclick=(e)=>{e.stopPropagation();navigator.clipboard.writeText(String(msg||'')).then(()=>{cp.textContent='COPIED';setTimeout(()=>cp.textContent='COPY',1500);});};
    actions.appendChild(cp);
  }
  // Close button
  const cl=document.createElement('button');
  cl.className='tbtn';cl.textContent='X';
  cl.onclick=()=>el.remove();
  actions.appendChild(cl);
  el.appendChild(actions);
  document.getElementById('tc').prepend(el);
  if(dur>0)setTimeout(()=>el.remove(),dur);
}
function updateErrLogBtn(){
  const btn=document.getElementById('errLogBtn');
  if(!btn)return;
  if(ERR_LOG.length>0){
    btn.classList.add('on');
    btn.innerHTML='&#9888; ERRORS <span class="errlog-count">'+ERR_LOG.length+'</span>';
  }else{
    btn.classList.remove('on');
  }
}
function openErrLog(){
  const modal=document.getElementById('errLogModal');
  const body=document.getElementById('errLogBody');
  if(ERR_LOG.length===0){
    body.innerHTML='<div class="errlog-empty">No errors logged.</div>';
  }else{
    body.innerHTML=ERR_LOG.map((e,i)=>{
      const t=new Date(e.time).toLocaleString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'});
      const escaped=e.msg.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      return '<div class="errlog-entry"><div class="et-time">'+t+'</div><div class="et-msg">'+escaped+'</div><button class="et-copy" onclick="copyErrLog('+i+',this)">COPY</button></div>';
    }).join('');
  }
  modal.classList.add('on');
}
function closeErrLog(){document.getElementById('errLogModal').classList.remove('on');}
function copyErrLog(idx,btn){
  navigator.clipboard.writeText(ERR_LOG[idx].msg).then(()=>{
    btn.textContent='COPIED';setTimeout(()=>btn.textContent='COPY',1500);
  });
}
function clearErrLog(){
  ERR_LOG.length=0;
  updateErrLogBtn();
  openErrLog();
}
function copyBlock(id){
  const el=document.getElementById(id);
  if(!el)return;
  // Get text content excluding the button
  const btn=el.querySelector('.copy-btn');
  const text=el.textContent.replace(btn?btn.textContent:'','').trim();
  navigator.clipboard.writeText(text).then(()=>{
    if(btn){btn.textContent='COPIED!';btn.classList.add('copied');setTimeout(()=>{btn.textContent='COPY';btn.classList.remove('copied');},1500);}
    toast('ok','Copied to clipboard');
  }).catch(()=>toast('error','Could not copy'));
}
document.addEventListener('DOMContentLoaded',()=>{loadTheme();loadInfoBarState();fetchAll();});
</script>
</body>
</html>

'@
  Write-Utf8NoBom -Path "$VibeRoot\DASHBOARD\public\index.html" -Content $indexHtml
  Write-Good "DASHBOARD\public\index.html written."

  # -- launch-dashboard.ps1 ---------------------------------------------------
  $launchPs1 = @'
# launch-dashboard.ps1 -- starts the server only, CMD handles browser
$Port = 9999
$DashDir = "C:\VIBESTACK\DASHBOARD"
$ServerUrl = "http://localhost:$Port"

# Already running? Just exit.
try {
  $r = Invoke-WebRequest -Uri "$ServerUrl/api/status" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
  if ($r.StatusCode -eq 200) { exit 0 }
} catch {}

# Kill zombie node process on port 9999
try {
  $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
  if ($conn) {
    $conn | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
  }
} catch {}

# First-time npm install
if (-not (Test-Path "$DashDir\node_modules")) {
  $np = Start-Process -FilePath "cmd" -ArgumentList "/c echo. && echo   VIBESTACK: Setting up dashboard for the first time... && echo   This takes 15-30 seconds. Please wait. && echo. && cd /d `"$DashDir`" && npm install && echo. && echo   Setup complete!" -Wait -PassThru
  if ($np.ExitCode -ne 0) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show("Dashboard setup failed.`nTry VIBESTACK-DASHBOARD-DEBUG.cmd for details.", "VIBESTACK", 0, 48) | Out-Null
    exit 1
  }
}

# Start server silently
Start-Process -FilePath "node" -ArgumentList "$DashDir\server.js" -WorkingDirectory $DashDir -WindowStyle Hidden
'@
  Write-Utf8NoBom -Path "$VibeRoot\DASHBOARD\launch-dashboard.ps1" -Content $launchPs1
  Write-Good "DASHBOARD\launch-dashboard.ps1 written."

  # -- VIBESTACK-DASHBOARD.cmd ------------------------------------------------
  $dashCmd = "@echo off`r`ntitle VIBESTACK Dashboard`r`n`r`n:: Check if dashboard is already running`r`nnetstat -ano | findstr :9999 | findstr LISTENING >nul 2>&1`r`nif not errorlevel 1 (`r`n  echo.`r`n  echo   Dashboard is already running.`r`n  echo   Opening in your browser...`r`n  echo.`r`n  start http://localhost:9999`r`n  timeout /t 2 /nobreak >nul`r`n  exit /b 0`r`n)`r`n`r`n:: Install deps if needed`r`nif not exist `"C:\VIBESTACK\DASHBOARD\node_modules`" (`r`n  echo.`r`n  echo   VIBESTACK: Setting up dashboard for the first time...`r`n  echo   This takes 15-30 seconds. Please wait.`r`n  echo.`r`n  cd /d `"C:\VIBESTACK\DASHBOARD`"`r`n  npm install`r`n)`r`n`r`ncls`r`necho.`r`necho  ================================================`r`necho  VIBESTACK DASHBOARD`r`necho  http://localhost:9999`r`necho  ================================================`r`necho.`r`necho  This window keeps the Dashboard running.`r`necho  DO NOT CLOSE this window while using the Dashboard.`r`necho  When you are done, close this window to stop it.`r`necho.`r`n`r`n:: Open browser after short delay`r`nstart /b cmd /c `"timeout /t 2 /nobreak >nul && start http://localhost:9999`"`r`n`r`ncd /d `"C:\VIBESTACK\DASHBOARD`"`r`nnode server.js`r`necho.`r`necho  Dashboard stopped.`r`npause`r`n"
  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-DASHBOARD.cmd" -Content $dashCmd
  Write-Good "VIBESTACK-DASHBOARD.cmd written."

  # -- VIBESTACK-DASHBOARD-DEBUG.cmd -----------------------------------------
  $dbgCmd = "@echo off`r`ntitle VIBESTACK Dashboard [DEBUG]`r`necho.`r`necho   VIBESTACK DASHBOARD - DEBUG MODE`r`necho   http://localhost:9999`r`necho   Press Ctrl+C to stop.`r`necho.`r`nif not exist `"C:\VIBESTACK\DASHBOARD\node_modules`" (`r`n  cd /d `"C:\VIBESTACK\DASHBOARD`"`r`n  npm install`r`n)`r`ncd /d `"C:\VIBESTACK\DASHBOARD`"`r`nnode server.js`r`necho.`r`npause`r`n"
  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-DASHBOARD-DEBUG.cmd" -Content $dbgCmd
  Write-Good "VIBESTACK-DASHBOARD-DEBUG.cmd written."

  # -- npm install for dashboard ----------------------------------------------
  if (-not (Test-Path "$VibeRoot\DASHBOARD\node_modules")) {
    Write-Info "Installing dashboard dependencies (express)..."
    Write-Host "  This takes 15-30 seconds on first run..." -ForegroundColor DarkGray
    try {
      $npmResult = Start-Process -FilePath "cmd" -ArgumentList "/c cd /d `"$VibeRoot\DASHBOARD`" && npm install 2>&1" -Wait -PassThru -WindowStyle Hidden
      if ($npmResult.ExitCode -eq 0) {
        Write-Good "Dashboard dependencies installed."
      } else {
        Write-WarnMsg "npm install may have had issues. Try VIBESTACK-DASHBOARD-DEBUG.cmd for details."
      }
    } catch {
      Write-WarnMsg "Could not install dashboard dependencies. Run VIBESTACK-DASHBOARD-DEBUG.cmd to troubleshoot."
    }
  } else {
    Write-Good "Dashboard dependencies already installed."
  }
}


# ==============================================================================
# CREATE DESKTOP SHORTCUT
# ==============================================================================

function Write-DesktopShortcut {
  Write-Step "CREATING DESKTOP SHORTCUT"

  try {
    # Try multiple desktop paths (OneDrive can redirect)
    $desktops = @(
      [Environment]::GetFolderPath("Desktop"),
      "$HOME\Desktop",
      "$Env:USERPROFILE\Desktop",
      "$Env:USERPROFILE\OneDrive\Desktop"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $cmdSource = "$VibeRoot\VIBESTACK-DASHBOARD.cmd"
    if (-not (Test-Path $cmdSource)) {
      Write-WarnMsg "VIBESTACK-DASHBOARD.cmd not found. Skipping desktop shortcut."
      return
    }

    $placed = $false
    foreach ($desktop in $desktops) {
      try {
        $cmdDest = Join-Path $desktop "VIBESTACK-DASHBOARD.cmd"
        Copy-Item $cmdSource $cmdDest -Force
        Write-Good "VIBESTACK-DASHBOARD.cmd copied to $desktop"
        $placed = $true
        break
      } catch { continue }
    }

    if (-not $placed) {
      Write-WarnMsg "Could not copy to Desktop. Find it at: C:\VIBESTACK\VIBESTACK-DASHBOARD.cmd"
    }
  } catch {
    Write-WarnMsg "Could not create Desktop shortcut. You can find the dashboard at:"
    Write-Host "    C:\VIBESTACK\VIBESTACK-DASHBOARD.cmd" -ForegroundColor Cyan
  }
}


# ==============================================================================
# WRITE WIPE SCRIPT (nuclear reset for Docker/Supabase)
# ==============================================================================

function Write-WipeScript {

  $wipeContent = @'
# VIBESTACK-WIPE.ps1
# Nuclear wipe -- removes ALL Supabase containers and volumes, resets ports.
# Docker IMAGES are kept so new projects start in seconds instead of re-downloading.
# Your project CODE is NOT deleted.

$VibeRoot = "C:\VIBESTACK"

Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Red
Write-Host "  VIBESTACK NUCLEAR WIPE" -ForegroundColor Red
Write-Host "  ================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  This will:" -ForegroundColor Yellow
Write-Host "    1. Stop ALL Docker containers" -ForegroundColor White
Write-Host "    2. Remove ALL Supabase containers" -ForegroundColor White
Write-Host "    3. Remove ALL Supabase Docker volumes" -ForegroundColor White
Write-Host "    4. Reset the port registry to starting position" -ForegroundColor White
Write-Host "    5. Clean up ghost project folders (empty ones only)" -ForegroundColor White
Write-Host ""
Write-Host "  Docker images are KEPT (saves re-download time)." -ForegroundColor DarkGray
Write-Host "  Your project CODE is NOT deleted." -ForegroundColor Green
Write-Host ""

$confirm = Read-Host "  Type WIPE to confirm, or press Enter to cancel"
if ($confirm -ne "WIPE") {
  Write-Host "  Cancelled." -ForegroundColor DarkGray
  Read-Host "  Press Enter to close"
  exit 0
}

Write-Host ""

$dockerOk = $false
try { docker info 2>&1 | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch {}
if (-not $dockerOk) {
  Write-Host "  [ERROR] Docker is not running. Start Docker Desktop first." -ForegroundColor Red
  Read-Host "  Press Enter to close"
  exit 1
}

Write-Host "  [1/5] Stopping all containers..." -ForegroundColor Cyan
try {
  $ids = (docker ps -q 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if ($ids.Count -gt 0) { docker stop $ids 2>&1 | Out-Null }
  Write-Host "  [OK]  Stopped." -ForegroundColor Green
} catch { Write-Host "  [WARN] $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "  [2/5] Removing Supabase containers..." -ForegroundColor Cyan
try {
  $sc = (docker ps -a --format "{{.Names}}" 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "supabase" }
  foreach ($c in $sc) { docker rm -f $c 2>&1 | Out-Null }
  Write-Host "  [OK]  Removed $($sc.Count) container(s)." -ForegroundColor Green
} catch { Write-Host "  [WARN] $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "  [3/5] Removing Supabase volumes..." -ForegroundColor Cyan
try {
  $sv = (docker volume ls --format "{{.Name}}" 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "supabase" }
  foreach ($v in $sv) { docker volume rm -f $v 2>&1 | Out-Null }
  Write-Host "  [OK]  Removed $($sv.Count) volume(s)." -ForegroundColor Green
} catch { Write-Host "  [WARN] $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "  [4/5] Resetting port registry..." -ForegroundColor Cyan
try {
  $regPath = "$VibeRoot\TOOLS\DATABASE\port-registry.json"
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($regPath, '{"nextBase":55000,"projects":{}}', $enc)
  Write-Host "  [OK]  Ports reset to 55000." -ForegroundColor Green
} catch { Write-Host "  [WARN] $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "  [5/5] Cleaning ghost folders..." -ForegroundColor Cyan
$pd = "$VibeRoot\PROJECTS"
if (Test-Path $pd) {
  foreach ($f in (Get-ChildItem $pd -Directory -EA SilentlyContinue)) {
    $hasPkg = Test-Path (Join-Path $f.FullName "package.json")
    $hasApp = Test-Path (Join-Path $f.FullName "app")
    if (-not $hasPkg -and -not $hasApp) {
      Remove-Item $f.FullName -Recurse -Force -EA SilentlyContinue
      Write-Host "  [OK]  Removed ghost: $($f.Name)" -ForegroundColor Green
    }
  }
}
try { docker network prune -f 2>&1 | Out-Null } catch {}

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Green
Write-Host "  WIPE COMPLETE -- Ready for fresh start" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next: Double-click Create-New-VibeStack-App.cmd" -ForegroundColor Cyan
Write-Host "  Or open the Dashboard: VIBESTACK-DASHBOARD.cmd" -ForegroundColor Cyan
Write-Host ""
Read-Host "  Press Enter to close"
'@

  Write-Utf8NoBom -Path "$VibeRoot\VIBESTACK-WIPE.ps1" -Content $wipeContent
  Write-Good "VIBESTACK-WIPE.ps1 written."
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

try {
  Clear-Host
  Write-Host ""

  if ($PatchOnly) {
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host "  VIBESTACK PATCH MODE" -ForegroundColor Cyan
    Write-Host "  ================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Updating create-project.js and launchers only." -ForegroundColor White
    Write-Host "  Your projects and running apps are untouched." -ForegroundColor DarkGray
    Write-Host ""
    Ensure-Dir $VibeRoot
    Ensure-Dir "$VibeRoot\CORE"
    Write-CreateProjectScript
    Write-LauncherFiles
    Write-StatusScript
    Write-HelpDocs
    Write-StartDbsScript
    Write-WipeScript
    Write-DashboardFiles
    Write-DesktopShortcut
    Write-Good "Patch complete. Core files and dashboard updated."
    exit 0
  }

  Write-Host "  ================================================" -ForegroundColor Cyan
  Write-Host "  VIBESTACK INSTALLER v1.5.1" -ForegroundColor Cyan
  Write-Host "  ================================================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Setting up your machine for AI-powered local development." -ForegroundColor White
  Write-Host "  Do not close this window until it says VIBESTACK IS READY." -ForegroundColor Yellow

  # Check if this is a resume
  $p = Get-Progress
  if ($p.completedSteps -and $p.completedSteps.Count -gt 0) {
    Write-Host ""
    Write-Host "  Resuming from previous run." -ForegroundColor DarkGray
    Write-Host "  Completed steps will be skipped automatically." -ForegroundColor DarkGray
  }
  Write-Host ""

  Ensure-Admin
  Ensure-Dir $VibeRoot
  Ensure-Dir "$VibeRoot\CORE"

  Invoke-PreflightCheck
  Ensure-CoreInstalls
  Build-VibeStackStructure
  Write-CreateProjectScript
  Write-LauncherFiles
  Write-UpdateScript
  Write-StatusScript
  Write-HelpDocs
  Write-PatchScript
  Write-StartDbsScript
  Write-WipeScript
  Write-DashboardFiles
  Write-DesktopShortcut
  Save-InstallerToCore
  Show-FinalSuccess
}
catch {
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Red
  Write-Host "  INSTALL STOPPED" -ForegroundColor Red
  Write-Host "  ================================================" -ForegroundColor Red
  Write-Host ""
  Write-Bad $_.Exception.Message
  Write-Host ""
  Write-Host "  Progress has been saved. Run the installer again to resume." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Run: Set-ExecutionPolicy -Scope Process Bypass" -ForegroundColor Cyan
  Write-Host "  Run: `& `"$HOME\Desktop\vibestack-installer.ps1`"" -ForegroundColor Cyan
  Write-Host ""
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host "  You can now close this window (click the X)." -ForegroundColor Green
  Write-Host "  ================================================" -ForegroundColor Green
  Write-Host ""
  Read-Host "  Or press Enter"
  exit 1
}

# Force exit so the PowerShell window closes cleanly instead of returning to prompt
exit 0
