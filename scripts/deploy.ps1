<#
.SYNOPSIS
    DSH 全栈部署脚本（PowerShell 版）— 一键部署 vLLM + DeepSeek Harness 到全新远程服务器。

.DESCRIPTION
    上传项目文件后，依次在远程执行三个脚本：
      1. scripts/prepare.sh    — 写入 .env + 下载模型权重（hfd.sh，可断点续传）
      2. scripts/start-vllm.sh — 构建并启动 vLLM 模型服务（qwen/docker-compose.yml）
      3. scripts/start-ai.sh   — 构建并启动 DSH Agent + Nginx，输出带 token 的 WebUI URL

    全新机器只需安装 Docker + Docker Compose；脚本自动处理其余一切。

    Architecture:
      - vllm-serve  : vLLM model service (Qwen3.8-Flash-Next-FP4), port 8000, host network
      - dsh-harness : DeepSeek Harness agent, binds 127.0.0.1:3080 (loopback only)
      - dsh-nginx   : Nginx reverse proxy, port 80 → 127.0.0.1:3080
      All containers use network_mode: host.

.PARAMETER RemoteHost
    远程服务器 IP 或主机名。默认：192.168.76.248

.PARAMETER User
    SSH 用户名。默认：test

.PARAMETER Password
    SSH 密码。默认：123456

.PARAMETER RemotePath
    远程部署目录。默认：/home/<User>/dsh-deploy

.PARAMETER PublicHost
    浏览器访问的主机名或 IP（用于 DSH_PUBLIC_URL / DSH_TRUSTED_HOST）。
    默认与 RemoteHost 相同；若通过域名或负载均衡器访问则需单独指定。

.PARAMETER ModelId
    HuggingFace 模型 ID。默认：nvidia/Qwen3.8-Flash-Next-FP4-Local

.PARAMETER ServedModelName
    vllm --served-model-name 的值。默认：qwen3.8-flash

.PARAMETER DeepseekApiKey
    DeepSeek API 密钥（可选，也可在 Web UI Settings > Models 中运行时配置）。

.EXAMPLE
    .\scripts\deploy.ps1
    .\scripts\deploy.ps1 -RemoteHost 192.168.76.248 -User test -Password 123456
    .\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -PublicHost dsh.example.com
    .\scripts\deploy.ps1 -ModelId Qwen/Qwen3-32B -ServedModelName my-qwen
    .\scripts\deploy.ps1 -DeepseekApiKey sk-xxx
#>

param(
    [string]$RemoteHost       = "192.168.76.248",
    [string]$User             = "test",
    [string]$Password         = "123456",
    [string]$RemotePath       = "",
    [string]$PublicHost       = "",
    [string]$ModelId          = "nvidia/Qwen3.8-Flash-Next-FP4-Local",
    [string]$ServedModelName  = "qwen3.8-flash",
    [string]$DeepseekApiKey   = ""
)

# RemotePath defaults to /home/$User/dsh-deploy (matches prepare.sh convention)
if (-not $RemotePath) { $RemotePath = "/home/$User/dsh-deploy" }
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
Write-Host "  DSH Full-Stack Deploy — vLLM + DeepSeek Harness" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Remote : $User@$RemoteHost" -ForegroundColor Gray
Write-Host "  Public : $PublicHost" -ForegroundColor Gray
Write-Host "  Path   : $RemotePath" -ForegroundColor Gray
Write-Host "  Model  : $ModelId" -ForegroundColor Gray
Write-Host "  Served : $ServedModelName" -ForegroundColor Gray
Write-Host "  Source : $ProjectRoot" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Create credential ---
$SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($User, $SecurePass)

# --- Establish SSH + SFTP sessions ---
Write-Host "Pre-check: Connecting to $RemoteHost ..." -ForegroundColor Yellow
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
    # --- Pre-check: Docker on remote ---
    $dockerCheck = Invoke-Remote "docker --version && docker compose version" "check Docker" -TimeOut 30
    if ($dockerCheck.ExitStatus -ne 0) {
        Write-Error "Remote server does not have Docker/Docker Compose installed. Install with: curl -fsSL https://get.docker.com | sh"
        exit 1
    }
    Write-Host ""

    # --- [1/5] Upload project files ---
    Write-Host "[1/5] Uploading project files to ${RemoteHost}:${RemotePath} ..." -ForegroundColor Yellow

    Invoke-Remote "mkdir -p $RemotePath/dsh $RemotePath/nginx/conf.d $RemotePath/qwen $RemotePath/scripts $RemotePath/models" "create directories"

    $filesToUpload = @(
        @{ Local = "$ProjectRoot\docker-compose.yml";        Remote = "$RemotePath/" },
        @{ Local = "$ProjectRoot\.env.example";              Remote = "$RemotePath/" },
        @{ Local = "$ProjectRoot\dsh\Dockerfile";            Remote = "$RemotePath/dsh/" },
        @{ Local = "$ProjectRoot\dsh\entrypoint.sh";         Remote = "$RemotePath/dsh/" },
        @{ Local = "$ProjectRoot\nginx\nginx.conf";          Remote = "$RemotePath/nginx/" },
        @{ Local = "$ProjectRoot\nginx\conf.d\default.conf"; Remote = "$RemotePath/nginx/conf.d/" },
        @{ Local = "$ProjectRoot\qwen\docker-compose.yml";   Remote = "$RemotePath/qwen/" },
        @{ Local = "$ProjectRoot\qwen\Dockerfile";           Remote = "$RemotePath/qwen/" },
        @{ Local = "$ProjectRoot\qwen\entrypoint.sh";        Remote = "$RemotePath/qwen/" },
        @{ Local = "$ProjectRoot\scripts\prepare.sh";        Remote = "$RemotePath/scripts/" },
        @{ Local = "$ProjectRoot\scripts\hfd.sh";            Remote = "$RemotePath/scripts/" },
        @{ Local = "$ProjectRoot\scripts\start-vllm.sh";     Remote = "$RemotePath/scripts/" },
        @{ Local = "$ProjectRoot\scripts\start-ai.sh";       Remote = "$RemotePath/scripts/" },
        @{ Local = "$ProjectRoot\scripts\get-url.sh";        Remote = "$RemotePath/scripts/" }
    )

    foreach ($f in $filesToUpload) {
        if (Test-Path $f.Local) {
            Upload-File $f.Local $f.Remote
        } else {
            Write-Host "      ! missing $($f.Local) -- skipped" -ForegroundColor DarkYellow
        }
    }
    Write-Host "      Upload complete (14 files)." -ForegroundColor DarkGray
    Write-Host ""

    # --- [2/5] Fix line endings + prepare .env ---
    Write-Host "[2/5] Fixing line endings + preparing .env ..." -ForegroundColor Yellow

    $envSetup = "set -e`ncd '$RemotePath'`n"
    $envSetup += "find . -name '*.sh' -exec sed -i 's/\r$//' {} +`n"
    $envSetup += "find . -name '*.sh' -exec chmod +x {} +`n"
    $envSetup += "cp .env.example .env`n"
    $envSetup += "sed -i 's|^DSH_PUBLIC_URL=.*|DSH_PUBLIC_URL=http://$PublicHost/|' .env`n"
    $envSetup += "sed -i 's|^DSH_TRUSTED_HOST=.*|DSH_TRUSTED_HOST=$PublicHost|' .env`n"
    if ($DeepseekApiKey) {
        $envSetup += "sed -i 's|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=$DeepseekApiKey|' .env`n"
    }

    $envResult = Invoke-Remote $envSetup "fix line endings + prepare .env" -TimeOut 120
    if ($envResult.ExitStatus -ne 0) {
        Write-Error "Failed to prepare .env on remote."
        exit 1
    }
    Write-Host "      .env ready." -ForegroundColor DarkGray
    Write-Host ""

    # --- [3/5] Download model (prepare.sh) ---
    Write-Host "[3/5] Downloading model $ModelId (prepare.sh) ..." -ForegroundColor Yellow
    Write-Host "      This may take 20-60 minutes depending on network speed." -ForegroundColor DarkGray
    Write-Host "      Resumable — re-running the deploy script will continue from where it left off." -ForegroundColor DarkGray

    $prepareResult = Invoke-Remote "cd '$RemotePath' && bash scripts/prepare.sh -m '$ModelId' -n '$ServedModelName' 2>&1" "prepare.sh (model download)" -TimeOut 7200
    if ($prepareResult.ExitStatus -ne 0) {
        Write-Host "      ! prepare.sh exited with status $($prepareResult.ExitStatus)" -ForegroundColor DarkYellow
        Write-Host "      Model download may be incomplete. Re-run the deploy script to resume." -ForegroundColor DarkYellow
        exit 1
    }
    Write-Host "      Model preparation complete." -ForegroundColor DarkGray
    Write-Host ""

    # --- [4/5] Start vLLM model service ---
    Write-Host "[4/5] Starting vLLM model service (start-vllm.sh) ..." -ForegroundColor Yellow

    $vllmResult = Invoke-Remote "cd '$RemotePath' && bash scripts/start-vllm.sh 2>&1" "start-vllm.sh" -TimeOut 1800
    if ($vllmResult.ExitStatus -ne 0) {
        Write-Host "      ! start-vllm.sh exited with status $($vllmResult.ExitStatus)" -ForegroundColor DarkYellow
        exit 1
    }
    Write-Host ""

    # --- [5/5] Start DSH Agent + Nginx ---
    Write-Host "[5/5] Starting DSH Agent + Nginx (start-ai.sh) ..." -ForegroundColor Yellow

    $aiResult = Invoke-Remote "cd '$RemotePath' && bash scripts/start-ai.sh 2>&1" "start-ai.sh" -TimeOut 900
    if ($aiResult.ExitStatus -ne 0) {
        Write-Host "      ! start-ai.sh exited with status $($aiResult.ExitStatus)" -ForegroundColor DarkYellow
        exit 1
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Deployment complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Web UI : http://$PublicHost/" -ForegroundColor White
    Write-Host "  Model  : $ModelId (served as $ServedModelName)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Note: FP4 model loading takes ~20 min. Wait for health check to pass." -ForegroundColor Gray
    Write-Host "  vLLM logs : ssh $User@$RemoteHost 'docker compose -f $RemotePath/qwen/docker-compose.yml logs -f'" -ForegroundColor Gray
    Write-Host "  Stop all  : ssh $User@$RemoteHost 'cd $RemotePath && docker compose down && docker compose -f qwen/docker-compose.yml down'" -ForegroundColor Gray
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
}
finally {
    if ($sshSession)  { Remove-SSHSession  -SessionId $sshSession.SessionId  | Out-Null }
    if ($sftpSession) { Remove-SFTPSession -SessionId $sftpSession.SessionId | Out-Null }
    Write-Host "SSH/SFTP sessions closed." -ForegroundColor DarkGray
}
