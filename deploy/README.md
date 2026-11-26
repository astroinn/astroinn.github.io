# 博客部署

推送 `main` 后，GitHub Actions 构建网站，将静态文件发布到公开的 `server-site` 分支，再发送签名 Webhook。服务器下载对应提交的归档，验证首页后切换 Nginx 使用的版本。GitHub Pages 由独立工作流发布。

## 首次安装

服务器需要 Docker Compose、curl、Python 3、OpenSSL、systemd 和 HTTPS 反代。将 `compose.yaml`、`nginx.conf`、`webhook.py`、`pull-site.sh` 和两份 `.service` 文件放到 `/opt/astroinn-blog`，由 root 持有。以 root 执行：

```bash
useradd --system --home-dir /opt/astroinn-blog/data --shell /usr/sbin/nologin blogdeploy
install -d -m 755 -o blogdeploy -g blogdeploy /opt/astroinn-blog/data
cd /opt/astroinn-blog
chmod 755 pull-site.sh
install -d -m 700 /etc/astroinn-blog
(umask 077; test -e /etc/astroinn-blog/webhook-key || openssl rand -hex 32 > /etc/astroinn-blog/webhook-key)
install -m 644 astroinn-blog-{pull,webhook}.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now astroinn-blog-webhook.service
docker compose up -d
```

将 `/etc/astroinn-blog/webhook-key` 中的密钥保存为 GitHub Actions Secret `BLOG_WEBHOOK_KEY`。

## 1Panel 反代

为 `202252.xyz` 配置 HTTPS，首页反代到 `http://127.0.0.1:8080`。在同一站点的 HTTPS 配置中添加 Webhook 的精确路由。

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

## 验证与恢复

首页返回 `200`，未签名的 Webhook 请求返回 `403`。Actions 的通知步骤收到 `204` 表示同步完成。公网通知返回 `404` 时检查精确路由，返回 `503` 时检查同步日志。

```bash
curl --fail -I https://202252.xyz/
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  --data-binary '{}' https://202252.xyz/_deploy/blog
journalctl -u astroinn-blog-webhook.service -n 30 --no-pager
```

手动同步可执行 `sudo systemctl start astroinn-blog-pull.service`，也可重跑 [服务器部署工作流](../.github/workflows/server-deploy.yml)。

需要回滚时，以 root 停止 Webhook 并切回上一版。修复后重新启动 Webhook，再重跑工作流。

```bash
systemctl stop astroinn-blog-webhook.service
cd /opt/astroinn-blog/data
test -L previous && test -s previous/index.html || exit 1
ln -sfn "$(readlink previous)" current.rollback
mv -Tf current.rollback current
```
