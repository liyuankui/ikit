# iKit 目录结构设计方案

## 设计原则

### 1. macOS 和 CLI 最佳实践

| 标准 | 用途 | iKit 使用 |
|------|------|----------|
| `~/.config/` | 配置文件 (XDG) | `~/.config/ikit/config.json` |
| `~/.local/state/` | 状态文件 (XDG) | 运行时状态、锁文件 |
| `~/.local/share/` | 数据文件 (XDG) | 持久化数据 |
| `~/.cache/` | 缓存文件 (XDG) | 可重新生成的数据 |
| `~/Library/Application Support/` | macOS 应用数据 | 兼容性考虑 |
| `~/Library/Caches/` | macOS 缓存 | 兼容性考虑 |

### 2. 决策

**采用混合方案**：
- **主目录**: `~/.ikit/` (简洁、易于访问)
- **符号链接**: 从标准位置链接到 `~/.ikit/`
- **向后兼容**: 保留现有路径，逐步迁移

---

## 目录结构设计

```
~/.ikit/
├── config/                    # 配置文件 (→ ~/.config/ikit/)
│   ├── config.json           # 主配置
│   └── defaults.json         # 默认配置
│
├── data/                      # 持久化数据 (→ ~/.local/share/ikit/)
│   ├── timer/                # Timer 数据
│   │   ├── active/           # 活跃的 timer 配置
│   │   │   ├── *.json        # task config
│   │   │   └── *.log         # execution log
│   │   ├── history/          # 历史记录
│   │   │   └── resume-history.json
│   │   └── archives/         # 已完成的 timer
│   │
│   ├── notes/                # Notes 缓存 (fallback)
│   │   ├── cache/            # Apple Notes 缓存
│   │   │   ├── folders.json  # folder 列表 + ID 映射
│   │   │   └── notes/        # note 内容缓存
│   │   │       └── <folder-id>/
│   │   │           └── <note-id>.json
│   │   └── sync-state.json   # 同步状态
│   │
│   ├── meet/                 # Meeting 数据
│   │   ├── sessions/         # 会议会话
│   │   │   └── <session-id>/
│   │   │       ├── meta.json         # 会话元数据
│   │   │       ├── status.json        # 执行状态
│   │   │       ├── transcriptions/   # 转录结果
│   │   │       └── recordings/        # 录音文件引用
│   │   └── active.json       # 当前活跃会话
│   │
│   └── claude/               # Claude Code 集成
│       ├── sessions.json     # session 列表缓存
│       └── resume-history.json
│
├── cache/                     # 缓存文件 (→ ~/.cache/ikit/)
│   ├── notes/                # Notes 临时缓存
│   └── thumbnails/           # 图片缩略图
│
├── logs/                      # 日志文件 (→ ~/Library/Logs/com.user.ikit/)
│   ├── ikit.log              # 主日志
│   ├── timer/                # Timer 日志
│   └── meet/                 # Meeting 日志
│
├── run/                       # 运行时状态 (→ ~/.local/state/ikit/)
│   ├── daemon.pid            # daemon 进程 ID
│   ├── lock                  # 锁文件
│   └── session-resume.txt    # ← 从 /tmp 移到这里
│
└── recordings/                # 录音文件 (→ ~/recordings/)
    └── -> ~/recordings/      # 符号链接
```

---

## 迁移策略

### Phase 1: 创建新目录结构（不影响现有）

```bash
# 创建 ~/.ikit 目录
mkdir -p ~/.ikit/{config,data,cache,logs,run}

# 创建子目录
mkdir -p ~/.ikit/data/{timer,notes,meet,claude}
mkdir -p ~/.ikit/data/timer/{active,history,archives}
mkdir -p ~/.ikit/data/notes/cache
mkdir -p ~/.ikit/data/meet/sessions
mkdir -p ~/.ikit/cache/notes
mkdir -p ~/.ikit/logs/{timer,meet}

# 符号链接：现有位置
ln -s ~/.config/ikit ~/.ikit/config
ln -s ~/recordings ~/.ikit/recordings
ln -s ~/Library/Logs/com.user.ikit.timer ~/.ikit/logs/timer-active
```

### Phase 2: 代码逐步迁移

| 组件 | 当前位置 | 新位置 | 优先级 |
|------|----------|--------|--------|
| Config | `~/.config/ikit/` | `~/.ikit/config/` | 低（已有符号链接） |
| Timer logs | `~/Library/Logs/com.user.ikit.timer/` | `~/.ikit/logs/timer/` | 中 |
| Timer config | `~/Library/Logs/com.user.ikit.timer/*.json` | `~/.ikit/data/timer/active/` | 中 |
| Session resume | `/tmp/claude-resume-session.txt` | `~/.ikit/run/session-resume.txt` | 高 |
| Notes cache | 无 | `~/.ikit/data/notes/` | 低 |
| Meet state | 无 | `~/.ikit/data/meet/` | 中 |
| Main log | `~/recordings/ikit.log` | `~/.ikit/logs/ikit.log` | 低 |

### Phase 3: 向后兼容

```swift
// 优先使用新路径，fallback 到旧路径
let ikitRoot = FileManager.default.homeDirectoryForCurrentUser.path + "/.ikit"

// Config
let configPaths = [
    "\(ikitRoot)/config/config.json",      // 新
    "~/.config/ikit/config.json"            // 旧 (fallback)
]

// Logs
let logPaths = [
    "\(ikitRoot)/logs",                    // 新
    "~/recordings"                          // 旧 (fallback)
]
```

---

## 具体设计

### 1. Timer 数据结构

```
~/.ikit/data/timer/
├── active/                               # 当前活跃的 timer
│   ├── timer-session-abc-123.json        # 配置
│   └── timer-session-abc-123.log         # 日志
│
├── history/                              # 历史记录
│   └── resume-history.json              # {
│                                         //   "timestamp": "...",
│                                         //   "pwd": "~/Work/iKit",
│                                         //   "status": "completed"
│                                         // }
│
└── archives/                             # 已完成/取消的 timer
    └── timer-once-20260120-1600.json    # 移动到这里
```

**Resume history 格式**:
```json
{
  "history": [
    {
      "id": "resume-20260120-163000",
      "timestamp": "2026-01-20T16:30:00Z",
      "pwd": "~/Work/iKit",
      "status": "completed",
      "sessionId": "optional-if-known"
    }
  ]
}
```

### 2. Notes 缓存结构

```
~/.ikit/data/notes/
├── cache/
│   ├── folders.json                     # {
│                                         //   "folders": [
│                                         //     {"id": "...", "name": "散文", "path": "散文"}
│                                         //   ]
│                                         // }
│   └── notes/
│       └── <folder-id>/
│           └── <note-id>.json           # {
│                                         //   "id": "...",
│                                         //   "name": "标题",
│                                         //   "body": "内容",
│                                         //   "cached_at": "..."
│                                         // }
│
└── sync-state.json                      # {
                                          //   "last_sync": "...",
                                          //   "last_hash": "..."
                                          // }
```

**用途**: 当 AppleScript 不可用时的 fallback

### 3. Meeting 状态结构

```
~/.ikit/data/meet/
├── sessions/
│   └── <session-id>/                    # 例如: 20260120-120000
│       ├── meta.json                    # {
│                                         //   "id": "...",
│                                         //   "started_at": "...",
│                                         //   "mode": "both",  # both/mic-only/system-only
│                                         //   "interval": 15
│                                         // }
│       ├── status.json                  # {
│                                         //   "state": "recording",  # recording/stopped/transcribing
│                                         //   "current_segment": 1,
│                                         //   "last_heartbeat": "..."
│                                         // }
│       ├── transcriptions/
│       │   ├── segment_1_mic.json
│       │   ├── segment_1_sys.json
│       │   └── final.json
│       └── recordings/
│           └── -> ~/recordings/20260120-120000/
│
└── active.json                          # 当前活跃的 session ID
```

### 4. 运行时状态

```
~/.ikit/run/
├── daemon.pid                           # daemon 进程 ID
├── lock                                 # 锁文件 (flock)
└── session-resume.txt                   # ← 从 /tmp 移到这里
                                        # 更持久，重启后可查看历史
```

---

## 实现优先级

### 优先级 1: 立即实施
1. ✅ 创建 `~/.ikit/` 目录结构
2. ✅ 移动 `session-resume.txt` 到 `~/.ikit/run/`
3. ✅ 符号链接现有路径

### 优先级 2: 近期实施
4. Timer 历史记录功能
5. Meeting 状态持久化
6. Notes 缓存

### 优先级 3: 长期优化
7. 完整迁移到新路径
8. 数据清理/归档机制
9. 备份/恢复工具

---

## 代码变更

### Swift (main.swift)

```swift
// 新增: IKit 目录管理
class IKitDirectory {
    static let root = FileManager.default.homeDirectoryForCurrentUser.path + "/.ikit"
    static let config = root + "/config"
    static let data = root + "/data"
    static let cache = root + "/cache"
    static let logs = root + "/logs"
    static let run = root + "/run"

    static func setup() {
        // 创建目录结构
        // 创建符号链接
        // 迁移现有数据
    }
}

// Session resume 文件路径变更
let sessionFile = "\(IKitDirectory.run)/session-resume.txt"  // 旧: /tmp/

// Timer 配置路径
let timerDataDir = "\(IKitDirectory.data)/timer/active"
```

### Shell (ghostty-start.sh)

```bash
# 新的 session 文件位置
SESSION_FILE="$HOME/.ikit/run/session-resume.txt"
```

---

## 总结

| 优势 | 说明 |
|------|------|
| **统一管理** | 所有 iKit 相关文件在一处 |
| **易于备份** | `~/.ikit` 一个目录即可 |
| **符合标准** | 遵循 XDG 和 macOS 约定 |
| **向后兼容** | 符号链接保留旧路径 |
| **可扩展** | 清晰的子目录结构 |
| **调试友好** | 日志、状态、数据分离 |

**建议**: 立即创建目录结构，逐步迁移，保持向后兼容。
