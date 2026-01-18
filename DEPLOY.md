# Nitter 部署指南

## 使用 Docker Secrets 本地部署

### 方式一：Docker Compose with .env（开发环境）

1. 创建 `.env` 文件（参考 `.env.example`）：
```bash
NITTER_SESSION_KIND=cookie
NITTER_SESSION_USERNAME=your_username
NITTER_SESSION_ID=your_id
NITTER_SESSION_AUTH_TOKEN=your_token
NITTER_SESSION_CT0=your_ct0
```

2. 构建并启动：
```bash
docker-compose build --no-cache
docker-compose up -d
```

### 方式二：Docker Secrets（生产环境）

1. 创建 Docker secrets：
```bash
# 创建 session auth_token secret
echo "your_auth_token_here" | docker secret create nitter_auth_token -

# 创建 session ct0 secret
echo "your_ct0_here" | docker secret create nitter_ct0 -

# 创建 session username secret
echo "your_username" | docker secret create nitter_username -

# 创建 session id secret
echo "your_id" | docker secret create nitter_id -
```

2. 更新 `docker-compose.yml` 使用 secrets：
```yaml
version: "3.9"

services:
  nitter:
    build: .
    image: nitter:local
    container_name: nitter-kurrna
    secrets:
      - nitter_auth_token
      - nitter_ct0
      - nitter_username
      - nitter_id
    environment:
      - NITTER_SESSION_KIND=cookie
      - NITTER_SESSION_USERNAME_FILE=/run/secrets/nitter_username
      - NITTER_SESSION_ID_FILE=/run/secrets/nitter_id
      - NITTER_SESSION_AUTH_TOKEN_FILE=/run/secrets/nitter_auth_token
      - NITTER_SESSION_CT0_FILE=/run/secrets/nitter_ct0
    ports:
      - "8080:8080"
    depends_on:
      - nitter-redis
    restart: unless-stopped

secrets:
  nitter_auth_token:
    external: true
  nitter_ct0:
    external: true
  nitter_username:
    external: true
  nitter_id:
    external: true
```

## 部署到 Fly.io

### 前置要求

1. 安装 flyctl：
```bash
# Windows (PowerShell)
pwsh -Command "iwr https://fly.io/install.ps1 -useb | iex"

# macOS/Linux
curl -L https://fly.io/install.sh | sh
```

2. 登录 Fly.io：
```bash
flyctl auth login
```

### 部署步骤

1. **初始化应用**（如果还没有创建）：
```bash
# fly.toml 已存在，跳过此步
# flyctl launch
```

2. **设置 Secrets**（重要！）：
```bash
# 设置 Twitter session 相关的敏感信息
flyctl secrets set \
  NITTER_SESSION_KIND=cookie \
  NITTER_SESSION_USERNAME=your_username \
  NITTER_SESSION_ID=your_id \
  NITTER_SESSION_AUTH_TOKEN=your_auth_token \
  NITTER_SESSION_CT0=your_ct0
```

3. **创建 Redis 数据库**：
```bash
# 创建 Upstash Redis（Fly.io 推荐）
flyctl redis create

# 或使用 Fly.io 内置 Redis
# 需要更新 docker-compose.yml 或创建单独的 fly.toml
```

如果使用 Upstash Redis，更新 `nitter.conf` 中的 Redis 连接信息，或通过环境变量：
```bash
flyctl secrets set \
  NITTER_REDIS_HOST=your-redis-host.upstash.io \
  NITTER_REDIS_PORT=6379 \
  NITTER_REDIS_PASSWORD=your-redis-password
```

4. **部署应用**：
```bash
# 部署到 Fly.io
flyctl deploy

# 查看部署状态
flyctl status

# 查看日志
flyctl logs
```

5. **验证部署**：
```bash
# 打开应用
flyctl open

# 或访问 https://nitter-kurrna.fly.dev
```

### 更新 Secrets

```bash
# 单独更新某个 secret
flyctl secrets set NITTER_SESSION_AUTH_TOKEN=new_token

# 查看已设置的 secrets（不会显示值）
flyctl secrets list

# 删除 secret
flyctl secrets unset NITTER_SESSION_AUTH_TOKEN
```

### 扩展和监控

```bash
# 查看应用资源使用情况
flyctl status

# 扩展机器实例
flyctl scale count 2

# 修改机器规格
flyctl scale vm shared-cpu-1x --memory 2048

# 查看实时日志
flyctl logs -f
```

### 故障排查

1. **检查 secrets 是否正确设置**：
```bash
flyctl secrets list
```

2. **查看应用日志**：
```bash
flyctl logs
```

3. **进入容器调试**：
```bash
flyctl ssh console
```

4. **检查环境变量**：
```bash
flyctl ssh console -C "env | grep NITTER"
```

### 注意事项

1. **不要将 .env 文件提交到 Git**：确保 `.env` 在 `.gitignore` 中
2. **使用 Fly.io secrets**：所有敏感信息必须通过 `flyctl secrets set` 设置
3. **Redis 连接**：确保 Nitter 能正确连接到 Redis（Upstash 或 Fly.io 内置）
4. **域名配置**：可以通过 `flyctl certs add your-domain.com` 添加自定义域名
5. **定期更新 session**：Twitter session 可能过期，需要定期更新 secrets

### 本地测试 Fly.io 构建

```bash
# 本地构建 Dockerfile（模拟 Fly.io 构建）
flyctl deploy --build-only --local-only

# 本地运行构建的镜像
docker run -p 8080:8080 \
  -e NITTER_SESSION_KIND=cookie \
  -e NITTER_SESSION_USERNAME=your_username \
  -e NITTER_SESSION_ID=your_id \
  -e NITTER_SESSION_AUTH_TOKEN=your_token \
  -e NITTER_SESSION_CT0=your_ct0 \
  registry.fly.io/nitter-kurrna:latest
```

## 获取 Twitter Session 信息

使用项目提供的工具获取 session：

```bash
# 使用 curl 方式（推荐）
python3 tools/create_session_curl.py username password totp_seed

# 使用浏览器方式
python3 tools/create_session_browser.py username password totp_seed

# 输出示例：
# {"kind": "cookie", "username": "...", "id": "...", "auth_token": "...", "ct0": "..."}
```

将输出的 `auth_token`、`ct0`、`id`、`username` 分别设置到对应的环境变量或 secrets 中。
