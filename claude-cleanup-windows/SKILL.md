---
name: claude-cleanup-windows
description: 在 Windows 上安全审计、完整备份、清理或重置 Claude Code 与 Claude Desktop 本机状态。适用于清理可再生缓存和日志、轮换本地 ID、重置桌面端登录态、移除应用、继承现有遥测状态、启用最小提示词模式或修改台北时区；不用于规避封禁或平台风控。
---

# Claude 本机清理（Windows）

使用随附 PowerShell 脚本执行，不要临时拼接 `Remove-Item`。脚本采用窄白名单、完整备份、一次最终知情确认和失败即停止。

## 运行顺序

如果当前执行者就是 Claude Code，只运行只读审计并提醒用户切换到 Codex 或普通 PowerShell。不要让正在使用 `%USERPROFILE%\.claude` 的 Claude Code 自己修改该目录。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\claude_cleanup.ps1 -Audit
```

如果由 Codex 或普通 PowerShell 执行，先运行审计并向用户说明：

- 第一个写操作是完整复制并校验 `%USERPROFILE%\.claude`，同时备份 `%USERPROFILE%\.claude.json`；
- 可再生缓存和日志会自动纳入最终清单，不逐项询问；
- 身份、Windows Credential Manager、桌面端登录态、应用、精简模式和时区属于风险操作，仍由用户选择；
- 文件移除只进入带时间戳的隔离目录，不会永久删除；Windows 包管理器卸载应用属于例外，恢复需要重新安装；
- 保护路径和遥测设置保持不变。

用户明确要求继续后，在真实交互式 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\claude_cleanup.ps1
```

不要用管道代答，不要增加跳过确认参数。若只有自动安全清理且 Claude 正在运行，脚本直接跳过安全目标，不要求退出；若用户选择风险操作，再交由用户正常退出并复检。脚本不能自动结束进程。

脚本显示展开后的完整清单。用户输入一次 `CONFIRM` 后才开始写盘。修改时区可能要求在管理员 PowerShell 中重跑；不要让用户把 Windows 密码发给执行者，也不要读取或保存密码。

结束后报告备份路径、隔离批次、实际选择、应用卸载结果、遥测继承结果和时区。任何中途停止都报告为部分完成，不能笼统声称清理成功。

## 自动安全清理

在 Claude Code 和 Claude Desktop 都已退出后，自动把下列现存目标纳入最终清单，无需逐项提问：

```text
%USERPROFILE%\.claude\cache
%USERPROFILE%\.claude\stats-cache.json
%USERPROFILE%\.claude\telemetry
%USERPROFILE%\.claude\usage-data
%USERPROFILE%\.claude\usage.jsonl
%USERPROFILE%\.claude\usage.with-fix.jsonl
%LOCALAPPDATA%\Claude\Cache
%LOCALAPPDATA%\Claude\Code Cache
%LOCALAPPDATA%\Claude\GPUCache
%LOCALAPPDATA%\Claude\Logs
%LOCALAPPDATA%\Anthropic\Claude\Cache
%APPDATA%\Claude\logs
%LOCALAPPDATA%\CrashDumps\Claude*.dmp
```

这些目标必须仍通过脚本白名单检查，并且只移入隔离目录。

## 绝对保护范围

绝不删除或移动：

```text
%USERPROFILE%\.claude\projects、sessions、history.jsonl、file-history、debug
%USERPROFILE%\.claude\skills、plugins、hooks、commands、scripts、agents、mcp-servers
%USERPROFILE%\.claude\backups、CLAUDE.md、settings.json、settings.local.json
任何项目目录、Git 仓库、Codex 会话、C:\Program Files\ClaudeCode 管理配置，以及未明确列入白名单的路径
```

`settings.json` 只允许结构化修改被用户明确选择的键。保留其他 env、hooks、plugins、权限、模型、MCP、状态栏和秘密。目标与保护路径重叠时立即停止。

## 风险操作

- **本地身份轮换**：轮换 `%USERPROFILE%\.claude.json` 的 `userID`、`machineID`，清除已知账号缓存字段，并把同一组新值同步到 `%USERPROFILE%\.claude\backups\.claude.json.backup.*`。仅用于隐私和排障，不宣称能改变平台关联判断。
- **Windows Credential Manager**：删除 `Claude Code-credentials` 会退出 CLI 登录，单独选择。
- **Claude Desktop**：可选择仅清持久数据与登录态，或再卸载 Windows 应用。MSIX/Appx 或 WinGet 卸载由系统包管理器执行；脚本不运行未知注册表中的卸载命令。
- **最小提示词模式**：在 `settings.json` 的 `env` 中设置或移除 `CLAUDE_CODE_SIMPLE=1`。启用后使用最小系统提示词和有限工具，并跳过 hooks、skills、plugins、MCP、自动记忆及 `CLAUDE.md` 自动发现；这些资产不会被删除。一次性脚本调用优先考虑 `claude --bare`。
- **台北时区**：仅在 Windows 当前不是 `Taipei Standard Time` 时询问。使用 `Set-TimeZone` 修改并验证；没有管理员权限时停止并让用户在管理员 PowerShell 中重跑。

## 遥测继承

逐值保存以下键：

```text
DISABLE_TELEMETRY
DISABLE_ERROR_REPORTING
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
```

当前关闭就保持关闭；当前未关闭就不主动关闭。改变遥测状态不属于本 skill 的清理范围。

本 skill 不用于规避封禁、支付检查、设备或 IP 信誉、浏览器指纹或任何平台风控。
