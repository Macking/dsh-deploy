<#
.SYNOPSIS
    Fetch the DSH WebUI launch URL (with token) from container logs.

.DESCRIPTION
    DSH prints a one-time launch URL in its startup logs:
      dsh web: http://<host>/?token=<TOKEN>
    The token is required for first access -- DSH exchanges it for a
    session cookie.  This script extracts that URL from the running
    container's logs, either locally or via SSH.

.PARAMETER RemoteHost
    Server IP. Default: 192.168.76.12. Set to empty string for local mode.

.PARAMETER User
    SSH username. Default: macking

.PARAMETER Password
    SSH password. Default: 12345678

.PARAMETER Wait
    Poll until the URL appears (useful right after deployment).

.PARAMETER WaitTimeout
    Max seconds to wait with -Wait. Default: 60

.PARAMETER Raw
    Print only the URL, no decorative output (for piping).

.EXAMPLE
    .\scripts\get-url.ps1
    .\scripts\get-url.ps1 -RemoteHost 10.0.0.50
    .\scripts\get-url.ps1 -Wait
    .\scripts\get-url.ps1 -Raw
#>

param(
    [string]$RemoteHost  = "192.168.76.12",
    [string]$User        = "macking",
    [string]$Password    = "12345678",
    [switch]$Wait,
    [int]$WaitTimeout    = 60,
    [switch]$Raw
)

$ErrorActionPreference = "Stop"

# Docker command to extract the URL (runs on the server via SSH).
# sed strips ANSI color codes; grep matches the URL line (not the
# entrypoint "Starting: dsh web" line); tail -1 gets the most recent
# URL (each restart issues a new token); final sed strips the prefix.
$GetUrlCmd = 'docker logs -t dsh-harness 2>&1 | sed "s/\x1b\[[0-9;]*m//g" | grep "dsh web: http" | tail -1 | sed "s/.*dsh web: //"'

# --- Determine target label ---
if ($RemoteHost) {
    $Target = "$User@$RemoteHost"
} else {
    $Target = "localhost"
}

# --- Create SSH session if remote ---
$sshSession = $null
if ($RemoteHost) {
    if (-not (Get-Module -ListAvailable Posh-SSH)) {
        Write-Host "ERROR: Posh-SSH module is not installed." -ForegroundColor Red
        Write-Host "  Run: Install-Module Posh-SSH -Force -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
    Import-Module Posh-SSH -ErrorAction Stop

    if (-not $Raw) {
        Write-Host "Connecting to $RemoteHost ..." -ForegroundColor DarkGray
    }
    $SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential($User, $SecurePass)
    $sshSession = New-SSHSession -ComputerName $RemoteHost -Credential $Credential -AcceptKey -ConnectionTimeout 15
}

function Get-Url {
    if ($sshSession) {
        $result = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $GetUrlCmd -TimeOut 30
        $url = if ($result.Output) { ($result.Output -join "`n").Trim() } else { "" }
    }
    else {
        # Local mode -- run docker directly (PowerShell Core on the server)
        $output = docker logs -t dsh-harness 2>&1 | Out-String
        $esc = [char]27
        $clean = $output -replace "$esc\[[0-9;]*m", ""
        $lines = $clean -split "`n" | Select-String "dsh web: http"
        if ($lines) {
            $url = ($lines[-1] -replace ".*dsh web: ", "").Trim()
        } else {
            $url = ""
        }
    }

    # Validate: must start with http and contain token=
    if ($url -and $url -match '^http.*token=') {
        return $url
    }
    return $null
}

function Print-Result {
    param([string]$Url)
    if ($Raw) {
        Write-Output $Url
        return
    }
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  DSH WebUI Launch URL" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Server : $Target" -ForegroundColor White
    Write-Host "  URL    : $Url" -ForegroundColor White
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Open this URL in your browser to authenticate." -ForegroundColor Gray
    Write-Host "  DSH exchanges the token for a session cookie --" -ForegroundColor Gray
    Write-Host "  after that, you can visit the URL without the token." -ForegroundColor Gray
    Write-Host ""
}

try {
    if ($Wait) {
        if (-not $Raw) {
            Write-Host "Waiting for DSH WebUI URL on $Target (timeout: $WaitTimeout s)..." -ForegroundColor Yellow
        }
        $elapsed = 0
        while ($elapsed -lt $WaitTimeout) {
            $url = Get-Url
            if ($url) {
                Print-Result -Url $url
                exit 0
            }
            Start-Sleep -Seconds 3
            $elapsed += 3
            if (-not $Raw) {
                Write-Host "  ... waiting ($elapsed s / $WaitTimeout s)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
        Write-Host "ERROR: Timed out after $WaitTimeout s -- URL not found in logs." -ForegroundColor Red
        Write-Host "Check the container manually:" -ForegroundColor Yellow
        Write-Host "  docker ps | grep dsh-harness"
        Write-Host "  docker logs dsh-harness"
        exit 1
    }
    else {
        $url = Get-Url
        if ($url) {
            Print-Result -Url $url
        }
        else {
            Write-Host "ERROR: Could not find 'dsh web: http...' in dsh-harness logs on $Target." -ForegroundColor Red
            Write-Host ""
            Write-Host "Possible causes:" -ForegroundColor Yellow
            Write-Host "  - Container not running: docker ps | grep dsh-harness"
            Write-Host "  - Still initializing:    .\scripts\get-url.ps1 -Wait"
            Write-Host "  - Logs rotated:          docker logs dsh-harness"
            exit 1
        }
    }
}
finally {
    if ($sshSession) {
        Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
        if (-not $Raw) {
            Write-Host "SSH session closed." -ForegroundColor DarkGray
        }
    }
}
