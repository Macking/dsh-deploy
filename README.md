# DeepSeek Harness (dsh) Deployment

Deploy the official [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) web UI behind an Nginx reverse proxy on a remote Ubuntu server, using Docker Compose.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Ubuntu Server (<SERVER_IP>)                        │
│                                                     │
│  ┌──────────────┐    ┌───────────────────────────┐  │
│  │  dsh-nginx   │    │  dsh-harness              │  │
│  │  (nginx)     │    │  (Node.js + dsh web)      │  │
│  │  port :80    │──▶│  127.0.0.1:3080           │  │
│  │  host network│    │  host network (loopback)  │  │
│  └──────────────┘    └───────────────────────────┘  │
│         │                                           │
│         │ network_mode: host (both containers)      │
│         ▼                                           │
│  Browser → http://<SERVER_IP>/                      │
└─────────────────────────────────────────────────────┘
```

**Why `network_mode: host`?** DSH deliberately binds to `127.0.0.1:3080` (loopback only) for security — it does not support `0.0.0.0` binding. With both containers on the host network, Nginx can proxy to `127.0.0.1:3080` where DSH is listening, while exposing port 80 to external browsers.

## Prerequisites

### Remote server (Ubuntu)
- Docker 29+ and Docker Compose v2+
- Port 80 available (no existing web server)
- A user with sudo/docker group access

### Local machine (Windows)
- PowerShell 5.1+ with [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module:
  ```powershell
  Install-Module Posh-SSH -Force -Scope CurrentUser
  ```

## Project structure

```
dsh-deploy/
├── docker-compose.yml      # Agent stack: dsh-harness + dsh-nginx
├── .env                    # Environment config (API key, public URL, model paths)
├── .env.example            # Template .env with documented variables
│
├── dsh/                    # Agent image (DeepSeek Harness web UI)
│   ├── Dockerfile          # Node.js 22 + npm install @deepseek-ai/dsh
│   └── entrypoint.sh       # Translates env vars → dsh web CLI flags
│
├── nginx/                  # Reverse proxy: :80 → 127.0.0.1:3080
│   ├── nginx.conf          # Main nginx config
│   └── conf.d/
│       └── default.conf    # Proxy rules + WebSocket/SSE support
│
├── qwen/                   # Model service image (vLLM + Qwen3.8-Flash-Next-FP4)
│   ├── docker-compose.yml  # GPU passthrough, host network, model volume mount
│   ├── Dockerfile          # Based on eugr/spark-vllm-b12x, bakes runtime ENV
│   └── entrypoint.sh       # vllm serve wrapper (model path + served name as args)
│
├── models/                 # Downloaded model weights (populated by prepare.sh)
│   └── .gitkeep            # Placeholder so git tracks the empty directory
│
└── scripts/
    │
    │  ── New-machine setup & model download ──
    ├── prepare.sh          # Export DSH_DEPLOY_HOME/MODEL_ID, write .env, download model
    ├── hfd.sh              # HuggingFace downloader (resumable, via hf-mirror.com)
    │
    │  ── Service startup (run on the server) ──
    ├── start-vllm.sh       # Build + start qwen/ compose (vLLM model service)
    ├── start-ai.sh         # Build + start root compose (dsh + nginx), print WebUI URL
    │
    │  ── Remote deployment (run from local machine) ──
    ├── deploy.ps1          # Windows: upload + build + start via SSH/SFTP (Posh-SSH)
    ├── deploy.sh           # Linux/macOS: same via sshpass
    │
    │  ── WebUI URL helper ──
    ├── get-url.ps1         # Fetch the launch URL with token (Windows)
    └── get-url.sh          # Fetch the launch URL with token (Linux/macOS/server)
```

## Deployment

### Usage (Local machine)

```bash
git clone https://github.com/Macking/dsh-deploy.git "$HOME/dsh-deploy"
cd "$HOME/dsh-deploy"
bash scripts/prepare.sh -m nvidia/Qwen3.8-Flash-Next-FP4-Local -n qwen3.8-flash
bash scripts/start-vllm.sh   # 构建并启动 vLLM 模型服务
bash scripts/start-ai.sh     # 构建并启动 DSH Agent + Nginx，打印 WebUI URL
```

### From Windows (PowerShell)

```powershell
# Deploy to the default server (192.168.76.12)
.\scripts\deploy.ps1

# Deploy to a different server
.\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -User myuser -Password mypass

# Deploy via SSH to one IP, but advertise a domain name as the public URL
.\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -PublicHost dsh.example.com
```

The script automatically updates `.env` on the remote server with the correct
`DSH_PUBLIC_URL` and `DSH_TRUSTED_HOST` based on `-PublicHost` (defaults to
`-RemoteHost`). No manual `.env` editing is needed.

### From Linux/macOS (Bash)

```bash
# Deploy to the default server (192.168.76.12)
./scripts/deploy.sh

# Deploy to a different server
REMOTE_HOST=10.0.0.50 REMOTE_USER=myuser REMOTE_PASS=mypass ./scripts/deploy.sh

# Deploy via SSH to one IP, but advertise a domain name as the public URL
REMOTE_HOST=10.0.0.50 PUBLIC_HOST=dsh.example.com ./scripts/deploy.sh
```

## Configuration

### `.env` file

| Variable | Description | Default |
|---|---|---|
| `DEEPSEEK_API_KEY` | API key for DeepSeek models (also configurable via Web UI Settings) | (empty) |
| `DSH_PUBLIC_URL` | Browser-facing URL dsh advertises | `http://192.168.76.12/` |
| `DSH_TRUSTED_HOST` | Browser-visible authority for dsh's host fence | `192.168.76.12` |

> **The deploy scripts automatically update `DSH_PUBLIC_URL` and `DSH_TRUSTED_HOST`**
> in the remote `.env` to match the target server's IP (or `-PublicHost`/`PUBLIC_HOST`
> if specified). You only need to edit `.env` manually if deploying without the scripts.

### Deploying to a different server

The deployment is fully IP-agnostic — no file in the project hardcodes a specific
server IP (the `192.168.76.12` in `.env` is just a default that the scripts override).

**With the deploy scripts** (recommended):
```powershell
# PowerShell — just pass the target IP
.\scripts\deploy.ps1 -RemoteHost <TARGET_IP> -User <USER> -Password <PASS>
```
```bash
# Bash — just set REMOTE_HOST
REMOTE_HOST=<TARGET_IP> REMOTE_USER=<USER> REMOTE_PASS=<PASS> ./scripts/deploy.sh
```

**Without the scripts** (manual), upload the files and edit `.env` on the server:
```
DSH_PUBLIC_URL=http://<TARGET_IP>/
DSH_TRUSTED_HOST=<TARGET_IP>
```
Then run `docker compose up -d` on the server.

## Accessing the Web UI

After deployment:
- **Web UI**: `http://<SERVER_IP>/?token=<TOKEN>`
- DSH requires a launch token for authentication. Get it from container logs:
  ```bash
  docker logs dsh-harness
  # Look for: dsh web: http://<SERVER_IP>/?token=xxxxxxxx
  ```
- Open the full URL (including `?token=...`) in your browser. DSH exchanges the token for a session cookie — subsequent requests don't need the token.
- Configure your DeepSeek API key in **Settings → Models** in the Web UI.

### Getting the launch URL with the helper scripts

Instead of copying the URL from log output manually, use the helper scripts
to extract it automatically:

**From Windows (PowerShell):**
```powershell
# Default server (192.168.76.12)
.\scripts\get-url.ps1

# Different server
.\scripts\get-url.ps1 -RemoteHost 10.0.0.50 -User myuser -Password mypass

# Wait for the URL to appear (right after deployment)
.\scripts\get-url.ps1 -Wait

# Print only the URL (for piping to Start-Process, etc.)
.\scripts\get-url.ps1 -Raw
```

**From Linux/macOS or directly on the server:**
```bash
# Run on the server directly (docker available locally)
./scripts/get-url.sh

# Run from local machine via SSH
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh

# Wait for the URL to appear
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --wait

# Print only the URL (for piping to curl / xdg-open)
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --raw
```

The `--wait` / `-Wait` flag polls every 3 seconds until the URL appears
(default timeout: 60s), which is useful right after deployment when the
container is still initializing.

## Managing the deployment

All commands run on the remote server in the deployment directory (default `/home/<USER>/dsh`):

```bash
# View running containers
docker compose ps

# View logs
docker logs dsh-harness -f
docker logs dsh-nginx -f

# Restart
docker compose restart

# Stop
docker compose down

# Rebuild after changes
docker compose build && docker compose up -d
```

## How it works

### DSH container (`dsh-harness`)
- Based on `node:22-slim` (DSH requires Node ^22.19 || >=24)
- Installs `@deepseek-ai/dsh` globally via npm
- Runs `dsh web --no-open --public-url $DSH_PUBLIC_URL --trusted-host $DSH_TRUSTED_HOST` via the entrypoint script, which starts the Web UI on `127.0.0.1:3080`
- `network_mode: host` so it listens on the host's loopback
- DSH home (`/dsh-home`) and workspace (`/workspace`) are persisted as named volumes

### Nginx container (`dsh-nginx`)
- Based on `nginx:1.27-alpine`
- Listens on port 80, proxies all requests to `127.0.0.1:3080`
- Preserves the `Host` header (required by DSH's trust fence)
- Supports WebSocket upgrades and SSE streaming for real-time LLM output
- `network_mode: host` so it can reach DSH on the host's loopback

### Security notes
- DSH intentionally does not bind to `0.0.0.0` — it serves only on loopback
- The Nginx proxy is the only external entry point
- DSH's `--trusted-host` fence admits only the configured browser-visible authority
- The launch token in the startup URL is a process credential — share it only with intended users
- For production, add TLS (HTTPS) at the Nginx layer
