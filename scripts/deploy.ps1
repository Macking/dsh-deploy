<#
.SYNOPSIS
    DSH (DeepSeek Harness) deployment script.
    Deploys the nginx + deepseek-harness containers to a remote Ubuntu server via SSH.

.DESCRIPTION
    Architecture:
      - Container 1 (dsh-harness): Node.js image running the official
        `dsh web` CLI from @deepseek-ai/dsh. Binds to 127.0.0.1:3080 (loopback only).
      - Container 2 (dsh-nginx):  Nginx reverse proxy, port 80 -> 127.0.0.1:3080.
      Both containers use network_mode: host so nginx can reach dsh's loopback.

    Steps:
      1. Uploads project files to the remote server via SFTP.
      2. Builds the dsh Docker image (Node.js + npx @deepseek-ai/dsh).
      3. Starts all services with docker compose.
      4. Verifies the deployment.

.PARAMETER RemoteHost
    Remote server IP or hostname. Default: 192.168.76.12

.PARAMETER User
    SSH username. Default: macking

.PARAMETER Password
    SSH password. Default: 12345678

.PARAMETER RemotePath
    Deployment directory on the remote server. Default: /home/<User>/dsh

.PARAMETER PublicHost
    Browser-facing hostname or IP for DSH_PUBLIC_URL and DSH_TRUSTED_HOST.
    Defaults to $RemoteHost. Set this when the public URL differs from the
    SSH host (e.g., a domain name or load balancer IP).

.EXAMPLE
    .\scripts\deploy.ps1
    .\scripts\deploy.ps1 -RemoteHost 192.168.76.12 -User macking -Password 12345678
    .\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -PublicHost dsh.example.com
#>

param(
    [string]$RemoteHost = "192.168.76.12",
    [string]$User       = "macking",
    [string]$Password   = "12345678",
    [string]$RemotePath = "",
    [string]$PublicHost = ""
)

# RemotePath defaults to /home/$User/dsh (derived from the SSH user)
if (-not $RemotePath) { $RemotePath = "/home/$User/dsh" }

# PublicHost defaults to RemoteHost (the common case: SSH IP == browser IP)
if (-not $PublicHost) { $PublicHost = $RemoteHost }

$ErrorActionPreference = "Stop"

# Ensure Posh-SSH is available
if (-not (Get-Module -ListAvailable Posh-SSH)) {
    Write-Error "Posh-SSH module is not installed. Run: Install-Module Posh-SSH -Force -Scope CurrentUser"
    exit 1
}
Import-Module Posh-SSH -ErrorAction Stop

# Project root = parent of scripts/
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DSH Deployment -- DeepSeek Harness + Nginx" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Remote : $User@$RemoteHost" -ForegroundColor Gray
Write-Host "  Public : $PublicHost" -ForegroundColor Gray
Write-Host "  Path   : $RemotePath" -ForegroundColor Gray
Write-Host "  Source : $ProjectRoot" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Create credential ---
$SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($User, $SecurePass)

# --- Establish SSH + SFTP sessions ---
Write-Host "[1/6] Connecting to $RemoteHost ..." -ForegroundColor Yellow
$sshSession  = New-SSHSession  -ComputerName $RemoteHost -Credential $Credential -AcceptKey -ConnectionTimeout 15
$sftpSession = New-SFTPSession -ComputerName $RemoteHost -Credential $Credential -AcceptKey -ConnectionTimeout 15

function Invoke-Remote {
    param([string]$Command, [string]$Label, [int]$TimeOut = 600)
    Write-Host "      > $Label" -ForegroundColor DarkGray
    $result = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $Command -TimeOut $TimeOut
    if ($result.Output) { $result.Output | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
    if ($result.Error -and $result.Error.Trim()) {
        Write-Host "        [stderr] $($result.Error)" -ForegroundColor DarkYellow
    }
    return $result
}

function Upload-File {
    param([string]$LocalPath, [string]$RemoteDest)
    $fileName = Split-Path $LocalPath -Leaf
    Write-Host "      > upload $fileName" -ForegroundColor DarkGray
    Set-SFTPItem -SessionId $sftpSession.SessionId -Path $LocalPath -Destination $RemoteDest -Force
}

try {
    # --- [2/6] Prepare remote directory ---
    Write-Host "[2/6] Preparing remote directory ..." -ForegroundColor Yellow
    Invoke-Remote "mkdir -p $RemotePath/nginx/conf.d $RemotePath/dsh" "create directories"

    # --- [3/6] Upload project files ---
    Write-Host "[3/6] Uploading project files ..." -ForegroundColor Yellow

    $filesToUpload = @(
        @{ Local = "$ProjectRoot\docker-compose.yml";        Remote = "$RemotePath/" },
        @{ Local = "$ProjectRoot\.env";                      Remote = "$RemotePath/" },
        @{ Local = "$ProjectRoot\nginx\nginx.conf";          Remote = "$RemotePath/nginx/" },
        @{ Local = "$ProjectRoot\nginx\conf.d\default.conf"; Remote = "$RemotePath/nginx/conf.d/" },
        @{ Local = "$ProjectRoot\dsh\Dockerfile";            Remote = "$RemotePath/dsh/" },
        @{ Local = "$ProjectRoot\dsh\entrypoint.sh";         Remote = "$RemotePath/dsh/" }
    )

    foreach ($f in $filesToUpload) {
        if (Test-Path $f.Local) {
            Upload-File $f.Local $f.Remote
        } else {
            Write-Host "      ! missing $($f.Local) -- skipped" -ForegroundColor DarkYellow
        }
    }

    # Fix CRLF line endings on entrypoint.sh (uploaded from Windows) and make executable
    Invoke-Remote "sed -i 's/\r$//' $RemotePath/dsh/entrypoint.sh && chmod +x $RemotePath/dsh/entrypoint.sh" "fix entrypoint.sh line endings + chmod"

    # Update .env with the target host's IP so DSH_PUBLIC_URL and DSH_TRUSTED_HOST
    # match the server being deployed to (not the default IP in the repo .env).
    Invoke-Remote "sed -i 's|^DSH_PUBLIC_URL=.*|DSH_PUBLIC_URL=http://$PublicHost/|; s|^DSH_TRUSTED_HOST=.*|DSH_TRUSTED_HOST=$PublicHost|' $RemotePath/.env" "set DSH_PUBLIC_URL/DSH_TRUSTED_HOST to $PublicHost"

    # --- [4/6] Build Docker image ---
    Write-Host "[4/6] Building dsh Docker image (this downloads Node.js deps, may take a few minutes) ..." -ForegroundColor Yellow
    $buildResult = Invoke-Remote "cd $RemotePath && docker compose build 2>&1" "docker compose build" -TimeOut 600
    if ($buildResult.ExitStatus -ne 0) {
        Write-Host "      ! build exited with status $($buildResult.ExitStatus)" -ForegroundColor DarkYellow
    }

    # --- [5/6] Start containers ---
    Write-Host "[5/6] Starting containers ..." -ForegroundColor Yellow
    Invoke-Remote "cd $RemotePath && docker compose down 2>/dev/null; docker compose up -d 2>&1" "docker compose up -d"

    # Wait for dsh to initialize (Node.js startup + npx fetch)
    Write-Host "      waiting for dsh to initialize (30s) ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30

    Invoke-Remote "cd $RemotePath && docker compose ps 2>&1" "container status"

    # --- [6/6] Verify deployment ---
    Write-Host "[6/6] Verifying deployment ..." -ForegroundColor Yellow

    # Check if dsh is listening on 3080
    Invoke-Remote "ss -tlnp | grep ':3080' || echo 'dsh not yet listening on 3080'" "port 3080 check"

    # Check nginx is listening on 80
    Invoke-Remote "ss -tlnp | grep ':80 ' || echo 'nginx not yet listening on 80'" "port 80 check"

    # Try accessing dsh through nginx
    Invoke-Remote "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo 'proxy not ready'" "nginx -> dsh proxy check"

    # Container logs
    Invoke-Remote "docker logs dsh-harness --tail 15 2>&1" "dsh-harness logs"
    Invoke-Remote "docker logs dsh-nginx --tail 10 2>&1" "dsh-nginx logs"

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Deployment complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Web UI         : http://$PublicHost/" -ForegroundColor White
    Write-Host "  Direct dsh     : http://127.0.0.1:3080 (host only)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Note: dsh binds to 127.0.0.1:3080 (loopback only)." -ForegroundColor Gray
    Write-Host "  Access via nginx at http://$PublicHost/ on port 80." -ForegroundColor Gray
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
}
finally {
    if ($sshSession)  { Remove-SSHSession  -SessionId $sshSession.SessionId  | Out-Null }
    if ($sftpSession) { Remove-SFTPSession -SessionId $sftpSession.SessionId | Out-Null }
    Write-Host "SSH/SFTP sessions closed." -ForegroundColor DarkGray
}
