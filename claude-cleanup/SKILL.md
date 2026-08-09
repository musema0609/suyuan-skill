---
name: claude-cleanup
description: 安全审计、备份、清理或重置本机 Claude Code 与 Claude Desktop 状态。适用于轮换本地设备 ID、清理桌面端缓存或应用、继承现有遥测状态、启用精简提示词模式，以及检查或修改 macOS 时区。不用于规避封禁或平台风控。
---

# Claude 本机清理

这个 skill 用于执行**有完整知情确认门的本机清理**。真正的执行逻辑以随附脚本为准，不要临时拼接 `rm` 命令替代。

## 执行流程

1. 先定位本 `SKILL.md` 所在目录，再运行只读审计：

   ```bash
   python3 scripts/claude_cleanup.py --audit
   ```

2. 汇报审计结果时，不输出完整设备 ID、token、账号邮箱或钥匙串秘密。把已确认事实和待用户选择分开，至少说明：
   - 当前遥测状态；
   - Claude Desktop 程序和本地数据是否存在；
   - 可选 CLI 缓存目标是否存在；
   - `CLAUDE_CODE_SIMPLE` 是否启用；
   - macOS 当前时区；
   - 正在运行的 Claude Desktop 和 Claude Code 进程数量。

3. 正式执行前，向用户说明交互脚本会：
   - 逐项询问每个可选操作；
   - 展开并显示所有可能移入废纸篓的现存路径；
   - 显示绝对不会删除的保护路径；
   - 要求用户输入最终确认词 `CONFIRM`；
   - 在第一个实际修改动作中完整备份并校验 `~/.claude`。

4. 只有用户明确要求继续后，才在真实终端中启动交互脚本：

   ```bash
   python3 scripts/claude_cleanup.py
   ```

   不要通过管道代填答案，不要增加绕过确认的参数。密码输入和每一步确认都必须交给用户本人。

5. 执行结束后，汇报：
   - 已验证的完整备份路径；
   - 废纸篓批次路径；
   - 实际修改的设置；
   - 执行前后保持不变的遥测状态；
   - 时区结果；
   - 因人工操作或错误而停止的步骤。

只有完整备份验证通过，且每个已选操作都有明确结果时，才能报告完成。中途停止必须报告为部分完成。

## 硬边界

清理采用窄白名单。脚本绝对不能删除或移动：

```text
~/.claude/projects
~/.claude/history.jsonl
~/.claude/file-history
~/.claude/debug
~/.claude/sessions
~/.claude/skills
~/.claude/plugins
~/.claude/hooks
~/.claude/commands
~/.claude/scripts
~/.claude/agents
~/.claude/mcp-servers
~/.claude/backups
~/.claude/CLAUDE.md
~/.claude/settings.json
~/.claude/settings.local.json
任何项目目录、Git 仓库或 Codex 会话
```

`settings.json` 只能接受用户明确选择的结构化修改。现有 env、hooks、plugins、权限、模型、MCP 配置、状态栏和秘密必须保留。

所有文件移除都进入 `~/.Trash` 下的时间戳目录，绝不清空废纸篓。如果清理目标与任一保护路径重叠，立即停止，不能猜测。

这个 skill 不用于规避封禁、支付检查、IP 或设备信誉、浏览器指纹控制或平台风控。本地 ID 轮换只用于隐私和排障，不得宣称它能让设备或账号不可关联。

## 操作分支

### 本地身份重置

完成全量备份并得到明确确认后，脚本可以轮换 `~/.claude.json` 中的 `userID` 和 `machineID`，然后把同一组新值同步到匹配的 `~/.claude/backups/.claude.json.backup.*`，避免 Claude 从内部备份恢复旧 ID。

只删除代码中明确列出的账号和缓存字段，保留其他键，不删除主文件或 `backups` 目录。删除钥匙串中的 `Claude Code-credentials` 是独立确认项，因为这会让 CLI 退出登录。

### Claude Desktop 清理

向用户提供三个明确选项：

1. 不清理桌面端；
2. 只清理桌面端数据、缓存、日志和偏好设置，保留 `/Applications/Claude.app`；
3. 清理桌面端数据，并把 `/Applications/Claude.app` 一并移入废纸篓。

最终确认前必须显示展开后的现存路径。受影响的 Claude 进程由用户本人正常退出，脚本不能自动 kill 会话。

### CLI 缓存清理

只允许移动脚本内置白名单中的目标：`~/.claude/cache`、`stats-cache.json`、`telemetry`、usage 文件以及 `~/Library/Caches/claude-cli-nodejs`。历史记录和所有自定义目录保持不动。

### 继承遥测状态

检测并逐值保留以下设置：

```text
DISABLE_TELEMETRY
DISABLE_ERROR_REPORTING
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
```

如果当前已经关闭遥测或非必要流量，就保持关闭；如果没有关闭开关，就不主动添加。改变遥测状态必须作为本次清理之外的独立用户请求处理。

### 精简系统提示词

可以向用户提供 `env.CLAUDE_CODE_SIMPLE="1"`，但不能静默启用。必须说明它会减少系统提示词和运行时功能面，并跳过 hooks、LSP、插件同步、署名、自动记忆和后台预取等加载；这些资产不会被删除。

如果用户只想偶尔使用精简模式，建议运行 `claude --bare`，而不是持久修改全局设置。

### macOS 时区

在 macOS 上显示当前时区，并建议使用 `Asia/Taipei`。由于这会改变系统时钟显示和时间戳，必须保持可选并单独确认。

脚本通过 macOS 原生 `sudo systemsetup` 修改时区。用户应直接在终端的隐藏密码提示中输入 Mac 开机密码。绝不能要求用户把密码发送、粘贴或透露给 Agent，也不能读取或保存密码。
