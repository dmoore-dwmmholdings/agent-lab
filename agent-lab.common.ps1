# Shared helpers for the Windows launchers (start-codex.ps1, start-claude.ps1).
#
# Windows uses PowerShell rather than the bash launchers on purpose. Under Git
# Bash / MSYS, every argument that looks like a Unix path -- /home/codex,
# /github, /tmp:rw,noexec... -- is silently rewritten into a Windows path
# before docker.exe ever sees it, which corrupts the volume and tmpfs flags.
# PowerShell hands the arguments to docker.exe untouched.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SharedVolumes = @(
    @{ Volume = 'agent-lab-github'; Mount = '/github' }
    @{ Volume = 'agent-lab-gcloud'; Mount = '/gcloud' }
)

$script:SharedEnv = @(
    'GH_CONFIG_DIR=/github/gh'
    'GIT_CONFIG_GLOBAL=/github/gitconfig'
    'CLOUDSDK_CONFIG=/gcloud'
    'GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json'
)

# Exit codes travel through this variable rather than through a function's
# return value. Anything docker writes to stdout becomes part of that return
# value whenever the call sits in a capturing context -- "exit (Invoke-Lab...)"
# is one -- which both swallows the agent's output and leaves `exit` holding an
# array instead of a number. Keeping the code out of the pipeline lets docker
# write straight to the console, which interactive sessions need anyway.
$script:LabExitCode = 0

function Set-LabExitCode {
    param([Parameter(Mandatory)][int] $Code)
    $script:LabExitCode = $Code
}

function Get-LabExitCode {
    return $script:LabExitCode
}

# A launcher failure should read like a CLI error, not a PowerShell stack
# trace, and should keep the sysexits.h codes the bash launchers return.
function New-LabError {
    param(
        [Parameter(Mandatory)][string] $Message,
        [int] $ExitCode = 1
    )

    $exception = New-Object System.Exception($Message)
    $exception.Data['LabExitCode'] = $ExitCode
    return $exception
}

function Get-LabErrorExitCode {
    param([Parameter(Mandatory)] $ErrorRecord)

    $exception = $ErrorRecord.Exception
    if ($exception -and $exception.Data -and $exception.Data.Contains('LabExitCode')) {
        return [int] $exception.Data['LabExitCode']
    }
    return 1
}

function New-LabConfig {
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string] $Agent,
        [Parameter(Mandatory)][string] $LabDir
    )

    if ($Agent -eq 'codex') {
        return [pscustomobject]@{
            Agent         = 'codex'
            Cli           = 'codex-lab'
            LabDir        = $LabDir
            Image         = 'codex-lab-project'
            HomeVolume    = 'codex-lab-home'
            ContainerHome = '/home/codex'
            ComposeFile   = 'compose.yaml'
            GuidanceDir   = '/home/codex/.codex'
            GuidanceFile  = '/home/codex/.codex/AGENTS.md'
            AgentCommand  = @('codex', '--dangerously-bypass-approvals-and-sandbox')
        }
    }

    return [pscustomobject]@{
        Agent         = 'claude'
        Cli           = 'claude-lab'
        LabDir        = $LabDir
        Image         = 'claude-lab-project'
        HomeVolume    = 'claude-lab-home'
        ContainerHome = '/home/claude'
        ComposeFile   = 'claude-compose.yaml'
        GuidanceDir   = '/home/claude/.claude'
        GuidanceFile  = '/home/claude/.claude/CLAUDE.md'
        AgentCommand  = @('claude', '--dangerously-skip-permissions')
    }
}

function Assert-LabDocker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw (New-LabError 'Docker Desktop is required. Install it, start it, then run this again.' 69)
    }
    docker info --format '{{.ServerVersion}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw (New-LabError 'Docker is installed but its engine is not responding. Start Docker Desktop, wait for it to report Running, then try again.' 69)
    }

    # The lab images are Linux images; Docker Desktop switched to Windows
    # containers fails much later with an unhelpful message.
    $serverOs = (docker version --format '{{.Server.Os}}' 2>&1)
    if ($LASTEXITCODE -eq 0 -and $serverOs -and "$serverOs".Trim() -ne 'linux') {
        throw (New-LabError "Docker Desktop is set to $("$serverOs".Trim()) containers. Right-click the Docker tray icon and choose 'Switch to Linux containers', then try again." 69)
    }
}

# docker run -it aborts with "the input device is not a TTY" when stdin or
# stdout is a pipe, so mirror the [[ -t 0 && -t 1 ]] test from the bash
# launchers instead of always requesting a TTY.
function Test-LabInteractive {
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    } catch {
        return $false
    }
    return [Environment]::UserInteractive
}

function Resolve-LabProject {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw (New-LabError 'No project directory was supplied.' 64)
    }
    if ($Path.StartsWith('\\')) {
        throw (New-LabError "Docker Desktop cannot bind-mount a UNC path ($Path). Map the share to a drive letter, or copy the project onto a local drive, then use that path." 66)
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw (New-LabError "Not a directory: $Path" 66)
    }

    $full = (Get-Item -LiteralPath $Path).FullName
    $trimmed = $full.TrimEnd('\', '/')

    $leaf = Split-Path -Leaf $trimmed
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '^[A-Za-z]:$') {
        # A whole drive was requested. Give it a usable name, but say plainly
        # that this hands the agent every project on that drive.
        $letter = $trimmed.Substring(0, 1).ToLowerInvariant()
        $leaf = "$letter-drive"
        Write-Warning "Mounting an entire drive ($full). The agent will be able to modify every file on it. Point the lab at a single project directory instead."
    }

    # Docker Desktop accepts a forward-slash Windows path; a backslash path is
    # ambiguous once Compose interpolates it into the bind source.
    $hostPath = $trimmed -replace '\\', '/'

    # Keep the container-side name to characters a Linux path handles cleanly.
    $safeLeaf = ($leaf -replace '[^A-Za-z0-9._-]', '-')

    return [pscustomobject]@{
        HostPath     = $hostPath
        WorkspaceDir = "/workspace/$safeLeaf"
        DisplayPath  = $full
    }
}

function Get-LabHomeArgs {
    param([Parameter(Mandatory)] $Config)

    $dockerArgs = @('run', '--rm', '--init')
    if (Test-LabInteractive) { $dockerArgs += '-it' }
    $dockerArgs += @(
        '--cap-drop', 'ALL'
        '--security-opt', 'no-new-privileges:true'
        '--tmpfs', '/tmp:rw,noexec,nosuid,size=1g'
        '--volume', "$($Config.HomeVolume):$($Config.ContainerHome)"
    )
    foreach ($shared in $script:SharedVolumes) {
        $dockerArgs += @('--volume', "$($shared.Volume):$($shared.Mount)")
    }
    foreach ($pair in $script:SharedEnv) {
        $dockerArgs += @('--env', $pair)
    }
    return $dockerArgs
}

# The bash launchers assume the image already exists, which is only true after
# a project session has built it. On a new machine the documented first step
# ("codex-lab login") would otherwise fail with "Unable to find image". Build
# it on demand instead.
function Initialize-LabImage {
    param([Parameter(Mandatory)] $Config)

    docker image inspect $Config.Image 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return }

    Write-Host "[agent-lab] building the $($Config.Agent) image (first run only)..."
    # Compose refuses to parse the file until PROJECT_DIR resolves, even for a
    # build that mounts nothing.
    $previousProject = $env:PROJECT_DIR
    $previousWorkspace = $env:WORKSPACE_DIR
    try {
        $env:PROJECT_DIR = ($Config.LabDir -replace '\\', '/')
        $env:WORKSPACE_DIR = '/workspace/agent-lab'
        Push-Location -LiteralPath $Config.LabDir
        try {
            & docker compose -f $Config.ComposeFile build
        } finally {
            Pop-Location
        }
    } finally {
        $env:PROJECT_DIR = $previousProject
        $env:WORKSPACE_DIR = $previousWorkspace
    }
    if ($LASTEXITCODE -ne 0) {
        throw (New-LabError "Could not build the $($Config.Agent) image." 1)
    }
}

# Runs a one-off command against the agent's Docker-only home volume. Every
# argument is passed as its own array element so PowerShell never has to
# re-quote a shell fragment. The exit code lands in Get-LabExitCode.
function Invoke-LabHomeCommand {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string[]] $CommandArgs
    )

    Initialize-LabImage -Config $Config
    $dockerArgs = (Get-LabHomeArgs -Config $Config) + @($Config.Image) + $CommandArgs
    & docker @dockerArgs
    Set-LabExitCode $LASTEXITCODE
}

function Initialize-LabGuidance {
    param([Parameter(Mandatory)] $Config)

    # No double quotes in this payload: PowerShell 5.1 does not escape embedded
    # quotes when it re-quotes an argument for a native executable.
    $payload = "mkdir -p $($Config.GuidanceDir); test -e $($Config.GuidanceFile) || cp /opt/agent-lab/guidance.md $($Config.GuidanceFile)"

    Initialize-LabImage -Config $Config
    $dockerArgs = @(
        'run', '--rm', '--init'
        '--cap-drop', 'ALL'
        '--security-opt', 'no-new-privileges:true'
        '--volume', "$($Config.HomeVolume):$($Config.ContainerHome)"
        $Config.Image
        'bash', '-lc', $payload
    )
    & docker @dockerArgs 2>&1 | Out-Null
}

function Invoke-LabGithub {
    param(
        [Parameter(Mandatory)] $Config,
        [string[]] $Rest = @()
    )

    $insteadOfKey = 'url.https://github.com/.insteadOf'
    $subCommand = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $tail = if ($Rest.Count -gt 1) { @($Rest[1..($Rest.Count - 1)]) } else { @() }

    switch ($subCommand) {
        'login' {
            $payload = "GH_BROWSER=echo gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git --hostname github.com && (git config --global --unset-all '$insteadOfKey' || true) && git config --global --add '$insteadOfKey' 'git@github.com:' && git config --global --add '$insteadOfKey' 'ssh://git@github.com/'"
            Invoke-LabHomeCommand -Config $Config -CommandArgs @('bash', '-lc', $payload)
        }
        'setup-git' {
            $payload = "gh auth setup-git --hostname github.com && (git config --global --unset-all '$insteadOfKey' || true) && git config --global --add '$insteadOfKey' 'git@github.com:' && git config --global --add '$insteadOfKey' 'ssh://git@github.com/'"
            Invoke-LabHomeCommand -Config $Config -CommandArgs @('bash', '-lc', $payload)
        }
        'identity' {
            if ($tail.Count -ne 2) {
                Write-Host "Usage: $($Config.Cli) github identity 'Your Name' you@example.com"
                Set-LabExitCode 64
                return
            }
            # Two plain invocations rather than one sh -c, so a name with spaces
            # or quotes never passes through a shell.
            Invoke-LabHomeCommand -Config $Config -CommandArgs @('git', 'config', '--global', 'user.name', $tail[0])
            if ((Get-LabExitCode) -ne 0) { return }
            Invoke-LabHomeCommand -Config $Config -CommandArgs @('git', 'config', '--global', 'user.email', $tail[1])
        }
        'status' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gh', 'auth', 'status') + $tail)
        }
        'logout' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gh', 'auth', 'logout') + $tail)
        }
        default {
            Write-Host "Usage: $($Config.Cli) github <login|setup-git|identity|status|logout>"
            Set-LabExitCode 64
        }
    }
}

function Invoke-LabGcloud {
    param(
        [Parameter(Mandatory)] $Config,
        [string[]] $Rest = @()
    )

    $subCommand = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $tail = if ($Rest.Count -gt 1) { @($Rest[1..($Rest.Count - 1)]) } else { @() }

    switch ($subCommand) {
        'login' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gcloud', 'auth', 'login', '--no-launch-browser') + $tail)
        }
        'firestore-login' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gcloud', 'auth', 'application-default', 'login', '--no-launch-browser') + $tail)
        }
        'adc-login' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gcloud', 'auth', 'application-default', 'login', '--no-launch-browser') + $tail)
        }
        'status' {
            Invoke-LabHomeCommand -Config $Config -CommandArgs (@('gcloud', 'auth', 'list') + $tail)
        }
        default {
            Write-Host "Usage: $($Config.Cli) gcloud <login|firestore-login|status>"
            Set-LabExitCode 64
        }
    }
}

function Show-LabLumeUnavailable {
    param([Parameter(Mandatory)] $Config)

    $message = @'
The lume path is macOS-only.

Lume boots a real macOS guest through Apple's Virtualization framework, which
exists only on Apple Silicon Macs. There is no Windows equivalent, and macOS
cannot be licensed to run in a VM on non-Apple hardware.

On Windows, use the Docker GUI desktop instead. It gives an agent a real X11
display, a window manager, and Framewatch's linux-x11 backend:

  {0} gui C:\path\to\project

Then open http://localhost:6080/vnc.html in your browser.
'@ -f $Config.Cli

    Write-Host $message
    Set-LabExitCode 69
}

function Invoke-LabProjectSession {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Project,
        [switch] $Gui
    )

    Initialize-LabGuidance -Config $Config

    $previousProject = $env:PROJECT_DIR
    $previousWorkspace = $env:WORKSPACE_DIR
    try {
        $env:PROJECT_DIR = $Project.HostPath
        $env:WORKSPACE_DIR = $Project.WorkspaceDir

        $composeArgs = @('compose')
        if ($Gui) {
            # Each agent's GUI image must have its own project name. Compose
            # derives the built image name from it, and the two GUI paths build
            # the shared Dockerfile with different agent arguments, so a shared
            # name would leave whichever ran second using the other agent's image.
            $composeArgs += @('-p', "$($Config.Agent)-lab-gui")
        }
        $composeArgs += @('-f', $Config.ComposeFile)
        if ($Gui) { $composeArgs += @('-f', 'compose.gui.yaml') }
        $composeArgs += @('run', '--rm')
        # "docker compose run" does not publish a service's declared ports
        # unless asked. Without this the GUI desktop starts fine inside the
        # container but nothing is listening on the host, so the documented
        # http://localhost:6080/vnc.html never connects.
        if ($Gui) { $composeArgs += '--service-ports' }
        if (-not (Test-LabInteractive)) { $composeArgs += '-T' }
        $composeArgs += 'project'
        if ($Gui) { $composeArgs += '/usr/local/bin/agent-lab-gui-entrypoint' }
        $composeArgs += @('node', '/usr/local/bin/agent-lab-entrypoint.mjs') + $Config.AgentCommand

        if ($Gui) {
            Write-Host '[agent-lab] the desktop will be at http://localhost:6080/vnc.html'
        }

        Push-Location -LiteralPath $Config.LabDir
        try {
            & docker @composeArgs
        } finally {
            Pop-Location
        }
        Set-LabExitCode $LASTEXITCODE
    } finally {
        $env:PROJECT_DIR = $previousProject
        $env:WORKSPACE_DIR = $previousWorkspace
    }
}
