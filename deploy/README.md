# 博客部署

推送 `main` 后，Actions 构建并发布静态文件到 `server-site`，然后向 `https://202252.xyz/_deploy/blog` 发送签名通知。Compose 里的 Webhook 容器验签，同步容器下载归档并更新 `data/current`，Nginx 读取该目录提供网页。

## 安装

需要 Docker Compose 2.23.1 或更新版本。将 `compose.yaml` 放在 `/opt/astroinn-blog`。已有服务器可复用发布目录和密钥。全新安装以 root 执行：

```bash
cd /opt/astroinn-blog
install -d -o 999 -g 996 -m 755 data
install -d -m 700 /etc/astroinn-blog
(umask 077; test -e /etc/astroinn-blog/webhook-key || openssl rand -hex 32 > /etc/astroinn-blog/webhook-key)
docker compose up -d
```

把密钥保存为仓库的 Actions Secret `BLOG_WEBHOOK_KEY`。在 1Panel 为站点配置 HTTPS，首页代理到 `127.0.0.1:8080`，Webhook 使用以下路由：

```nginx
location = /_deploy/blog {
    limit_except POST { deny all; }
    client_max_body_size 1k;
    client_body_timeout 5s;
    proxy_connect_timeout 3s;
    proxy_read_timeout 90s;
    proxy_pass http://127.0.0.1:8097;
}
```

## 验证和恢复

首页返回 `200`，未签名的 Webhook 请求返回 `403`，Actions 的有效通知返回 `204`。可用 `docker compose logs --tail=50 webhook sync` 查看日志。手动同步最新版本：

```bash
docker compose exec -T sync python3 /pull-site.py
```

需要回滚时，先停止 Webhook，切回 `data/previous`，避免新通知覆盖回滚结果：

```bash
docker compose stop webhook
(
    cd data || exit 1
    test -L previous && test -s previous/index.html || exit 1
    ln -sfn "$(readlink previous)" current.rollback
    mv -Tf current.rollback current
)
```

修复后执行 `docker compose start webhook`，再重跑 [部署工作流](../.github/workflows/server-deploy.yml)。
