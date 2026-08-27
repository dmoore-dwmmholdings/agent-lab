# Windows launcher for Codex Lab. Feature parity with the bash ./start-codex.
#
#   codex-lab C:\path\to\project
#   codex-lab .
#   codex-lab login
#   codex-lab mcp list
#   codex-lab github login
#   codex-lab gcloud login
#   codex-lab gui C:\path\to\project

# Deliberately no param() block. With one, PowerShell binds dash-prefixed
# tokens as script parameters and silently drops the ones it recognises -- a
# pass-through "gcloud ... -v" loses its -v before docker ever sees it. A bare
# $args forwards every argument verbatim.
$Arguments = @($args)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'agent-lab.common.ps1')

function Show-Usage {
    Write-Host 'Usage: codex-lab C:\path\to\project'
    Write-Host '       codex-lab login'
    Write-Host '       codex-lab mcp <list|add|remove|login|logout> ...'
    Write-Host '       codex-lab github <login|setup-git|identity|status|logout>'
    Write-Host '       codex-lab gcloud <login|firestore-login|status>'
    Write-Host '       codex-lab gui C:\path\to\project'
    Write-Host '       codex-lab lume ...            (macOS only)'
}

try {
    $config = New-LabConfig -Agent 'codex' -LabDir $PSScriptRoot
    Assert-LabDocker

    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $rest = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
    $gui = $false

    switch ($command) {
        'login' {
            Invoke-LabHomeCommand -Config $config -CommandArgs (@('codex', 'login', '--device-auth') + $rest)
            exit (Get-LabExitCode)
        }
        'mcp' {
            Invoke-LabHomeCommand -Config $config -CommandArgs (@('codex', 'mcp') + $rest)
            exit (Get-LabExitCode)
        }
        'github' {
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
