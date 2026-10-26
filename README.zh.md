[English](README.md) | 中文

# DeepSeek Harness (dsh) 部署

通过 Docker Compose，在远程 Ubuntu 服务器上以 Nginx 反向代理的方式部署官方 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）Web UI。

## 架构

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

**为什么使用 `network_mode: host`？** 出于安全考虑，DSH 刻意只绑定 `127.0.0.1:3080`（仅 loopback），不支持 `0.0.0.0` 绑定。两个容器都使用 host 网络后，Nginx 可以代理到 DSH 监听的 `127.0.0.1:3080`，同时将 80 端口暴露给外部浏览器。

## 前置条件

### 远程服务器（Ubuntu）
- Docker 29+ 及 Docker Compose v2+
- 80 端口可用（无其他 Web 服务器占用）
- 具有 sudo/docker 组权限的用户

### 本地机器（Windows）
- PowerShell 5.1+，安装 [Posh-SSH](https://github.com/darkoperator/Posh-SSH) 模块：
  ```powershell
  Install-Module Posh-SSH -Force -Scope CurrentUser
  ```

## 项目结构

```
dsh-deploy/
├── docker-compose.yml      # Agent 栈：dsh-harness + dsh-nginx
├── .env                    # 环境配置（API key、公网 URL、模型路径）
├── .env.example            # 模板 .env，含变量说明
│
├── dsh/                    # Agent 镜像（DeepSeek Harness Web UI）
│   ├── Dockerfile          # Node.js 22 + npm install @deepseek-ai/dsh
│   └── entrypoint.sh       # 将环境变量转换为 dsh web CLI 参数
│
├── nginx/                  # 反向代理：:80 → 127.0.0.1:3080
│   ├── nginx.conf          # Nginx 主配置
│   └── conf.d/
│       └── default.conf    # 代理规则 + WebSocket/SSE 支持
│
├── qwen/                   # 模型服务镜像（vLLM + Qwen3.8-Flash-Next-FP4）
│   ├── docker-compose.yml  # GPU 直通、host 网络、模型卷挂载
│   ├── Dockerfile          # 基于 eugr/spark-vllm-b12x，烘焙运行时 ENV
│   └── entrypoint.sh       # vllm serve 包装脚本（模型路径 + 服务名作为参数）
│
├── models/                 # 下载的模型权重（由 prepare.sh 填充）
│   └── .gitkeep            # 占位文件，使 git 跟踪空目录
│
└── scripts/
    │
    │  ── 新机器初始化与模型下载 ──
    ├── prepare.sh          # 导出 DSH_DEPLOY_HOME/MODEL_ID，写入 .env，下载模型
    ├── hfd.sh              # HuggingFace 下载器（可断点续传，经 hf-mirror.com）
    │
    │  ── 服务启动（在服务器上执行）──
    ├── start-vllm.sh       # 构建并启动 qwen/ compose（vLLM 模型服务）
    ├── start-ai.sh         # 构建并启动根 compose（dsh + nginx），打印 WebUI URL
    │
    │  ── 远程部署（从本地机器执行）──
    ├── deploy.ps1          # Windows：通过 SSH/SFTP 上传 + 构建 + 启动（Posh-SSH）
    ├── deploy.sh           # Linux/macOS：同上，使用 sshpass
    │
    │  ── WebUI URL 辅助脚本 ──
    ├── get-url.ps1         # 获取带 token 的启动 URL（Windows）
    └── get-url.sh          # 获取带 token 的启动 URL（Linux/macOS/服务器）
```

## 部署

### 用法（在服务器上执行）

```bash
git clone https://github.com/Macking/dsh-deploy.git "$HOME/dsh-deploy"
cd "$HOME/dsh-deploy"
bash scripts/prepare.sh -m nvidia/Qwen3.8-Flash-Next-FP4-Local -n qwen3.8-flash
bash scripts/start-vllm.sh   # 构建并启动 vLLM 模型服务
bash scripts/start-ai.sh     # 构建并启动 DSH Agent + Nginx，打印 WebUI URL
```
从上面控制台复制WebUI URL，打开浏览器后粘贴回车，即可开始使用。

### 从 Windows 部署（PowerShell）

```powershell
# 部署到默认服务器（192.168.76.12）
.\scripts\deploy.ps1

# 部署到其他服务器
.\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -User myuser -Password mypass

# 通过 SSH 连接一个 IP，但以域名作为公网 URL
.\scripts\deploy.ps1 -RemoteHost 10.0.0.50 -PublicHost dsh.example.com
```

脚本会根据 `-PublicHost`（默认取 `-RemoteHost`）自动更新远程服务器 `.env` 中的
`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST`，无需手动编辑 `.env`。

### 从 Linux/macOS 部署（Bash）

```bash
# 部署到默认服务器（192.168.76.12）
./scripts/deploy.sh

# 部署到其他服务器
REMOTE_HOST=10.0.0.50 REMOTE_USER=myuser REMOTE_PASS=mypass ./scripts/deploy.sh

# 通过 SSH 连接一个 IP，但以域名作为公网 URL
REMOTE_HOST=10.0.0.50 PUBLIC_HOST=dsh.example.com ./scripts/deploy.sh
```

## 配置

### `.env` 文件

| 变量 | 说明 | 默认值 |
|---|---|---|
| `DEEPSEEK_API_KEY` | DeepSeek 模型的 API key（也可在 Web UI 设置中配置） | (空) |
| `DSH_PUBLIC_URL` | dsh 对外通告的浏览器访问 URL | `http://192.168.76.12/` |
| `DSH_TRUSTED_HOST` | dsh 主机信任围栏所允许的浏览器可见主机名 | `192.168.76.12` |

> **部署脚本会自动更新 `DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST`**，使远程 `.env`
> 与目标服务器 IP 匹配（如指定了 `-PublicHost`/`PUBLIC_HOST` 则用该值）。
> 仅在不使用脚本部署时才需手动编辑 `.env`。

### 部署到不同服务器

部署完全不绑定特定 IP —— 项目中没有任何文件硬编码服务器 IP
（`.env` 中的 `192.168.76.12` 仅为默认值，脚本会覆盖）。

**使用部署脚本**（推荐）：
```powershell
# PowerShell — 传入目标 IP 即可
.\scripts\deploy.ps1 -RemoteHost <TARGET_IP> -User <USER> -Password <PASS>
```
```bash
# Bash — 设置 REMOTE_HOST 即可
REMOTE_HOST=<TARGET_IP> REMOTE_USER=<USER> REMOTE_PASS=<PASS> ./scripts/deploy.sh
```

**不使用脚本**（手动），上传文件并在服务器上编辑 `.env`：
```
DSH_PUBLIC_URL=http://<TARGET_IP>/
DSH_TRUSTED_HOST=<TARGET_IP>
```
然后在服务器上执行 `docker compose up -d`。

## 访问 Web UI

部署完成后：
- **Web UI**：`http://<SERVER_IP>/?token=<TOKEN>`
- DSH 需要启动 token 进行认证。从容器日志获取：
  ```bash
  docker logs dsh-harness
  # 查找：dsh web: http://<SERVER_IP>/?token=xxxxxxxx
  ```
- 在浏览器中打开完整 URL（包含 `?token=...`）。DSH 会将 token 换为会话 cookie —— 之后访问无需再带 token。
- 在 Web UI 的 **设置 → 模型** 中配置 DeepSeek API key。

### 使用辅助脚本获取启动 URL

无需手动从日志复制 URL，使用辅助脚本自动提取：

**从 Windows（PowerShell）：**
```powershell
# 默认服务器（192.168.76.12）
.\scripts\get-url.ps1

# 其他服务器
.\scripts\get-url.ps1 -RemoteHost 10.0.0.50 -User myuser -Password mypass

# 等待 URL 出现（部署后立即使用）
.\scripts\get-url.ps1 -Wait

# 仅打印 URL（用于管道传给 Start-Process 等）
.\scripts\get-url.ps1 -Raw
```

**从 Linux/macOS 或直接在服务器上：**
```bash
# 在服务器上直接执行（本地有 docker）
./scripts/get-url.sh

# 从本地机器通过 SSH 执行
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh

# 等待 URL 出现
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --wait

# 仅打印 URL（用于管道传给 curl / xdg-open）
REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --raw
```

`--wait` / `-Wait` 标志每 3 秒轮询一次，直到 URL 出现（默认超时 60 秒）。
这在部署后容器仍在初始化时特别有用。

## 管理部署

以下命令在远程服务器的部署目录中执行（默认 `/home/<USER>/dsh`）：

```bash
# 查看运行中的容器
docker compose ps

# 查看日志
docker logs dsh-harness -f
docker logs dsh-nginx -f

# 重启
docker compose restart

# 停止
docker compose down

# 修改后重新构建
docker compose build && docker compose up -d
```

## 工作原理

### DSH 容器（`dsh-harness`）
- 基于 `node:22-slim`（DSH 要求 Node ^22.19 || >=24）
- 通过 npm 全局安装 `@deepseek-ai/dsh`
- 通过 entrypoint 脚本执行 `dsh web --no-open --public-url $DSH_PUBLIC_URL --trusted-host $DSH_TRUSTED_HOST`，在 `127.0.0.1:3080` 启动 Web UI
- `network_mode: host`，使其监听宿主机的 loopback
- DSH 主目录（`/dsh-home`）和工作区（`/workspace`）以命名卷持久化

### Nginx 容器（`dsh-nginx`）
- 基于 `nginx:1.27-alpine`
- 监听 80 端口，将所有请求代理到 `127.0.0.1:3080`
- 保留 `Host` 头（DSH 信任围栏要求）
- 支持 WebSocket 升级和 SSE 流式传输，用于实时 LLM 输出
- `network_mode: host`，使其能访问 DSH 的 loopback

### 安全说明
- DSH 刻意不绑定 `0.0.0.0` —— 仅在 loopback 上服务
- Nginx 代理是唯一的外部入口
- DSH 的 `--trusted-host` 围栏仅允许配置的浏览器可见主机名
- 启动 URL 中的 token 是进程凭证 —— 仅与授权用户共享
- 生产环境建议在 Nginx 层添加 TLS（HTTPS）
