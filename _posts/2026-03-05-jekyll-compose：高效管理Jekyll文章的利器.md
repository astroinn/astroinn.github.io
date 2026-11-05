---
title: "jekyll-compose：高效管理 Jekyll 文章的利器"
date: 2026-03-05 10:00:00 +0800
categories: [工具]
tags: [Jekyll, jekyll-compose, 博客, 写作效率]
---

## 前言

手动在 `_posts/` 目录创建 `YYYY-MM-DD-title.md` 文件、复制粘贴 Front Matter 模板……时间久了你一定觉得繁琐。**jekyll-compose** 是 Jekyll 官方维护的插件，为你提供一组便捷的命令行工具，让文章的创建、发布、重命名都变成一条命令的事。

---

## 安装

在项目根目录的 `Gemfile` 中添加：

```ruby
gem 'jekyll-compose', group: [:jekyll_plugins]
```

然后执行：

```bash
bundle install
```

验证安装是否成功：

```bash
bundle exec jekyll help
```

如果输出中出现 `draft`、`post`、`publish`、`unpublish`、`rename`、`compose` 等子命令，说明安装完成。

---

## 核心命令一览

| 命令 | 作用 | 示例 |
|------|------|------|
| `jekyll draft "标题"` | 创建草稿到 `_drafts/` | `jekyll draft "Redis缓存策略"` |
| `jekyll post "标题"` | 直接创建文章到 `_posts/` | `jekyll post "Docker入门指南"` |
| `jekyll publish <草稿路径>` | 将草稿发布为文章 | `jekyll publish _drafts/redis缓存策略.md` |
| `jekyll unpublish <文章路径>` | 将文章退回草稿 | `jekyll unpublish _posts/2026-03-05-redis缓存策略.md` |
| `jekyll page "标题"` | 创建新页面 | `jekyll page "关于我"` |
| `jekyll rename <路径> "新标题"` | 重命名文章或草稿 | `jekyll rename _posts/2026-03-05-旧标题.md "新标题"` |
| `jekyll compose "标题"` | 通用创建（默认为文章） | `jekyll compose "Nginx配置详解"` |

> 所有命令前需加 `bundle exec`，例如 `bundle exec jekyll post "标题"`。
{: .prompt-info }

---

## 推荐工作流：草稿 → 发布

相比直接创建文章，使用 **草稿工作流** 更加规范：

### 第一步：创建草稿

```bash
bundle exec jekyll draft "Kubernetes Pod 生命周期详解"
```

这会在 `_drafts/` 目录生成 `kubernetes-pod-生命周期详解.md`，文件中自动包含基础 Front Matter。

### 第二步：本地预览草稿

```bash
bundle exec jekyll serve --drafts
```

加上 `--drafts` 参数后，草稿会以当天日期出现在站点中，方便预览效果。

### 第三步：写完后发布

```bash
bundle exec jekyll publish _drafts/kubernetes-pod-生命周期详解.md
```

插件会自动：
- 在文件名前加上当天日期（如 `2026-03-05-kubernetes-pod-生命周期详解.md`）
- 将文件从 `_drafts/` 移动到 `_posts/`
- 在 Front Matter 中添加 `date` 字段

### 需要撤回？

```bash
bundle exec jekyll unpublish _posts/2026-03-05-kubernetes-pod-生命周期详解.md
```

文件会被移回 `_drafts/`，日期前缀也会被去掉。

---

## 自定义 Front Matter 模板

这是 jekyll-compose 最实用的功能之一。在 `_config.yml` 中添加以下配置，每次创建文章/草稿时会自动填充你定义的 Front Matter：

```yaml
jekyll_compose:
  default_front_matter:
    posts:
      description:
      categories: []
      tags: []
      math: false
      mermaid: false
    drafts:
      description:
      categories: []
      tags: []
      math: false
      mermaid: false
```

配置后，执行 `jekyll post "测试"` 生成的文件内容如下：

```markdown
---
layout: post
title: 测试
date: 2026-03-05 10:00:00 +0800
description:
categories: []
tags: []
math: false
mermaid: false
---
```

> 如果使用的主题（如 Chirpy）已有默认 layout，可以不在模板中写 `layout`。
{: .prompt-tip }

---

## 创建后自动打开编辑器

### 方式一：配置 `_config.yml`

```yaml
jekyll_compose:
  auto_open: true
```

### 方式二：设置环境变量

告诉 jekyll-compose 用哪个编辑器打开：

**Windows PowerShell：**

```powershell
# 当前会话生效
$env:JEKYLL_EDITOR = "code"

# 永久写入用户环境变量
[Environment]::SetEnvironmentVariable("JEKYLL_EDITOR", "code", "User")
```

**Linux / macOS：**

```bash
# 写入 ~/.bashrc 或 ~/.zshrc
export JEKYLL_EDITOR="code"
```

配置完成后，每次创建文章时 VS Code 会自动打开对应文件。

---

## 自定义文件名格式

默认情况下，jekyll-compose 会将标题中的空格替换为 `-`。如果需要自定义文件名 slug，可以在创建时使用 `--source` 指定，或者创建后用 `rename` 命令修改：

```bash
# 创建后觉得文件名太长，重命名
bundle exec jekyll rename _posts/2026-03-05-kubernetes-pod-生命周期详解.md "K8s Pod 生命周期"
```

重命名会同时更新文件名和 Front Matter 中的 `title`。

---

## 实战演示

完整演示从创建到发布的全流程：

```bash
# 1. 创建草稿
bundle exec jekyll draft "Git 常用命令速查表"
# => _drafts/git-常用命令速查表.md

# 2. 编辑内容（VS Code 自动打开）
# ... 编写文章 ...

# 3. 本地预览
bundle exec jekyll serve --drafts

# 4. 满意后发布
bundle exec jekyll publish _drafts/git-常用命令速查表.md
# => _posts/2026-03-05-git-常用命令速查表.md

# 5. 发现标题需要调整
bundle exec jekyll rename _posts/2026-03-05-git-常用命令速查表.md "Git 命令速查手册"
# => _posts/2026-03-05-git-命令速查手册.md
```

---

## 常见问题

### Q：为什么执行命令提示找不到 `draft` 子命令？

确保 `Gemfile` 中将插件放在 `jekyll_plugins` 组内，并且已经执行过 `bundle install`：

```ruby
gem 'jekyll-compose', group: [:jekyll_plugins]
```

### Q：发布时能否指定日期？

可以，使用 `--date` 参数：

```bash
bundle exec jekyll publish _drafts/文章.md --date "2026-01-01"
```

### Q：能和 GitHub Pages 一起使用吗？

jekyll-compose 只是本地命令行工具，它帮你生成和管理文件，不参与站点构建。所以不管你用 GitHub Pages 还是其他方式部署，都完全兼容。

---

## 总结

| 场景 | 以前 | 用 jekyll-compose |
|------|------|-------------------|
| 创建文章 | 手动建文件、写日期前缀、复制 Front Matter | `jekyll post "标题"` 一步到位 |
| 管理草稿 | 手动在文件夹间移动、改文件名 | `draft` → `publish` → `unpublish` |
| 重命名 | 改文件名 + 改 Front Matter 中的 title | `jekyll rename` 自动同步 |
| Front Matter | 每次复制粘贴模板 | 配置一次，自动生成 |

jekyll-compose 虽然小巧，但能显著提升 Jekyll 博客的日常写作效率。推荐每个 Jekyll 用户都装上。

---

## 参考

- [jekyll-compose GitHub 仓库](https://github.com/jekyll/jekyll-compose)
- [Jekyll 官方文档](https://jekyllrb.com/docs/)
