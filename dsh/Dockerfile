FROM node:22-slim
LABEL maintainer="dsh-deploy"
LABEL description="DeepSeek Harness (dsh) — official open-source agent harness"

ARG APT_MIRROR=mirrors.aliyun.com

# DSH requires: Node ^22.19 || >=24. node:22-slim ships 22.x.
# Install system deps: git (dsh workspace), bash, curl for healthcheck
# 合并apt操作，安装后立即清理apt缓存
RUN set -eux; \
    sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" \
        /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git bash curl ca-certificates zip unzip; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean

# 配置国内npm镜像
RUN npm config set registry https://registry.npmmirror.com

# Working directory for dsh sessions and workspace
WORKDIR /workspace

# DSH stores its home/config under $DSH_HOME (default ~/.dsh).
# We use /dsh-home so it persists via a named volume.
ENV DSH_HOME=/dsh-home
RUN mkdir -p $DSH_HOME

# Pre-install pnpm + dsh CLI，安装完成后清理npm/pnpm缓存
RUN npm install -g pnpm \
    && npm install -g @deepseek-ai/dsh@latest \
    && npm cache clean --force \
    && rm -rf /root/.npm /root/.local/share/pnpm /root/.pnpm-store

# DSH binds to 127.0.0.1:3080 by design (loopback only, per official docs).
# nginx (separate container, same host network) proxies to 127.0.0.1:3080.
EXPOSE 3080

# Entrypoint script translates DSH_PUBLIC_URL / DSH_TRUSTED_HOST env vars
# into the corresponding --public-url / --trusted-host CLI flags that
# dsh web requires for the reverse-proxy trust fence.
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
RUN chmod +x /usr/local/bin/dsh-entrypoint.sh

ENTRYPOINT ["dsh-entrypoint.sh"]
