---
name: c-drive-savior
description: Next-Generation Agent-Native Windows Storage Engine (C-Drive-Savior 2026+). Full disk diagnosis, precision cache cleaning, transactional NTFS Junction relocation to D:, and Shell32 Known Folder redirection. Use whenever the user mentions C盘满了, C盘快满了, 清理C盘, 电脑空间不足, 帮我清理电脑空间, C盘瘦身, 把文件移到D盘, analyze C drive, clean system drive, disk full, or asks what can be deleted or moved to D:.
---

# C-Drive-Savior 2026+ | Agent-Native Fast Invocation Runbook

本项目是**双模一体**的智能体系统工程：底层是高性能 Python 3.12+ 原生 WinAPI 内核程序，顶层是标准化的 AI Agent 技能（Skill）。

当用户提出清理或分析 C 盘需求时，**Agent 应严格遵循以下三步极速标准工作流，切勿自行手写脆弱的 PowerShell / CMD 遍历与删除脚本**。

---

## ⚡ Agent 三步极速操作工作流 (Quick Action Runbook)

### 步骤 1：执行只读深度诊断 (Step 1: Read-Only Diagnosis)

在终端中执行统一命令获取全盘空间与资产状态：

```powershell
python -m c_drive_savior scan
```
*(如果需要机器可读的结构化 JSON，可添加 `--json` 参数)*

### 步骤 2：向用户呈现结构化决策卡片 (Step 2: Present 1-Round Decision Card)

读取命令输出后，整理为清晰易懂的分类卡片展示给用户确认：

1. **🟢 可安全清理的缓存 (GREEN / Safe to Clean)**：
   - 典型：`%LOCALAPPDATA%\uv`、`%LOCALAPPDATA%\pip\cache`、`%LOCALAPPDATA%\Temp`、DirectX Shader 缓存等。
   - 效果：安全清理，软件下次使用时自动按需重建，零副作用。
2. **🟣 建议无缝迁移至 D 盘 (MOVE / NTFS Junction Relocation)**：
   - 典型：AI 工作区与模型缓存（`.codex`、`.workbuddy-ai`、`.claude`、`.ollama`）、`AppData\Roaming\uv` 全局 Python 环境。
   - 效果：通过原生 `_winapi.CreateJunction` 整体移入 D 盘并在原地保留软链接，软件无感运行，彻底释放 C 盘空间。
3. **📁 系统已知文件夹重定向 (Known Folder Redirection)**：
   - 典型：`Documents`（文档）、`Downloads`（下载）。
   - 效果：调用 Shell32 原生重定向至 `D:\Documents`、`D:\Downloads`。
4. **🔴 绝对受保护系统禁区 (RED / Strictly Protected)**：
   - 明确告知用户：`WinSxS`、`System32`、`Package Cache` 受底层防护拦截，绝对不予手删，以保护系统更新与软件修复链。

### 步骤 3：根据用户确认极速执行原子操作 (Step 3: Atomic Execution)

获得用户授权后，直接调用内置原子命令执行：

```powershell
# 1. 清理指定安全缓存
python -m c_drive_savior clean "<target_cache_path>"

# 2. 事务性搬迁大目录至 D 盘并建立 Junction 软链接 (3步原子置换，遇错自动回滚)
python -m c_drive_savior relocate "<source_path>" --dest "D:\MovedFromC\<folder_name>"

# 3. 重定向用户已知文件夹
python -m c_drive_savior redirect Documents "D:\Documents"
python -m c_drive_savior redirect Downloads "D:\Downloads"
```

---

## 🎨 可视化控制台模式 (Web Console Mode)

如果用户希望在浏览器中查看动态仪表盘并进行可视化点选，告知用户执行：

```powershell
python -m c_drive_savior serve --port 8999
```
并在浏览器中打开 **http://127.0.0.1:8999** 即可进入暗黑赛博朋克毛玻璃管理面板。

---

## 🤖 FastMCP 2026 原生工具集成 (MCP Tool Calling)

如果当前 Agent 支持 Model Context Protocol (MCP)，可以直接挂载并调用原生工具：

```json
{
  "mcpServers": {
    "c-drive-savior": {
      "command": "python",
      "args": ["-m", "c_drive_savior", "mcp"],
      "cwd": "C:\\path\\to\\C-Drive-Savior\\src"
    }
  }
}
```

- `get_c_drive_overview`: 获取经 Cognitive Guard 极限压缩的盘符高信噪比摘要（< 400 Tokens）。
- `list_cleanup_candidates`: 游标分页获取 GREEN 安全缓存项。
- `list_migration_candidates`: 游标分页获取 MOVE 软链接迁移项。
- `plan_relocation`: Dry-run 预检迁移安全性。
- `execute_relocation`: 原子执行搬迁并建立 Junction。
- `clean_cache`: 执行目录安全清理。
- `redirect_known_folder`: 重定向文档/下载目录。

---

## 🚫 严禁行为准则 (Strictly Prohibited)

- **严禁**：手写 `rmdir /s /q`、`Remove-Item -Recurse` 或批处理暴力删除任意目录。
- **严禁**：递归删除软链接（Junction/Symlink）内部数据。
- **严禁**：触碰或删除 `C:\ProgramData\Package Cache`（会导致 MSI 修复链损坏报 0x80070005）。
- **必须**：始终使用 `python -m c_drive_savior` 内置原子命令，利用内核的重解析点防护与自动回滚保障系统安全。
