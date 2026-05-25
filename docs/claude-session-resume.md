# Claude Session Resume - 需求设计文档

> **版本**: 1.0
> **日期**: 2026-01-20
> **作者**: Kyle Li

---

## 1. 背景

日常工作中大量使用 Claude Code / Copilot 作为 AI Agent 辅助完成工作。这些工作分为两类：
- **准备性工作**: 需要时间沉淀，分阶段完成
- **推进型工作**: 需要持续跟进，分多次会话完成

**痛点**: 希望在某天完成一部分工作后，安排在未来某个时刻自动恢复该会话，而不是重开新 session（丢失上下文）。

---

## 2. 目标

实现 **定时恢复 Claude Code 会话** 的能力：

```
用户: "后天四点半帮我 resume 这个 session"
系统: 通过 macOS launchctl 调度，在指定时间自动启动 Claude 并恢复原会话
```

---

## 3. 现有基础

### 3.1 iKit Timer 能力

| 功能 | 说明 |
|------|------|
| LaunchAgents 调度 | 使用 `launchctl` 实现系统级定时任务 |
| 确认对话框 | AppleScript `display dialog` 显示确认按钮 |
| Ghostty 集成 | 可在新 Tab 中执行命令 |
| 参数支持 | `--time`, `--date`, `--daily`, `--weekday`, `--run`, `--then-run` |

### 3.2 ~/dotfiles/bin/99 模式

```bash
# ~/dotfiles/bin/99 - 避免 osascript 输入法拦截问题
#!/bin/bash
cd ~/Notebooks
PROMPT_FILE="/tmp/claude-prompt.txt"
if [[ -f "$PROMPT_FILE" ]]; then
    PROMPT=$(cat "$PROMPT_FILE")
    rm -f "$PROMPT_FILE"
    cd ~/Notebooks && claude --permission-mode bypassPermissions "$PROMPT"
fi
```

**设计思路**: 使用数字 `99` 而不是字母，规避输入法切换问题。

---

## 4. 解决方案设计

### 4.1 架构流程

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│  Claude Session │ ───> │  iKit timer      │ ───> │  LaunchAgents   │
│  (Current)      │      │  resume command  │      │  (.plist)       │
└─────────────────┘      └──────────────────┘      └─────────────────┘
                                                              │
                                                              │ Scheduled Time
                                                              ▼
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│  Ghostty New    │ <────│  ~/dotfiles/bin/98│ <────│  launchctl      │
│  Tab + claude   │      │  (session resume) │      │  trigger        │
│  --resume       │      └──────────────────┘      └─────────────────┘
└─────────────────┘                                        │
           │                                                 │
           │ Confirmation Dialog                            │
           ▼                                                 │
┌─────────────────┐      ┌──────────────────┐               │
│  User Confirms  │ ───> │  Claude Resumed  │ <─────────────┘
│  (AppleScript)  │      │  (Original Context)             │
└─────────────────┘      └──────────────────┘
```

### 4.2 核心流程（基于现有 iKit Timer 架构）

**关键理解**: iKit timer 通过 launchctl 实现，定时器触发时会回调 `ikit timer execute <taskName>`

```
用户: ikit timer resume --time 16:30 --session abc123
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│ iKit TimerTool.create()                                         │
│ ├─ 生成 plist: ~/Library/LaunchAgents/com.user.timer-xxx.plist │
│ │  └─ ProgramArguments: ikit timer execute <taskName>          │
│ ├─ 保存 config: ~/Library/Logs/.../timer-xxx.json              │
│ │  └─ { "sessionId": "abc123", "title": "...", ... }           │
│ └─ launchctl load <plist>                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (定时触发)
┌─────────────────────────────────────────────────────────────────┐
│ launchctl 运行: ikit timer execute <taskName>                  │
│         │                                                       │
│         ▼                                                       │
│ TimerTool.execute()                                             │
│ ├─ 读取 config JSON                                             │
│ ├─ 获取 sessionId                                               │
│ └─ 调用 executeAction()                                         │
│         │                                                       │
│         ▼                                                       │
│ executeAction() - Session Resume 分支                           │
│ ├─ 写入 /tmp/claude-resume-session.txt (sessionId)             │
│ ├─ osascript 显示确认对话框                                      │
│ └─ 用户确认后:                                                   │
│    └─ AppleScript 激活 Ghostty, 新 Tab, 输入 "98 "              │
│         │                                                       │
│         ▼                                                       │
│ ~/dotfiles/bin/98                                               │
│ └─ claude --resume abc123                                       │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 新增组件

#### 组件 1: `~/dotfiles/bin/98` - Session Resume 脚本

```bash
#!/bin/bash
# Claude Session Resume Script
# Triggered by iKit timer to resume a specific Claude session

SESSION_FILE="/tmp/claude-resume-session.txt"
cd ~/Notebooks

if [[ -f "$SESSION_FILE" ]]; then
    SESSION_ID=$(cat "$SESSION_FILE")
    rm -f "$SESSION_FILE"

    if [[ -n "$SESSION_ID" ]]; then
        claude --permission-mode bypassPermissions --resume "$SESSION_ID"
    else
        echo "Error: No session ID provided" >&2
        exit 1
    fi
else
    echo "Error: Session file not found" >&2
    exit 1
fi
```

**设计要点**:
- 使用数字 `98` 规避输入法问题
- 读取临时文件获取 `sessionId`
- 执行 `claude --resume <sessionId>`

#### 组件 2: iKit Timer 新增 `--session` 参数

```swift
// iKit timer create 新增参数
func create(
    ...
    session: String?  // <-- 新增：Claude session ID
)
```

#### 组件 3: iKit Timer 新增 `resume` 子命令

```bash
# 便捷命令：直接安排当前 session 的恢复
ikit timer resume --time HH:MM [--date DATE]
```

---

## 5. 实现细节

### 5.1 用户工作流

#### 场景 A: 从当前会话安排恢复

```bash
# 1. 在 Claude Code 工作中
# 2. 获取当前 session ID（Claude 自动提供）
# 3. 告诉 iKit 安排恢复

ikit timer resume \
  --time 16:30 \
  --date 2026-01-22 \
  --session abc123def456 \
  --title "Resume: 代码重构任务"
```

#### 场景 B: 手动指定 session

```bash
ikit timer new \
  --time 09:00 \
  --session abc123def456 \
  --then-run "98" \
  --title "继续昨天的讨论"
```

### 5.2 AppleScript 执行流程

当定时器触发时：

```
1. 写入 session ID 到 /tmp/claude-resume-session.txt
2. 显示确认对话框: "⏰ Resume Session: [title]"
3. 用户点击 "确定"
4. 激活 Ghostty，打开新 Tab
5. 逐字符输入 "98 " (数字，无输入法问题)
6. 按下 Enter
7. ~/dotfiles/bin/98 读取 session ID 并执行 claude --resume
```

### 5.3 Session ID 获取方式

Claude Code 会自动维护 session 信息，可通过以下方式获取：

```bash
# 方式 1: Claude 内置环境变量
echo $CLAUDE_SESSION_ID

# 方式 2: 从 Claude conversations 目录读取
ls -t ~/.claude/conversations/ | head -1

# 方式 3: Claude Code 提供的 /session-id 命令
```

---

## 6. 技术规格

### 6.1 文件布局

```
~/dotfiles/bin/
├── 99                      # 现有：快速 Claude Ask
├── 98                      # 新增：Session Resume
└── ...

~/Library/LaunchAgents/
├── com.user.timer-session-abc123.plist  # 新增：Session resume 任务
└── ...

~/Library/Logs/com.user.ikit.timer/
├── timer-session-abc123.log              # 新增：Session resume 日志
└── ...

/tmp/
├── claude-resume-session.txt             # 新增：Session ID 传递
└── claude-prompt.txt                     # 现有：Prompt 传递
```

### 6.2 命令接口

```bash
# 新增: resume 子命令（便捷）
ikit timer resume --time HH:MM [--session ID] [--date DATE] ...

# 扩展: new 子命令支持 --session
ikit timer new --time HH:MM --session <ID> ...
```

### 6.3 任务命名规范

```
timer-session-{sessionId}-{timestamp}
```

示例: `timer-session-abc123-1737369600`

---

## 7. 实现清单

### Phase 1: 基础脚本

- [ ] 创建 `~/dotfiles/bin/98`
- [ ] 添加可执行权限 `chmod +x`
- [ ] 测试手动执行 `98` 命令

### Phase 2: iKit 扩展

- [ ] `TimerTool.create()` 添加 `session` 参数
- [ ] 添加 `saveSessionId()` 辅助方法
- [ ] 修改 `generateAppleScript()` 支持会话恢复
- [ ] 添加 `resume()` 便捷方法

### Phase 3: CLI 集成

- [ ] 添加 `--session` 参数解析
- [ ] 添加 `ikit timer resume` 子命令
- [ ] 更新 help 文本

### Phase 4: 测试验证

- [ ] 单元测试：创建 session resume 任务
- [ ] E2E 测试：完整流程验证
- [ ] 边界测试：无效 session ID 处理

---

## 8. 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| Session ID 过期/无效 | 添加验证逻辑，显示友好错误提示 |
| Ghostty 未运行 | AppleScript 自动启动 Ghostty |
| 输入法仍干扰数字输入 | 使用 `98` (数字) 已大幅降低风险 |
| 临时文件残留 | 执行后自动清理 `/tmp/claude-resume-session.txt` |

---

## 9. 未来扩展

- [ ] 支持多个 session 轮询恢复
- [ ] 与 Raycast 集成（快捷创建 resume 任务）
- [ ] Session 摘要生成（恢复时显示上次工作内容）
- [ ] 智能时间建议（基于历史模式）

---

**下一步**: 开始实现 Phase 1 - 创建 `~/dotfiles/bin/98` 脚本
