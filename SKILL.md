---
name: c-drive-savior
description: Next-Generation Agent-Native Windows Storage Engine (C-Drive-Savior 2026+). Full disk diagnosis, precision cache cleaning, transactional NTFS Junction relocation to D:, and Shell32 Known Folder redirection. Features native Model Context Protocol (FastMCP 2026) JSON-RPC server, FastAPI REST backend, and zero-build glassmorphism web console. Use whenever the user asks to clean C drive, free up disk space, migrate files to D:, inspect storage, or when autonomous agents need storage management tools.
---

# C Drive Savior 2026+ | Agent-Native Storage Subsystem

专为 2026+ 超级智能体（Claude Opus/Fable, GPT-6, Gemini 3.8 等）与现代系统设计的高性能 Windows C 盘优化引擎。采用 Python 3.12+ 原生 WinAPI 内核、FastMCP 2026 协议与零构建前后端完全分离架构。

## 🎯 核心工作流程 (Core Workflow)

AI Agent 与开发者运维标准工作流：

```text
 1. 深度诊断 (Scan)       ──► FastScanner 并发剖析 + Cognitive Guard 压缩摘要
 2. 决策与规划 (Plan)    ──► 区分 GREEN(安全缓存) / MOVE(可迁资产) / RED(系统禁区)
 3. 原子执行 (Execute)    ──► 原生 _winapi Junction 软链接搬迁 / Shell32 文件夹重定向
 4. 实时监控 (Console)   ──► FastAPI 异步后端 + 零构建 Vue 3 赛博朋克控制台
```

---

## 🛠️ CLI 极速运维指令 (CLI Reference)

在终端中直接运行标准模块命令：

```powershell
# 1. 极速全盘空间剖析与摘要报告
python -m c_drive_savior scan

# 2. 输出机器可读的结构化 JSON 数据
python -m c_drive_savior scan --json

# 3. 启动交互式 Web 控制台与 REST API (端口 8999)
python -m c_drive_savior serve --port 8999

# 4. 安全清理指定缓存目录
python -m c_drive_savior clean "%LOCALAPPDATA%\uv"

# 5. 事务性将大目录搬迁至 D 盘并在原位置建立无缝 NTFS Junction 软链接
python -m c_drive_savior relocate "C:\Users\username\.codex" --dest "D:\MovedFromC\.codex"

# 6. 重定向 Windows 已知文件夹 (Documents / Downloads) 到 D 盘
python -m c_drive_savior redirect Documents "D:\Documents"
python -m c_drive_savior redirect Downloads "D:\Downloads"

# 7. 启动 FastMCP JSON-RPC Stdio 服务 (供 Agent 工具挂载)
python -m c_drive_savior mcp
```

---

## 🤖 FastMCP 2026 Agent 工具契约 (MCP Tools)

系统原生支持 Model Context Protocol (MCP)。Agent 可直接发现并调用下列高信噪比工具：

| 工具名称 (Tool Name) | 核心功能与信噪比设计 |
| :--- | :--- |
| `get_c_drive_overview` | 返回由 **Cognitive Guard** 压缩的盘符容量、Top 5 空间占用与可释放潜力的精炼摘要（< 400 Tokens）。 |
| `list_cleanup_candidates` | 游标分页获取经知识库分类的 GREEN 可安全清理缓存目录。 |
| `list_migration_candidates` | 游标分页获取适合迁往 D 盘的重点数据资产（AI 工具链、包管理器环境等）。 |
| `plan_relocation` | Dry-run 预检目录搬迁：计算占用体积、校验跨盘符空间与进程冲突。 |
| `execute_relocation` | 执行原子三步搬迁（备份重命名 -> 跨盘移动 -> 原生 Junction 创建），失败自动回滚。 |
| `clean_cache` | 执行安全缓存清理（具备重解析点穿透保护与进程锁检查）。 |
| `redirect_known_folder` | 动态调用 Shell32 原生重定向“文档”或“下载”目录至次级驱动器。 |
| `get_known_folders` | 获取当前用户所有已知文件夹的实际目标路径。 |

---

## 🔒 安全红线与认知护栏 (Safety Boundaries)

1. **绝对禁区 (RED Tiers)**：严禁手删 `C:\Windows\System32`、`C:\Windows\WinSxS` 与 `C:\ProgramData\Package Cache`。
2. **重解析点穿透保护 (Reparse Point Guard)**：清理缓存（如 `%TEMP%`）时严格阻断重解析点遍历，绝不递归删除软链接指向的真实文件。
3. **安全解绑 (Safe Unlink)**：解绑 NTFS Junction 时仅调用底层目录节点删除，严禁使用递归 `rmtree`。
4. **认知护栏 (Cognitive Guard)**：全面过滤庞大冗余的深层目录树，通过 Cursor Pagination 与领域卡片防止上下文溢出。
