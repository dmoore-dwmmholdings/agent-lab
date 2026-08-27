# Windows installer for Agent Lab. Equivalent of ./install.sh.
#
# Run from a normal (non-elevated) PowerShell prompt:
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Unlike install.sh this writes .cmd shims rather than symlinks. Creating a
# symlink on Windows needs either Developer Mode or an elevated prompt, and a
# shim works from cmd.exe, PowerShell, and Git Bash alike.

[CmdletBinding()]
param(
    # Where to put the codex-lab / claude-lab / lume-lab commands.
    [string] $BinDir = (Join-Path $env:LOCALAPPDATA 'AgentLab\bin'),
    # Skip the user PATH update.
    [switch] $NoPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoDir = $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error 'Docker Desktop is required. Install it, start it, then run this again.'
    exit 1
}

docker info --format '{{.ServerVersion}}' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Docker is installed but its engine is not responding. Start Docker Desktop, wait for it to report Running, then run this again.'
    exit 1
}

# Agent Lab images are Linux images. A Docker Desktop switched to Windows
# containers cannot run them, and the failure much later is cryptic.
$serverOs = (docker version --format '{{.Server.Os}}' 2>$null)
if ($LASTEXITCODE -eq 0 -and $serverOs -and $serverOs.Trim() -ne 'linux') {
    Write-Error "Docker Desktop is set to $($serverOs.Trim()) containers. Right-click the Docker tray icon and choose 'Switch to Linux containers', then run this again."
    exit 1
}

foreach ($volume in @('codex-lab-home', 'claude-lab-home', 'agent-lab-github', 'agent-lab-gcloud')) {
    docker volume create $volume | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Could not create the Docker volume $volume."
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

# Prefer PowerShell 7 when it is installed, but fall back to the Windows
# PowerShell that every machine has.
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

$shims = @(
    @{ Name = 'codex-lab';  Script = 'start-codex.ps1' }
    @{ Name = 'claude-lab'; Script = 'start-claude.ps1' }
    @{ Name = 'lume-lab';   Script = 'lume-lab.ps1' }
)

foreach ($shim in $shims) {
    $target = Join-Path $repoDir $shim.Script
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Error "Missing launcher: $target"
        exit 1
    }
    $shimPath = Join-Path $BinDir "$($shim.Name).cmd"
    $lines = @(
        '@echo off'
        'setlocal'
        "$psExe -NoProfile -NoLogo -ExecutionPolicy Bypass -File ""$target"" %*"
        'exit /b %ERRORLEVEL%'
    )
    # Batch files need CRLF; a LF-only .cmd misbehaves around labels and goto.
    Set-Content -LiteralPath $shimPath -Value $lines -Encoding ascii
    Write-Host "installed $shimPath"
}

if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $entries = @($userPath.Split(';') | Where-Object { $_ -ne '' })
    $already = @($entries | Where-Object { $_.TrimEnd('\') -ieq $BinDir.TrimEnd('\') })
    if ($already.Count -eq 0) {
        $updated = if ($userPath.Trim() -eq '') { $BinDir } else { "$($userPath.TrimEnd(';'));$BinDir" }
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Host "added $BinDir to your user PATH (open a new terminal to pick it up)"
    }
    # Make the commands usable in the shell that ran the installer, too.
    $inSession = @($env:Path -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ieq $BinDir.TrimEnd('\') })
    if ($inSession.Count -eq 0) {
        $env:Path = "$env:Path;$BinDir"
    }
}

Write-Host ''
Write-Host 'Agent Lab installed.'
Write-Host 'Next: codex-lab login, then codex-lab github login and codex-lab gcloud login.'
Write-Host 'For Claude: claude-lab login.'
