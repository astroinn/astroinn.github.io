# Astroinn 博客自动部署

推送 main 后，GitHub Actions 构建并检查网站，将静态文件发布到公开的 server-site 分支，再通过 HTTPS 向 https://202252.xyz/_deploy/blog 发送签名通知。Debian 服务器收到通知才拉取文件，并在拉取成功后切换版本。Nginx 使用只读挂载提供网页。

部署需要 Docker Compose、curl、Python 3、systemd 和提供 HTTPS 的反向代理。服务器经 GitHub API 获取产物分支的提交编号，再从 codeload 下载该提交的归档。

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

## 公网入口与首次发布

1. 将 202252.xyz 解析到站点的公网入口，在反向代理上配置 HTTPS，站点代理目标为 http://127.0.0.1:8080。
2. 在此站点的 HTTPS server 块添加 1panel-webhook-location.conf 中的精确路径规则，保存前验证 OpenResty 配置。
3. 将改动合入 main，检查工作流 Build and Deploy to Server 的通知步骤及公网首页。GitHub Pages 使用自己的工作流。
4. 检查首篇文章、搜索及图片。图片继续使用 img.202252.xyz。

```bash
journalctl -u astroinn-blog-webhook.service -n 30 --no-pager
cd /opt/astroinn-blog && docker compose ps
curl --fail -I https://202252.xyz/
```

若通知失败，可修复入口后重跑 main 的最新工作流，或通过私网 SSH 执行 systemctl start astroinn-blog-pull.service。构建内容无变化时也会发送通知，便于补发。

## 回滚

执行以下命令前停用接收服务，避免收到新通知又切回。修复并发布后重新启动接收服务，再手动重跑最新工作流。

```bash
systemctl stop astroinn-blog-webhook.service
cd /opt/astroinn-blog/data
test -L previous && test -s previous/index.html
ln -sfn "$(readlink previous)" current.rollback
mv -Tf current.rollback current
```

发布目录会保留历史版本。清理时保留 current 和 previous 指向的版本。
