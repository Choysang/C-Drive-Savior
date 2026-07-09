# C Drive Savior / C盘拯救者

面向 Windows 的 C 盘空间诊断与安全清理 Skill。

你只需要跟 Agent 说一句：

```text
C 盘快满了
```

或者：

```text
帮我清理一下电脑空间
```

它就会先只读扫描 Windows 系统盘，分析 C 盘到底被什么占满，然后生成一份本地可打开的可视化报告。

它不是普通的“无脑清理工具”。

很多清理软件只会告诉你“发现 12GB 垃圾文件”，但不会解释这些文件到底是什么，也不会告诉你删完会不会影响登录状态、软件配置、项目文件、聊天记录、卸载修复能力，或者 Windows 更新恢复能力。

C Drive Savior 的核心是让 Agent 帮你判断，而不是让软件按固定规则乱删。

## 它会做什么

报告会把 C 盘空间拆清楚：

- 哪些目录占用最大
- 哪些是系统缓存、临时文件、浏览器缓存、开发工具缓存
- 哪些是下载目录、桌面、用户文件、安装包、压缩包
- 哪些是微信/浏览器/软件缓存等需要人工确认的内容
- 哪些是 Windows 核心目录、安装目录、恢复目录，不能手动乱删
- 哪些文件可以迁移到 D 盘，且不影响实际使用

每一项都会尽量给出：

- 具体路径
- 占用大小
- 风险等级
- 清理建议
- 删除或移动后的影响
- 是否需要用户确认

## 风险分级

### 绿：可优先清理

主要是临时文件、系统缓存、浏览器缓存、安装残留、npm/pnpm/pip/uv/Playwright 等可重建缓存。

删除后通常不会影响正常使用，系统或软件需要时会重新生成。

### 黄：确认后处理

可能包含用户文件、下载内容、聊天软件缓存、离线视频、项目目录、压缩包、大型安装包、软件修复缓存、OEM 恢复包等。

Agent 会给出建议，但不会替你直接删除，避免误删重要资料。

### 红：不建议手动删除

包括 Windows 核心目录、程序运行文件、配置数据库、Windows Installer 缓存、WinSxS、System32、SysWOW64、SystemApps、Program Files 等。

Agent 只解释它们为什么占空间，并引导你使用系统工具或卸载器，不提供危险的一键删除。

### Move：适合迁移到 D 盘

包括 Downloads、Documents、Pictures、Videos、Desktop、大型安装包、压缩包、项目资料、数据集、模型文件等用户可控内容。

它会优先建议安全迁移方式，而不是把软件安装目录直接拖到 D 盘。

## 安全原则

- 默认只扫描，不动文件。
- 所有清理动作都需要用户主动确认。
- 高风险目录不会给一键删除。
- 用户资料类文件不会自动清理。
- 系统关键路径只分析，不手动操作。
- 删除前说明影响，删除后生成清理报告。
- 能通过卸载器、Storage Sense、Disk Cleanup、DISM 等官方方式处理的内容，优先使用官方方式。

## 适合解决的问题

- C 盘突然爆满
- 不知道哪些文件能删
- 微信、浏览器、系统缓存越来越大
- 下载目录和桌面堆满安装包
- 清理软件扫出来一堆东西但不敢点删除
- 想知道 C 盘到底被什么吃掉了
- 想把能移动的文件安全转移到 D 盘
- 想清理开发工具缓存，比如 npm、pnpm、pip、uv、Playwright、Chrome 模型缓存

## 你可以这样触发

```text
C 盘满了
帮我看看 C 盘
清理一下系统盘
分析一下电脑空间
看看哪些文件占用最大
帮我安全释放 C 盘空间
哪些东西可以移到 D 盘
```

## 工作流程

1. 只读扫描 C 盘，输出当前磁盘占用面板。
2. 同一级目录按大小从大到小排序。
3. 默认只排查超过 1GB 的内容。
4. 先处理可重建缓存和临时文件。
5. 再让用户确认软件修复包、旧更新文件、恢复文件、下载文件和用户资料。
6. 对适合迁移的内容给出 D 盘迁移方案。
7. 执行后生成清理报告，记录清理了什么、释放多少空间、哪些被跳过。

## 安装

把这个仓库克隆到 Codex skills 目录：

```powershell
$skills = "$env:USERPROFILE\.codex\skills"
New-Item -ItemType Directory -Force $skills
git clone https://github.com/Choysang/C-Drive-Savior.git "$skills\c-drive-savior"
```

如果你设置了自定义 `CODEX_HOME`，请把仓库放到：

```text
$CODEX_HOME\skills\c-drive-savior
```

然后重启 Codex。

## 手动运行扫描面板

Skill 内置一个只读扫描脚本：

```powershell
python ".\scripts\c_drive_panel.py" --threshold-gb 1 --open
```

它会生成：

- `c-drive-scan-*.json`
- `c-drive-panel-*.html`

HTML 文件可以直接在浏览器打开，用来快速查看 C 盘空间结构。

## 重要提醒

这个项目的目标不是“暴力清空”，而是先把空间占用讲明白，再做低风险、可确认、可追溯的清理。

它不会鼓励你手动删除这些目录：

- `C:\Windows\System32`
- `C:\Windows\SysWOW64`
- `C:\Windows\WinSxS`
- `C:\Windows\Installer`
- `C:\Windows\SystemApps`
- `C:\Program Files`
- `C:\Program Files (x86)`

一句话总结：

> C Drive Savior 是一个面向 Windows 的 C 盘空间诊断和安全清理 Skill。它不追求“暴力清空”，而是先把空间占用讲明白，再帮你做低风险、可确认、可追溯的清理。

## License

MIT
