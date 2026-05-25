# iKit 目录结构设计 v2

## 设计原则

1. **不考虑兼容性** - 直接使用新路径
2. **iKit 自管理** - `ikit init` 创建目录结构
3. **与子命令一致** - 子目录对应子命令
4. **简单实用** - 不过度设计
5. **统一管理** - 目录操作收口到一个类

---

## 目录结构

```
~/.ikit/
├── timer/
│   ├── active/          # 当前活跃的 timer
│   │   ├── *.json       # 配置
│   │   └── *.log        # 日志
│   └── history.json     # resume 历史
│
├── meet/
│   ├── sessions/        # 会议会话
│   │   └── <session-id>/
│   │       ├── meta.json
│   │       ├── status.json
│   │       └── recordings/  # 录音文件
│   └── active.json      # 当前活跃会话
│
├── note/
│   └── cache/           # Notes 缓存
│       ├── folders.json
│       └── notes/
│
├── claude/
│   └── sessions.json    # session 列表
│
├── logs/
│   ├── ikit.log         # 主日志
│   └── timer/           # timer 日志
│
├── config/
│   └── config.json      # 主配置
│
└── run/
    ├── session-resume.txt
    └── daemon.pid
```

---

## 与子命令对应

| 子命令 | 目录 |
|--------|------|
| `ikit timer` | `~/.ikit/timer/` |
| `ikit meet` | `~/.ikit/meet/` |
| `ikit note` | `~/.ikit/note/` |
| `ikit claude` (新) | `~/.ikit/claude/` |
| `ikit config` | `~/.ikit/config/` |
| (通用) | `~/.ikit/logs/`, `~/.ikit/run/` |

不需要独立目录的子命令：
- `task` - 使用 EventKit，无本地数据
- `cal` - 使用 EventKit，无本地数据
- `photo` - 使用 Photos 框架，无本地数据
- `contact` - 使用 Contacts 框架，无本地数据
- `sc` - 调用 Shortcuts，无本地数据

---

## 代码实现

### Swift: IKitDir 类

```swift
// 统一的目录管理类
class IKitDir {
    static let root = FileManager.default.homeDirectoryForCurrentUser.path + "/.ikit"

    // 子目录
    static let timer = root + "/timer"
    static let meet = root + "/meet"
    static let note = root + "/note"
    static let claude = root + "/claude"
    static let logs = root + "/logs"
    static let config = root + "/config"
    static let run = root + "/run"

    // Timer 子目录
    static let timerActive = timer + "/active"

    // Meet 子目录
    static let meetSessions = meet + "/sessions"

    // Note 子目录
    static let noteCache = note + "/cache"

    // 路径方法
    static func sessionResumeFile() -> String { return run + "/session-resume.txt" }
    static func timerConfig(_ name: String) -> String { return timerActive + "/\(name).json" }
    static func timerLog(_ name: String) -> String { return timerActive + "/\(name).log" }
    static func meetSession(_ id: String) -> String { return meetSessions + "/\(id)" }

    // 初始化
    static func setup() {
        let dirs = [
            root,
            timer, timerActive,
            meet, meetSessions,
            note, noteCache,
            claude,
            logs, logs + "/timer",
            config,
            run
        ]

        for dir in dirs {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        }

        Logger.info("✅ iKit 目录已创建: \(root)")
    }

    // 清理
    static func clean() {
        // 删除旧文件、归档等
    }
}
```

### 新增子命令: `ikit init`

```swift
// 在 main.swift 中添加
} else if sub == "init" {
    IKitDir.setup()
    Logger.info("✅ iKit 初始化完成")
}
```

---

## 路径变更

| 旧路径 | 新路径 |
|--------|--------|
| `/tmp/claude-resume-session.txt` | `~/.ikit/run/session-resume.txt` |
| `~/Library/Logs/com.user.ikit.timer/` | `~/.ikit/timer/active/` |
| `~/recordings/ikit.log` | `~/.ikit/logs/ikit.log` |
| `~/.config/ikit/config.json` | `~/.ikit/config/config.json` |
| `~/recordings/` | `~/.ikit/meet/sessions/<id>/recordings/` |

---

## 使用示例

```bash
# 初始化 iKit
ikit init

# 创建 timer (自动创建目录)
ikit timer new --time 16:30 --pwd ~/Work/iKit

# 查看 resume 历史
cat ~/.ikit/timer/history.json

# Meeting 录音
ikit meet daemon ~/Documents/meeting-session
# → ~/.ikit/meet/sessions/<session-id>/recordings/
```

---

## 实现优先级

### Phase 1: 目录创建
- [ ] `IKitDir` 类
- [ ] `ikit init` 命令
- [ ] 更新现有路径

### Phase 2: Timer 迁移
- [ ] 更新 timer 路径
- [ ] history.json

### Phase 3: Meet 迁移
- [ ] 更新录音路径
- [ ] session 状态

### Phase 4: 其他
- [ ] Note 缓存
- [ ] Claude sessions
- [ ] 日志路径

---

## 总结

**简洁、一致、自管理**
- 子目录对应子命令
- `IKitDir` 统一管理
- `ikit init` 一键创建
