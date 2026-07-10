# C Drive Savior · C盘拯救者

> 让 AI Agent 像一个懂 Windows 的老工程师一样，安全地拯救你的 C 盘。
> An agent skill that diagnoses, safely cleans, and migrates a full Windows C: drive — then proves the result with a before/after report.

对你的 Agent（Codex / Claude Code）说一句：

```text
C 盘快满了
```

它就会跑完一条完整的流水线：

```text
① 只读扫描 → 磁盘占用面板     看清 C 盘被什么吃掉（含普通扫描看不到的隐藏占用）
② 一轮确认                    所有需要拍板的项目一次列全，你只回答一次
③ 安全清理                    可重建缓存分级清理，管理员项走 UAC 提权
④ 迁移到 D 盘                 复制→校验→切换路径→留撤销方案，绝不裸移
⑤ 清理报告                    释放了多少 GB、每一项清了什么、哪些失败为什么
```

## 为什么不用普通清理软件？

普通清理软件告诉你"发现 12GB 垃圾文件"，但不会告诉你：删完之后软件修复会不会失败、微信聊天记录还在不在、Windows 更新还能不能回滚。

**C Drive Savior 的每一条规则都来自真实翻车现场**（完整清单见 [`references/pitfalls.md`](references/pitfalls.md)，24 条实证教训）：

- 有人清空了 `Package Cache`，两周后软件"修复"功能报错找不到安装包 → 所以它把安装缓存列为**黄灯确认项**，并优先建议备份到 D 盘而不是删除
- 有人在组件存储损坏时跑了 `DISM /ResetBase`，94.9% 处报错、SFC 一起罢工 → 所以它在任何 WinSxS 清理前**强制先做健康检查**
- 微信 4.0 把数据锁死在 C 盘 `Documents\xwechat_files`，还和旧版数据双份占用 → 所以它知道先用微信内置"清理历史版本冗余数据"，再靠"文档"文件夹重定向整体搬到 D 盘
- `Remove-Item "C:\$WINDOWS.~BT"` 会静默删错路径（`$WINDOWS` 被当变量展开）→ 所以所有命令强制 `-LiteralPath` + 单引号

## 核心能力

| 能力 | 说明 |
|---|---|
| **磁盘占用面板** | 同级目录从大到小、默认只看 >1GB；ASCII 面板 + 深色/浅色自适应 HTML 仪表盘 |
| **隐藏占用透视** | pagefile / hiberfil / 系统还原点(VSS) / 回收站 / Windows Update 缓存 / WinSxS 真实大小——解释"文件夹加起来对不上已用空间"之谜 |
| **四色风险分级** | 🟢可重建缓存 · 🟡需确认（修复缓存/回滚资产/聊天数据）· 🔴禁止手删 · 🔵适合迁移；只把"有决策"的项上灯，不做全盘点 |
| **分层安全清理** | `clean.ps1` 默认干跑（只测量不删除）；逐项实测释放量；进程占用自动跳过；管理员项生成一条 UAC 提权命令 |
| **D 盘迁移引擎** | `migrate.ps1`：空间预检×1.1 → robocopy → 文件数+字节双校验 → 可选 junction → 撤销命令写入日志；OneDrive/系统目录直接拒绝 |
| **逐应用迁移手册** | 微信 4.0 / QQ / 钉钉 / WPS / Steam / Docker / WSL / npm·pip·gradle·nuget 缓存 / 页面文件 / iTunes 备份 / CompactOS（[`references/relocation-guide.md`](references/relocation-guide.md)） |
| **清理报告** | `report.ps1`：磁盘级净释放 GB（主指标）+ 逐项实测 + 失败原因 + 撤销方式 + 保养建议，HTML 一眼看懂 |

## 快速开始

**Codex：**

```powershell
$skills = "$env:USERPROFILE\.codex\skills"
New-Item -ItemType Directory -Force $skills
git clone https://github.com/Choysang/C-Drive-Savior.git "$skills\c-drive-savior"
```

**Claude Code：**

```powershell
$skills = "$env:USERPROFILE\.claude\skills"
New-Item -ItemType Directory -Force $skills
git clone https://github.com/Choysang/C-Drive-Savior.git "$skills\c-drive-savior"
```

重启 Agent，然后说：`C盘满了`、`帮我清理电脑空间`、`哪些东西可以移到D盘`、`看看C盘被什么吃掉了`。

**不用 Agent 也能单独跑面板**（纯 PowerShell，无任何依赖，只读）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\scan.ps1 -ThresholdGB 1 -OpenReport
```

## 仓库结构

```text
c-drive-savior/
├── SKILL.md                        # Agent 编排：五阶段流水线 + 铁律
├── scripts/
│   ├── scan.ps1                    # 只读扫描 + 面板（控制台/JSON/HTML，含隐藏占用）
│   ├── clean.ps1                   # 绿灯清理器：默认干跑，-Execute 才动手，逐项记账
│   ├── migrate.ps1                 # D盘迁移：预检→复制→校验→junction→撤销日志
│   ├── report.ps1                  # 清理报告：基线对比 + 动作明细 + 建议
│   └── c_drive_panel.py            # Python 备选扫描器（大盘更快）
├── references/
│   ├── pitfalls.md                 # 24 条实证翻车教训（写任何命令前必读）
│   ├── decision-model.md           # 四色分级目录 + 隐藏占用 + 执行顺序
│   ├── relocation-guide.md         # 逐应用"搬去D盘"手册
│   └── research-sources.md         # 微软官方文档与社区来源沉淀
└── evals/evals.json                # 9 条行为评测（防翻车回归）
```

## 安全哲学

1. **先看清，再动手**：不出面板不删除，所有破坏性动作过用户确认。
2. **一次拍板**：需要你决定的事项一次列全编号清单，不挤牙膏式追问。
3. **官方工具优先**：能走卸载器 / Storage Sense / Disk Cleanup / DISM / 应用内迁移的，绝不手删目录。
4. **可撤销**：迁移默认保留源副本窗口期，撤销命令写进日志；用户数据只给可逆操作。
5. **诚实记账**：释放空间逐项实测 + 磁盘级复核，失败项原样报告，绝不编数字。

## 致谢

- 分级决策清单、分段磁盘条、"现状→诊断→处方→操作→预防"报告结构的灵感来自 [khazix-skills/storage-analyzer](https://github.com/KKKKhazix/khazix-skills/tree/main/storage-analyzer)，本项目将其重构为 Windows 专用五阶段流水线。
- 官方口径来自 Microsoft Learn / Support（WinSxS、Storage Sense、Dev Drive、已知文件夹重定向等），见 [`references/research-sources.md`](references/research-sources.md)。

## License

MIT

---

> 如果它帮你救回了几十 GB，点个 ⭐ 让更多 C 盘用户看到它。
