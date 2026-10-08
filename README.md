# C-Drive-Savior 2026+ | C盘拯救者

> **Next-Generation Agent-Native Windows Storage Subsystem & Real-Time Console**
>
> 专为 2026+ 超级智能体（Claude Opus/Fable, GPT-6, Gemini 3.8 等）与现代开发者设计的全自主 Windows C 盘优化引擎。彻底告别传统清理工具的黑盒与历史包袱，采用零构建前后端完全分离架构与原生 Windows 底层内核。

[![Python 3.12+](https://img.shields.io/badge/python-3.12+-blue.svg)](https://www.python.org/downloads/)
[![FastMCP 2026](https://img.shields.io/badge/FastMCP-Stdio%20JSON--RPC-purple.svg)](https://modelcontextprotocol.io/)
[![FastAPI](https://img.shields.io/badge/FastAPI-v2.0-009688.svg)](https://fastapi.tiangolo.com)
[![Vue 3 ESM](https://img.shields.io/badge/Frontend-Zero--Build%20Vue3-4FC08D.svg)](https://vuejs.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 🌟 核心设计理念 (Architecture Philosophy)

在过去的系统维护中，传统清理工具存在三大根本痛点：
1. **时代的断层**：传统软件只识别回收站与系统日志，对动辄数十 GB 的现代 **AI 本地模型、Agent 工作区（Codex, Claude Desktop, WorkBuddy）、现代包管理器环境（uv, pnpm, cargo）** 毫无所知。
2. **缺乏原子性与不可逆破坏**：暴力强删导致快捷方式失效、软件无法修复（如损坏 `Package Cache`）；缺乏无缝迁移与原子回滚机制。
3. **Agent 协作鸿沟**：缺乏面向自主智能体（Autonomous Agents）的标准交互协议，输出未经提炼的海量文本造成 Token 洪泛。

**C-Drive-Savior 2026+** 针对上述问题进行了**彻底的无历史包袱重构**：

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                        Super-Intelligent Agents                        │
 │           (Claude Fable 5.1 / GPT-6 / Opus 5.5n / Gemini 3.8)           │
 └──────────────────────┬─────────────────────────┬───────────────────────┘
                        │ FastMCP JSON-RPC        │ REST API
                        ▼                         ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      C-Drive-Savior Presentation                       │
 │  ┌───────────────────────────────┐   ┌───────────────────────────────┐ │
 │  │ FastMCP 2026 Stdio Server     │   │ FastAPI 2.0 Web Console       │ │
 │  │ (Cognitive Guard Token Safe)  │   │ (Zero-Build Vue3 ESM Tailwind)│ │
 │  └───────────────┬───────────────┘   └───────────────┬───────────────┘ │
 └──────────────────┼───────────────────────────────────┼─────────────────┘
                    └─────────────────┬─────────────────┘
                                      ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │                           Core Engine Core                             │
 │  ┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────┐ │
 │  │ Concurrent Profiler   │ │ Precision Cleaner     │ │ Relocator     │ │
 │  │ (os.scandir + Memory) │ │ (Reparse Safe)        │ │ (Atomic 3-Step│ │
 │  └───────────────────────┘ └───────────────────────┘ └───────────────┘ │
 └────────────────────────────────────┬───────────────────────────────────┘
                                      ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      Native Windows Kernel Drivers                     │
 │  • _winapi.CreateJunction (NTFS Reparse Points, No Admin Required)     │
 │  • Shell32 SHSetKnownFolderPath (User Shell Folders Redirection)       │
 │  • Win32 Process Snapshot Locking (Conflict Detection)                 │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ 核心能力与黑科技 (Key Features)

### 1. 🤖 FastMCP 2026 协议原生集成 (Agent-Native)
内置完整的 Model Context Protocol (MCP) JSON-RPC 2.0 引擎。任何 AI Agent 可通过 Stdio 零延迟调用：
- `get_c_drive_overview`: 获取经 **Cognitive Guard** 压缩的极高信噪比盘符与 Top 消费者摘要（< 400 Tokens）。
- `list_cleanup_candidates`: 分页获取可安全清除的 GREEN 缓存目录。
- `list_migration_candidates`: 分页获取适于无缝转移至 D 盘的重点资产。
- `execute_relocation`: 原子迁移源目录至目标驱动器，并在原地建立 NTFS Junction。
- `redirect_known_folder`: 动态调用 Shell32 重定向用户“文档”或“下载”目录。

### 2. 🔗 原生 NTFS Junction 事务性迁移 (Transactional Relocation)
- 告别可能破坏注册表路径的传统“拷贝后删除”。
- 直接调用 Python 底层 C 扩展 `_winapi.CreateJunction`，在普通用户权限下即可建立底层文件系统硬分流。
- **三步原子保护**：`源目录备份改名 -> 数据移动至目标盘 -> 建立原生 Junction -> 验证通过后释放源备份`。任何环节异常即刻秒级回滚。

### 3. 🛡️ 智能认知护栏 (Cognitive Guard)
- 防止大型目录树扫描结果向大模型上下文窗口倾倒数十万 Tokens。
- 基于游标的轻量级分页（Cursor-based Pagination）与多维结构化诊断卡片。

### 4. 🎨 零构建现代极客控制台 (Zero-Build ESM Console)
- **前后端完全分离**：无 `node_modules` 负担，无需 Vite/Webpack 构建。
- 基于原生 ESM Import Maps + Vue 3 + Tailwind CSS CDN 打造的暗色赛博朋克毛玻璃（Glassmorphism）控制台。
- 启动即用：实时盘符水位进度条、一键安全清理、一键目录迁移、Known Folders 状态一览。

### 5. 🧠 2026 现代工作区与 AI 资产图谱 (Knowledge Catalog)
精准分类治理现代计算机的关键大资产：
- **AI 运行时与工作区**：`.codex` (会话与工程), `.workbuddy-ai`, `.claude` (桌面端), `.ollama` (本地权重), `OpenAI`, `HuggingFace Hub`
- **现代工具链缓存**：`uv` (全局与缓存), `pip`, `npm`, `pnpm`, `playwright`
- **中国特色生态治理**：微信/QQNT/证券行情数据安全识别
- **绝对受保护禁区**：`WinSxS`, `System32`, `Package Cache` 严格保护，绝不误触

---

## 🚀 快速上手 (Quick Start)

### 1. 环境准备
仅需 Python 3.12+ 环境：
```bash
git clone https://github.com/Choysang/C-Drive-Savior.git
cd C-Drive-Savior
pip install -r requirements.txt
```

### 2. 启动可视化控制台 (Web Console)
```bash
python -m c_drive_savior serve --port 8999
```
浏览器访问 `http://127.0.0.1:8999`，即可进入极具极客感的可视化运维面板。

### 3. 命令行极速运维 (CLI)
```bash
# 全盘极速诊断 (输出格式化诊断报告)
python -m c_drive_savior scan

# 输出机器可读 JSON
python -m c_drive_savior scan --json

# 一键安全清理指定缓存
python -m c_drive_savior clean "%LOCALAPPDATA%\uv"

# 原子迁移大目录至 D 盘并建立 Junction
python -m c_drive_savior relocate "C:\Users\username\.codex" --dest "D:\MovedFromC\.codex"

# 重定向用户 Known Folders (如文档/下载) 到 D 盘
python -m c_drive_savior redirect Documents "D:\Documents"
```

### 4. 作为 Agent MCP 工具挂载 (Claude Desktop / Codex / Cursor)
在你的 Agent 客户端配置文件（如 `claude_desktop_config.json`）中添加：
```json
{
  "mcpServers": {
    "c-drive-savior": {
      "command": "python",
      "args": ["-m", "c_drive_savior", "mcp"],
      "cwd": "C:\\path\\to\\C-Drive-Savior"
    }
  }
}
```

---

## 📂 项目结构 (Project Directory Tree)

```text
C-Drive-Savior/
├── src/
│   └── c_drive_savior/
│       ├── __init__.py
│       ├── __main__.py               # python -m c_drive_savior 入口
│       ├── core/
│       │   ├── engine/               # 核心执行引擎
│       │   │   ├── scanner.py        # 并发目录测量与盘符剖析器
│       │   │   ├── relocator.py      # 事务性 Junction 迁移与回滚
│       │   │   └── cleaner.py        # 具备重解析点保护的安全清理器
│       │   ├── native/               # Windows 底层 API 绑定
│       │   │   ├── junction.py       # 原生 _winapi Junction 生命周期
│       │   │   ├── known_folders.py  # Shell32 已知文件夹重定向
│       │   │   └── process_lock.py   # 运行期文件/进程冲突感知
│       │   └── rules/
│       │       └── catalog.py        # 2026 AI/Dev/系统资产图谱
│       ├── domain/                   # 领域模型与协议
│       │   ├── models.py             # Pydantic v2 强类型领域模型
│       │   └── cognitive_guard.py    # Agent 上下文认知护栏与分页
│       ├── server/                   # 通信与服务层
│       │   ├── cli.py                # 统一命令行接口
│       │   ├── api_server.py         # FastAPI 异步 REST 服务
│       │   └── mcp_server.py         # FastMCP JSON-RPC Stdio 服务
│       └── console/                  # 零构建现代 Web 前端
│           ├── index.html            # Tailwind + Glassmorphism UI
│           └── app.js                # 原生 ESM Vue 3 响应式客户端
├── tests/                            # 自动化全量测试套件
│   ├── test_modern_engine.py         # 核心引擎与认知护栏单测
│   └── test_api_and_mcp.py           # REST API 与 MCP 服务契约测试
├── pyproject.toml                    # PEP 621 标准项目构建配置
├── requirements.txt                  # 运行时依赖
└── SKILL.md                          # 面向 AI Agent 的标准化技能声明
```

---

## 🛡️ 安全承诺与设计边界 (Safety Guarantees)

1. **绝对不碰系统红线区**：严禁暴力清理 `Windows\System32`、`WinSxS` 和 `Package Cache`，保护 Windows Update 和 MSI 修复链的完整性。
2. **重解析点穿透保护**：在遍历和清理 Temp 缓存时，遇到任何重解析点（Junction/Symlink）一律跳过，绝不递归删除所指向的目标数据。
3. **软链接解绑安全**：解绑 Junction 链接时使用原生底层解绑操作，严防任何意外递归清空实际数据盘目录。

---

## 📄 License
MIT License. Open for human engineers and autonomous AI agents alike.
