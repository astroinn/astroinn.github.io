# Astroinn 博客自动部署

推送 `main` 后，GitHub Actions 构建并检查网站，将静态文件发布到公开的 `server-site` 分支，再通过 HTTPS 向 https://202252.xyz/_deploy/blog 发送签名通知。Debian 服务器收到通知才拉取文件，并在拉取成功后切换版本。Nginx 使用只读挂载提供网页。

部署需要 Docker Compose、curl、Python 3、systemd 和提供 HTTPS 的反向代理。服务器经 GitHub API 获取产物分支的提交编号，再从 codeload 下载该提交的归档。

## 分支和服务

| 名称 | 用途 |
| --- | --- |
| `main` | 博客源码、文章和部署配置 |
| `server-site` | Actions 自动维护的静态产物分支，服务器从这里取得发布版本 |
| `astroinn-blog-webhook.service` | 在服务器本机接收签名通知 |
| `astroinn-blog-pull.service` | 手动同步最新版本时使用的单次服务 |

日常更新只需推送 `main`。GitHub Pages 由 [独立工作流](../.github/workflows/pages-deploy.yml) 发布。自建站点由 [服务器工作流](../.github/workflows/server-deploy.yml) 发布。

## 服务器安装

将 deploy 下的配置、脚本和 systemd 服务文件复制到 /opt/astroinn-blog，保持 root 所有。首次安装：

```bash
useradd --system --home-dir /opt/astroinn-blog/data --shell /usr/sbin/nologin blogdeploy
install -d -m 755 -o blogdeploy -g blogdeploy /opt/astroinn-blog/data
chmod 755 /opt/astroinn-blog/pull-site.sh
install -d -m 700 /etc/astroinn-blog
(umask 077; test -e /etc/astroinn-blog/webhook-key || openssl rand -hex 32 > /etc/astroinn-blog/webhook-key)
install -m 644 /opt/astroinn-blog/astroinn-blog-{pull,webhook}.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now astroinn-blog-webhook.service
cd /opt/astroinn-blog && docker compose up -d
```

将服务器密钥文件中的单行内容通过可信通道填入 GitHub 仓库的 Actions Secret BLOG_WEBHOOK_KEY。不要提交密钥或贴到日志。Webhook 仅接收最近五分钟内经过 HMAC-SHA256 验证的通知，并以博客专用用户运行固定拉取脚本。部署失败返回 503，Actions 会重试。旧版本保持可用。

## 1Panel 反代与发布验证

1. 在 1Panel 为 `202252.xyz` 配置 HTTPS，将 `/` 转发到 `http://127.0.0.1:8080`。
2. 将 `/_deploy/blog` 精确匹配并转发到 `http://127.0.0.1:8097`，保留签名请求头。可参考 [OpenResty 路由配置](1panel-webhook-location.conf)。
3. 将改动合入 main，检查工作流 Build and Deploy to Server 的通知步骤及公网首页。GitHub Pages 使用自己的工作流。
4. 检查首篇文章、搜索及图片。图片继续使用 img.202252.xyz。

```bash
journalctl -u astroinn-blog-webhook.service -n 30 --no-pager
cd /opt/astroinn-blog && docker compose ps
curl --fail -I https://202252.xyz/
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  --data-binary '{}' https://202252.xyz/_deploy/blog
```

首页应返回 `200`，未签名通知应返回 `403`。Actions 的通知步骤成功代表服务器已验签并同步，返回 `204`。公网通知返回 `404` 时，检查 1Panel 是否配置了精确路由。返回 `503` 时，查看 Webhook 日志里的下载或解包错误。

修复后可重跑 `main` 的最新工作流。也可以在服务器上执行 `sudo systemctl start astroinn-blog-pull.service` 手动同步。构建内容无变化时，工作流也会补发通知。

## 回滚

执行以下命令前停用接收服务，避免收到新通知又切回。修复并发布后重新启动接收服务，再手动重跑最新工作流。

```bash
systemctl stop astroinn-blog-webhook.service
cd /opt/astroinn-blog/data
test -L previous && test -s previous/index.html || exit 1
ln -sfn "$(readlink previous)" current.rollback
mv -Tf current.rollback current
```

发布目录会保留历史版本。清理时保留 current 和 previous 指向的版本。
