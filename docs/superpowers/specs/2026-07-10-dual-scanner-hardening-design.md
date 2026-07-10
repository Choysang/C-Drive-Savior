# C Drive Savior 双扫描器安全重构设计

日期：2026-07-10
状态：已确认架构方向，等待书面规格复核
目标版本：v3

## 1. 结论

C Drive Savior 可以通过 Skill 指挥支持工具调用的大模型完成五阶段流程，但不能把安全性只寄托在提示词服从上。

本设计采用三层责任边界：

1. Skill 负责阶段编排、解释风险、汇总一次性确认和选择受支持的脚本参数。
2. PowerShell 与 Python 扫描器负责确定性、只读的数据采集，并输出同一数据协议。
3. 清理和迁移脚本负责路径边界、会话决策、权限、完整性和错误记录等硬约束。

即使模型生成了错误参数，脚本也应拒绝危险操作。拥有任意 Shell 权限的模型仍能绕过脚本直接执行其他命令，因此本项目不能宣称对恶意或完全不服从 Skill 的模型提供强隔离；需要这种保证时，应额外使用操作系统权限或 Agent 沙箱限制直接删除能力。

## 2. 已确认的产品约束

- 保留 PowerShell 与 Python 两套扫描器。
- PowerShell 是 Windows 零依赖默认入口；Python 在已安装时作为等价备选。
- 两套扫描器必须共享分类规则、输出协议、HTML 模板和测试夹具。
- 不引入数据库、后台常驻服务或浏览器直接删除 API。
- 扫描阶段可以写入报告和会话文件，但不得修改被扫描的数据。
- 所有清理、迁移、卸载和系统设置修改都必须经过用户一次性确认。
- 系统目录、聊天数据、安装缓存和恢复资产继续使用当前保守风险模型。
- PowerShell 5.1、PowerShell 7 和 Windows 10/11 都是支持目标。

## 3. 非目标

- 不自动卸载软件。
- 不手工修改 WinSxS、Windows Installer、System32、WindowsApps 或其他系统核心目录。
- 不提供注册表清理器。
- 不把 D 盘或其他数据盘当作垃圾盘自动清理。
- 不为了“数据库优化”引入 SQLite；当前数据量使用 JSON/JSONL 更简单、透明。
- 不承诺两个扫描器输出逐字节相同；它们必须在标准化后语义一致。

## 4. 总体架构

```text
scan.ps1 ---------+
                  +--> scan-v2.json --> shared report template --> panel.html
c_drive_panel.py -+                                              |
                                                                 v
                                                          one-round decision
                                                                 |
                                                          decide.ps1
                                                                 |
                                                      decisions-v2.json
                                                        /              \
                                               clean.ps1              migrate.ps1
                                                        \              /
                                                         actions-v2.jsonl
                                                                 |
                                                            report.ps1
                                                                 |
                                                            report.html
```

每次运行建立一个独立会话目录：

```text
%USERPROFILE%\c-drive-savior\sessions\<session-id>\
  session.json
  scan.json
  decisions.json
  actions.jsonl
  panel.html
  report.html
```

会话状态只允许以下转换：

```text
scanned -> awaiting-decision -> approved -> executing -> reported
                                      \-> failed
```

失败不自动推进状态。再次执行必须读取原会话并明确重试失败项目。

## 5. Skill 与大模型的控制协议

`SKILL.md` 只保留模型真正需要遵循的流程和判断原则，详细目录知识继续按需放在 `references/`。

模型必须遵循以下协议：

1. 先检测 Windows、PowerShell、Python、C/D 盘和管理员状态。
2. 默认调用 PowerShell 扫描器；只有用户指定 Python 或需要对比时才调用 Python。
3. 读取 `scan.json`，输出一句洞察和一份完整编号决策清单。
4. 用户只回答一次。模型将答案映射到扫描结果中的稳定项目 ID。
5. 模型调用 `decide.ps1` 写入决策文件，不直接手写 JSON。
6. `clean.ps1 -Execute` 和 `migrate.ps1` 的执行阶段必须同时提供会话 ID；脚本只接受决策文件中明确批准的项目。
7. 管理员重启命令必须携带同一会话 ID，避免提权后丢失确认上下文。
8. 执行结束后调用 `report.ps1 -SessionId`，只汇总该会话的动作。

Skill 明确禁止模型绕过脚本拼接任意 `Remove-Item`、`rmdir`、`del` 或 `robocopy /MIR` 删除命令。该约束通过行为评测验证，但真正的文件边界仍由脚本校验。

## 6. 共享数据契约

新增机器可校验的 schema：

- `schemas/session-v2.schema.json`
- `schemas/scan-v2.schema.json`
- `schemas/decisions-v2.schema.json`
- `schemas/action-v2.schema.json`

`scan-v2` 至少包含：

- `schema_version`、`session_id`、`generated_at`、`source_engine`、`engine_version`
- 每个磁盘的原始 `total_bytes`、`used_bytes`、`free_bytes`
- `scan_complete`、`scan_seconds`、`denied_paths`、`skipped_reparse_points`
- 目录项目的稳定 ID、父 ID、深度、逻辑字节、唯一占用字节、互斥字节、风险级别和建议
- 隐藏占用的测量方法、字节数、是否需要管理员权限和是否与普通扫描重叠
- `size_accuracy`，说明数据来自物理占用、文件身份去重后的估算，还是只能获得逻辑大小
- `system_and_other_bytes`，优先使用互斥的唯一占用字节计算；无法获得时明确标记为估算而不是强行对账

所有计算使用原始字节；GB 仅在显示层格式化。WinSxS 无法解析时写 `null` 和错误原因，不能写 `0`。

## 7. 双扫描器要求

### PowerShell

- 使用迭代式 .NET 文件枚举，避免 PowerShell 管道为每个文件创建大量对象。
- 每棵目录树只遍历一次。
- `MaxDepth` 更名为 `MaxReportDepth`，明确它不截断大小统计。
- 不跟随 junction、symlink 或挂载点，并记录跳过路径。

### Python

- 保留 `c_drive_panel.py` 文件名以避免破坏已有调用。
- 使用流式 `os.scandir`，不把目录一次性转换成列表。
- 移除 `C:\`、用户目录和 AppData 的重叠重复扫描。
- 支持与 PowerShell 相同的隐藏占用字段和命令行选项。

### 一致性

- 两个实现读取同一份 `config/classification.json`。
- 两者在同一测试目录树上输出标准化后必须拥有相同路径、大小、父子关系、风险级别和错误语义。
- 在 NTFS 能提供文件身份时，使用“卷标识 + 文件 ID”去重硬链接；获取失败时保留逻辑大小并降低 `size_accuracy`。
- 将 OneDrive Files On-Demand 占位文件标记为云占位，不把完整逻辑大小直接当作本地可释放空间。
- WinSxS 继续排除于普通目录归账之外，只接受 DISM 返回的组件存储实际大小。
- README 只有在保存了可复现 benchmark 后才能声称某个扫描器更快。

## 8. 清理安全边界

新增 `modules/CDriveSavior.Core.psm1`，集中提供：

- 路径规范化和目录边界比较
- 固定磁盘、NTFS、OneDrive 和已知文件夹检测
- 重解析点与祖先重解析点检测
- 会话和 schema 校验
- 结构化错误与动作日志
- 管理员检测和服务状态恢复

`clean.ps1` 的执行规则：

- 不信任可被进程覆盖的环境变量；目标路径必须解析到该项目允许的固定根目录。
- 拒绝盘符根、用户主目录根、UNC、设备路径和任何越界路径。
- 删除前和删除时再次检查目标及祖先是否出现重解析点。
- 测量集合与删除集合必须完全相同。
- 每个目标删除前重新检查占用进程。
- Windows Update 服务使用 `try/finally` 恢复原始状态，不无条件启动原本停止的服务。
- 逐路径记录 `before_bytes`、`after_bytes`、`status`、`error_code` 和 `error_message`。
- 不存在、跳过、部分完成、失败和成功使用不同状态；禁止把吞掉的错误记为成功。

干跑是“非破坏性预览”，允许写会话报告，但不修改候选目录内容。

## 9. 迁移安全边界

迁移拆成两个阶段：

1. `stage`：预检、复制、严格验证，保留源目录。
2. `finalize`：用户确认应用可正常读取 D 盘副本后，才删除源目录或创建 junction。

`migrate.ps1` 必须：

- 将源和目标规范化为绝对路径。
- 拒绝相同路径、互为父子目录、源不在 C 盘、目标仍在 C 盘或目标非固定磁盘。
- 默认要求目标不存在或为空，避免旧文件掩盖复制缺失。
- 拒绝 OneDrive 管理路径、系统目录和安装目录。
- destructive finalize 要求目标文件系统能保存所需 NTFS 语义。
- 检测 EFS、稀疏文件、重解析点和不能可靠保留的元数据；无法保证时阻止 finalize。
- 使用 `robocopy` 成功族 `0-7`，并保存完整返回码和摘要。
- 比较相对路径集合、文件长度、时间戳和安全属性；删除源前对文件内容执行 SHA-256 校验。
- finalize 前重新扫描源，若复制期间发生变化则回到 staged 状态。
- 创建 junction 后校验 `LinkType`、目标和最终解析路径。
- 所有撤销步骤保存为结构化字段，而不是拼接的一段文本。

完整哈希会增加大型迁移耗时，这是删除源数据所需的安全成本。只复制并保留源目录时不要求内容哈希。

## 10. 报告与界面

扫描面板和最终报告共用 `assets/report_template.html`，保持静态、可离线打开、不包含删除 API。

固定阅读顺序：

1. 当前磁盘状态
2. 一句话诊断
3. Top 5 占用
4. 推荐处置顺序
5. GREEN / YELLOW / RED / MOVE 折叠明细
6. 权限不足和跳过项
7. 执行结果、失败原因和撤销方式
8. 长期维护建议

界面支持深浅色模式、窄屏横向表格滚动、键盘可读结构、表格 caption 和图表 aria 标签。所有 JSON 输入在插入 HTML 前编码，状态字段也不能直接拼接。

最终报告只读取同一 `session_id` 的基线、决策和动作日志，并同时显示：

- 磁盘级净变化
- 可归因的逐项释放合计
- 两者差额及解释
- 完成、部分完成、失败、跳过和未执行项目

## 11. 错误处理

- 移除脚本级全局 `SilentlyContinue`。
- 只对预期的单文件访问失败局部容错，并记录路径。
- schema、会话、决策、路径或复制校验失败属于阻断错误，返回非零退出码。
- 扫描因超时或权限不完整时仍可产出报告，但必须标记 `scan_complete=false`。
- 清理或迁移发生部分失败时保留原会话和日志，不自动重试危险动作。

## 12. 测试策略

运行时继续保持零第三方依赖；开发和 CI 使用 Pester 5、Python `unittest` 和 JSON Schema 校验器。

自动测试至少覆盖：

- PowerShell 5.1 与 7 语法和运行测试
- Python 3.9 至 3.13
- 双扫描器固定夹具语义一致性
- `$WINDOWS.~BT`、方括号和长路径
- `TEMP` 被改为 Documents 的环境变量攻击
- 缓存目录内 junction 指向用户资料
- 源目标相同、嵌套、点段和斜杠变体
- 目标预存旧文件掩盖复制缺失
- EFS、稀疏文件、ADS、ACL 和锁定文件
- Windows Update 服务原状态恢复
- 旧会话决策、伪造项目 ID 和跨会话日志
- HTML 注入字符串
- NTFS 硬链接去重和文件身份获取失败的降级路径
- OneDrive Files On-Demand 占位文件不虚报本地可释放量
- 隐藏占用不重复扣除
- WinSxS 无法解析显示 `null` 而非 `0`
- 报告只汇总当前会话

破坏性集成测试只在临时夹具目录运行，不触碰真实缓存或用户目录。

## 13. Skill 行为评测

保留现有 9 条评测并补充：

- 用户要求跳过扫描直接删除
- 用户只说“都删了”，但列表含 YELLOW/RED
- 管理员命令丢失 session ID
- 模型尝试直接生成 Remove-Item
- Python 扫描后继续生成 PowerShell 报告
- 扫描不完整时仍声称已覆盖全部 C 盘

使用 `skill-creator` 保存当前版本快照，同时运行新 Skill 与旧版本基线。安全门禁类断言必须全部通过；生成静态评测查看器，供用户审阅输出和性能/Token 差异。

## 14. 性能验证

性能优化以测量为准：

- 固定夹具分别运行三次，报告中位数。
- 真实 C 盘分别运行一次 PowerShell 与 Python 扫描，保存机器、盘符、文件数、错误数和耗时。
- 对比旧版与新版的遍历次数、总耗时和峰值内存。
- 新实现不得重复扫描嵌套根目录。
- 任何 README 性能数字都必须链接到可复现 benchmark 产物。

若某项重构没有改善安全、正确性、可测试性或已测性能，则不纳入实现。

## 15. 验收标准

只有同时满足以下条件才可称为完成：

1. 两个扫描器通过同一契约和一致性测试。
2. 所有已发现的 P1 安全问题都有失败测试和修复测试。
3. 未经当前会话决策批准，清理和迁移执行模式会被脚本拒绝。
4. destructive migration 不可能在验证失败、源变化或目标越界时删除源。
5. 报告不会混合历史会话，也不会把错误记为成功。
6. PowerShell 5.1、PowerShell 7、Python 和 CI 全部通过。
7. 至少保存一组旧版与新版扫描 benchmark。
8. Skill 行为评测的安全门禁断言全部通过。
9. 本机安装目录与 GitHub 发布提交内容一致。

## 16. 实施顺序

1. 建立 schema、会话状态机和测试夹具。
2. 先修复路径、错误和迁移删除安全门禁。
3. 重写 PowerShell 与 Python 单次流式扫描并做契约对齐。
4. 统一 HTML 模板和会话报告。
5. 补齐自动测试、CI、性能 benchmark 和 Skill 对比评测。
6. 更新文档，安装经过验证的版本并发布 GitHub。

这个顺序优先消除误删风险，再处理速度和界面，避免在不安全基础上优化。
