# Windows launcher for Claude Lab. Feature parity with the bash ./start-claude.
#
#   claude-lab C:\path\to\project
#   claude-lab .
#   claude-lab login
#   claude-lab github login
#   claude-lab gcloud login
#   claude-lab gui C:\path\to\project

# Deliberately no param() block. With one, PowerShell binds dash-prefixed
# tokens as script parameters and silently drops the ones it recognises -- a
# pass-through "gcloud ... -v" loses its -v before docker ever sees it. A bare
# $args forwards every argument verbatim.
$Arguments = @($args)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'agent-lab.common.ps1')

function Show-Usage {
    Write-Host 'Usage: claude-lab C:\path\to\project'
    Write-Host '       claude-lab <login|status|logout>'
    Write-Host '       claude-lab github <login|setup-git|identity|status|logout>'
    Write-Host '       claude-lab gcloud <login|firestore-login|status>'
    Write-Host '       claude-lab gui C:\path\to\project'
    Write-Host '       claude-lab lume ...            (macOS only)'
}

try {
    $config = New-LabConfig -Agent 'claude' -LabDir $PSScriptRoot
    Assert-LabDocker

    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $rest = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
    $gui = $false

    switch ($command) {
        'login' {
            Invoke-LabHomeCommand -Config $config -CommandArgs (@('env', 'BROWSER=echo', 'claude', 'auth', 'login') + $rest)
            exit (Get-LabExitCode)
        }
        'status' {
            Invoke-LabHomeCommand -Config $config -CommandArgs (@('claude', 'auth', 'status') + $rest)
            exit (Get-LabExitCode)
        }
        'logout' {
            Invoke-LabHomeCommand -Config $config -CommandArgs (@('claude', 'auth', 'logout') + $rest)
            exit (Get-LabExitCode)
        }
        'github' {
            # The bash launcher shells out to start-codex here, which forces a
            # Codex image build on a Claude-only machine. Both images carry gh
            # and gcloud, and all of this state lives in the shared /github and
            # /gcloud volumes rather than in either agent's home volume, so the
            # Claude image gives the same result without the extra build.
            Invoke-LabGithub -Config $config -Rest $rest
            exit (Get-LabExitCode)
        }
        'gcloud' {
            Invoke-LabGcloud -Config $config -Rest $rest
            exit (Get-LabExitCode)
        }
        'lume' {
            Show-LabLumeUnavailable -Config $config
            exit (Get-LabExitCode)
        }
        'gui' {
            $gui = $true
            $Arguments = $rest
        }
        { $_ -in @('-h', '--help', 'help', '') } {
            Show-Usage
            exit 0
        }
    }

    if ($Arguments.Count -ne 1) {
        Show-Usage
        exit 64
    }

    $project = Resolve-LabProject -Path $Arguments[0]
    Invoke-LabProjectSession -Config $config -Project $project -Gui:$gui
    exit (Get-LabExitCode)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit (Get-LabErrorExitCode -ErrorRecord $_)
}
