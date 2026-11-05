---
title: "TOML：迄今最适合 Python 项目的配置语言"
date: 2024-12-30 8:00:00 +0800
categories: [Python Features]
tags: [Python, toml]
---

Python、Java 用来编写和运行程序；JSON、YAML 和 TOML 则主要用来表示数据。写 Python 项目的配置文件时，我尤其喜欢 TOML：语法简洁，数据类型也能自然地映射到 Python。Python 项目常用的 `pyproject.toml`，就是一个典型例子。

下面从一份 `config.toml` 开始，看看它的基本语法，以及如何在 Python 中读取它。

## TOML 的基本语法

如果你使用 VS Code，可以按需安装 *Even Better TOML* 扩展，获得更丰富的编辑体验。

### 注释与键值对

TOML 用 `#` 表示注释，既可以单独占一行，也可以写在键值对后面。键和值用 `=` 连接：

```toml
# config.toml
name = 'Astroinn'
version = 1
enabled = true
topics = ['Python', 'TOML', 'blogging']
created_at = 2024-12-30T00:00:00Z
```

单引号和双引号都能表示字符串，但两者并不完全相同。双引号字符串支持 `\n` 等转义序列；单引号字符串按字面保留内容。例如：

```toml
description = "Astroinn says: \"Hello!\""
```

这里的整数、布尔值、字符串和数组都很直观。`created_at` 也不是普通字符串，而是带 UTC 时区的日期时间值。更多类型和语法细节可以查阅 [TOML 规范](https://toml.io/en/v1.0.0)。

### 用 Python 读取 TOML

Python 3.11 起，标准库提供了只负责读取 TOML 的 `tomllib`。把上面的内容保存为 `config.toml`，再运行：

```python
# read_toml.py
import tomllib
from pprint import pp

with open('config.toml', 'rb') as f:
    config = tomllib.load(f)

pp(config)
```

`tomllib.load()` 接收以二进制模式打开的文件，所以这里使用 `'rb'`。输出类似下面这样：

```text
{'name': 'Astroinn',
 'version': 1,
 'enabled': True,
 'topics': ['Python', 'TOML', 'blogging'],
 'created_at': datetime.datetime(2024, 12, 30, 0, 0, tzinfo=datetime.timezone.utc)}
```

可以看到，TOML 的整数、布尔值和数组分别变成了 Python 的 `int`、`bool` 和 `list`，带时区的日期时间变成了 `datetime.datetime`。如果使用 Python 3.10 或更早版本，可以选择第三方解析库；上面的 `tomllib` 代码需要 Python 3.11 或更新版本。具体类型映射见 [Python 官方文档](https://docs.python.org/3/library/tomllib.html)。

### 内联表

TOML 的表对应 Python 的字典。内容较少时，可以用花括号写成内联表：

```toml
shape = { height = 1, weight = 50 }
```

解析后，`config['shape']` 是 `{'height': 1, 'weight': 50}`。内联表适合简短的数据；内容变多时，普通表更容易阅读。

### 普通表与嵌套表

用方括号声明表，后面的键值对就属于这个表，直到遇到下一个表头：

```toml
[account]
bilibili = 'astroinnB'
youtube = 'astroinnY'
```

这会得到 `{'account': {'bilibili': 'astroinnB', 'youtube': 'astroinnY'}}`。如果一个平台需要保存多个字段，可以用点号创建嵌套结构：

```toml
[account]
bilibili.username = 'astroinnB'
bilibili.followers = 100
youtube = 'astroinnY'
```

此时 `config['account']['bilibili']` 是 `{'username': 'astroinnB', 'followers': 100}`。字段多了之后，还可以改用嵌套表，让同一平台的配置放在一起：

```toml
[account]
youtube = 'astroinnY'

[account.bilibili]
username = 'astroinnB'
followers = 100
```

上面两段配置会解析成相同的结构。它们是两种独立写法，不要同时放进同一个文件，否则会重复定义键。

### 表数组

如果每个平台都需要相同的字段，可以把它们组织成一组表。TOML 使用双层方括号 `[[account]]` 表示表数组：

```toml
[[account]]
platform = 'bilibili'
username = 'astroinnB'

[[account]]
platform = 'youtube'
username = 'astroinnY'
```

解析后，`config['account']` 是一个列表，里面依次放着两个字典：

```python
[
    {'platform': 'bilibili', 'username': 'astroinnB'},
    {'platform': 'youtube', 'username': 'astroinnY'},
]
```

这一段也是独立示例：普通表 `[account]` 和表数组 `[[account]]` 不能在同一份 TOML 文件中定义为同一个键。

## 为什么使用专门的配置格式

直接用 Python 文件写配置也可以，但导入模块时会执行其中的代码。TOML 是数据格式，解析配置时不会执行任意 Python 语句；同时，它的类型明确，适合保存项目设置。不过，数据格式本身并不能保证配置内容可信，也不适合把真实密码直接写进会提交到仓库的文件。

对 Python 项目来说，TOML 的实用之处在于：写起来清楚，读入后又能方便地得到字典、列表和日期时间等 Python 对象。需要项目配置时，可以先从一份简单的 `config.toml` 开始。
