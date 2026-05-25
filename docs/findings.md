# Findings & Decisions - Session Resume 功能

## Requirements

### 用户原始需求
- 可以说"后天四点半帮我 resume 这个 session"
- 使用 macOS launchctl 机制调度
- 打开 Ghostty 新 tab 并执行 resume
- 避免输入法问题（使用数字命令如 99）
- 传递当前 session 的 pwd（resume 必须在原目录）

### 已实现功能
- ✅ 定时调度（launchctl）
- ✅ 确认对话框
- ✅ 打开 Ghostty 新 tab
- ✅ 传递 pwd 并 cd
- ✅ 使用 `--continue` resume 最近 session

### 待确认需求
- ❓ 是否需要持久化 resume 信息
- ❓ 是否需要查看历史 resume 记录
- ❓ 是否需要 resume 特定历史 session（而非最近的）

## Research Findings

### Claude Session 管理机制

**Session 数据位置**:
```
~/.claude/
├── history.jsonl                          # 全局历史（跨项目）
├── projects/
│   ├── -Users-kyle-Work-iKit/
│   │   ├── <session-id>.jsonl            # Session 对话内容
│   │   └── sessions-index.json           # Session 索引
│   └── -Users-kyle-Notebooks/
│       └── ...
```

**history.jsonl 格式**:
```json
{
  "display": "用户消息摘要",
  "timestamp": 1768895456243,
  "project": "~/Work/iKit",
  "sessionId": "0719ac9b-7006-4868-9181-9bb75e317b67"
}
```

**sessions-index.json 格式**:
```json
{
  "version": 1,
  "entries": [
    {
      "sessionId": "...",
      "fullPath": "...",
      "fileMtime": 1768891064172,
      "firstPrompt": "...",
      "messageCount": 38,
      "created": "2026-01-20T05:34:41.684Z",
      "modified": "2026-01-20T06:37:44.155Z",
      "gitBranch": "master",
      "projectPath": "~/Work/iKit",
      "isSidechain": false
    }
  ]
}
```

### Claude CLI Resume 选项

| 选项 | 参数 | 说明 |
|------|------|------|
| `--continue` | 无 | 继续当前目录最近的会话 |
| `--continue` | session-id | 继续指定 session |
| `--resume` | 无 | 打开交互式选择器 |
| `--resume` | session-id | 恢复指定 session |
| `--session-id` | uuid | 使用指定 session ID 创建新会话 |

**关键发现**:
- `--continue` 不需要 session ID，自动选择当前目录最近的 session
- `--continue` 是我们需求的最佳选择
- `--resume <id>` 需要 ID，但 "No conversation found" 错误表明只有活跃 session 可 resume

### launchd/LaunchAgent 行为

**LaunchAgent 位置**:
```
~/Library/LaunchAgents/com.user.timer-*.plist
```

**关键属性**:
- `Label`: 唯一标识符
- `ProgramArguments`: 执行的命令和参数
- `StartCalendarInterval` / `StartInterval`: 调度时间
- `RunAtLoad`: 加载时是否立即运行
- `StandardOutPath` / `StandardErrorPath`: 日志路径

**重启后行为** (待验证):
- ⚠️ macOS 登录时自动加载 `~/Library/LaunchAgents`
- ⚠️ 定时任务 schedule 应该保留
- ⚠️ 需要实际测试验证

## Technical Decisions

| Decision | Rationale |
|----------|-----------|
| 使用 `--continue` 而非 `--resume <id>` | 不需要手动获取 session ID，Claude 自动继续当前目录最近的会话。简化了实现，不需要复杂的 ID 获取逻辑。 |
| JSON 格式存储 session 信息 | 可扩展，易于解析，保留 sessionId 字段以备将来使用。Python json.load() 直接处理。 |
| ~~`/tmp` 用于临时 session 文件~~ | ~~系统重启后自动清理~~ |
| **`~/.ikit/` 统一目录** | 遵循 XDG 和 CLI 最佳实践，统一管理所有 iKit 文件 |
| `~/.ikit/run/` 存放运行时状态 | 包括 session-resume.txt、daemon.pid、lock 等临时但可持久的数据 |
| `~/.ikit/data/` 存放持久化数据 | timer、notes、meet、claude 等功能的数据 |
| XDG 目录结构 | `/config`, `/data`, `/cache`, `/logs`, `/run` 分离关注点 |
| 符号链接现有路径 | 向后兼容，逐步迁移，不破坏现有功能 |
| AppleScript 打开 Ghostty 新 tab | 与 claude-ask.sh 保持一致，使用 Finder trick 确保 new tab 打开。 |
| Python 解析 JSON 而非 jq | Python 是系统自带，jq 需要额外安装。从文件读取避免 shell 转义问题。 |

### `~/.ikit/` 目录结构设计

**完整结构** (`docs/ikit-directory-design.md`):
```
~/.ikit/
├── config/           → ~/.config/ikit/
├── data/             → ~/.local/share/ikit/
│   ├── timer/
│   ├── notes/
│   ├── meet/
│   └── claude/
├── cache/            → ~/.cache/ikit/
├── logs/             → ~/Library/Logs/com.user.ikit/
├── run/              → ~/.local/state/ikit/
│   └── session-resume.txt    ← 从 /tmp 移到这里
└── recordings/       → ~/recordings/
```

**优势**:
- 统一管理，易于备份 (`tar czf ikit-backup.tar.gz ~/.ikit`)
- 符合 XDG Base Directory Specification
- 清晰的子目录分离关注点
- 符号链接保持向后兼容

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Python JSON 解析失败（多行 JSON） | 修改为从文件读取 `with open('$SESSION_FILE', 'r')` 而非 shell 字符串传递 `json.loads('$CONTENT')` |
| osascript 输出格式检查 | 验证输出为 "button returned:确定"，`output.contains("确定")` 可以匹配 |
| Session ID 找不到 ("No conversation found") | 改用 `--continue` 而非 `--resume <id>`，不需要特定 session ID |

## Resources

### iKit 文件路径（新旧对比）

| 类型 | 旧位置 | 新位置 | 状态 |
|------|--------|--------|------|
| Config | `~/.config/ikit/` | `~/.ikit/config/` | 符号链接 |
| Timer logs | `~/Library/Logs/com.user.ikit.timer/` | `~/.ikit/logs/timer/` | 待迁移 |
| Timer data | `~/Library/Logs/com.user.ikit.timer/*.json` | `~/.ikit/data/timer/active/` | 待迁移 |
| Session resume | `/tmp/claude-resume-session.txt` | `~/.ikit/run/session-resume.txt` | 待迁移 |
| Main log | `~/recordings/ikit.log` | `~/.ikit/logs/ikit.log` | 待迁移 |
| Recordings | `~/recordings/` | `~/.ikit/recordings/` (符号链接) | 保持原位置 |
| LaunchAgents | `~/Library/LaunchAgents/` | (不变，macOS 要求) | 不迁移 |

### 代码文件
- Swift 源码: `Sources/iKit/main.swift`
- 启动脚本: `~/dotfiles/bin/ghostty-start.sh`
- 设计文档: `docs/ikit-directory-design.md`

### Claude 数据
- History: `~/.claude/history.jsonl`
- Sessions: `~/.claude/projects/*/sessions-index.json`

### 有用的命令
```bash
# 列出所有 timers
launchctl list | grep timer

# 查看 timer 日志
cat ~/Library/Logs/com.user.ikit.timer/timer-*.log

# 手动触发 timer
ikit timer execute <task-name>

# 获取最新 session ID
python3 << 'EOF'
import json
with open(os.path.expanduser("~/.claude/history.jsonl")) as f:
    for line in reversed(f.readlines()):
        data = json.loads(line)
        if data.get('project') == '~/Work/iKit':
            print(data.get('sessionId'))
            break
EOF
```

## Visual/Browser Findings

### osascript 对话框测试
- 命令: `osascript -e 'display dialog "测试" buttons {"取消", "确定"}'`
- 输出: `button returned:确定`
- Exit code: 0

### Session 文件格式验证
```json
{
  "sessionId": "test-continue",
  "pwd": "\/Users\/kyle\/Work\/iKit"
}
```
- JSON 格式正确
- Python json.load() 成功解析
- 字符串中的 `/` 被转义为 `\/`（正常）

---

**REMINDER**: 2-Action Rule
- 每查看/浏览 2 次后，必须更新此文件
- 防止视觉信息在上下文重置时丢失
