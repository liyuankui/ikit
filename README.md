# iKit: Apple Ecosystem Agent-Native CLI

`iKit` is a high-performance, native macOS CLI designed specifically for AI Agents. It unifies the management of Apple's core productivity apps.

**Version**: v2.7.0 (Daemon Reliability)

---

## 核心功能

### 📝 Notes (备忘录)
- **极速同步**: 智能增量同步，支持 ID 隔离
- **安全写入**: 原子化操作，自动同步

### 📋 Tasks & 📅 Calendar
- 基于 `EventKit`，无需启动 App 即可毫秒级读写

### 🖼 Photos
- **Batch OCR**: 批量识别截图文字
- **智能搜索**: 按截图/收藏筛选

### 🎙 Meet (会议助手)
- **双轨录制**: 麦克风 + 系统音频独立录制
- **Aggressive Gating**: 自动消除回声，避免重复转录
- **说话人分离**: 自动区分 Local/Remote 说话人
- **本地转写**: 集成 FunASR，完全离线处理
- **后台模式**: 可靠的后台录音，支持心跳检测和优雅退出
- **状态管理**: `status`/`stop` 命令管理 daemon 生命周期
- **预检查**: 启动前检查磁盘空间、FunASR 可用性、权限

---

## 快速开始

### 编译与安装
```bash
cd ~/Work/iKit
swift build -c release
cp .build/release/ikit ~/.local/bin/ikit
```

### 基础配置
`~/.config/ikit/config.json`:
```json
{
  "notes_root": "~/Notebooks/AppleNotes",
  "python_path": "/path/to/python",
  "transcribe_script": "/path/to/transcribe.py",
  "meet": {
    "default_interval": "15m",
    "default_mode": "both",
    "auto_transcribe": true
  }
}
```

**Meet 配置说明**：
- `default_interval`: 默认录音片段时长（格式：`60s`, `5m`, `1h`）
- `default_mode`: 录音模式（`both`, `mic-only`, `system-only`）
- `auto_transcribe`: 是否自动转录录音文件

### 依赖安装
```bash
# Python 依赖（用于转录）
pip install torch torchaudio funasr modelscope librosa scipy soundfile

# Pre-commit hooks（开发）
pip install pre-commit
pre-commit install
```

---

## 开发工具

### Pre-commit Hooks

项目使用 pre-commit 进行代码质量检查。配置文件：`.pre-commit-config.yaml`

首次设置：
```bash
# 安装 pre-commit
pip install pre-commit

# 安装 git hooks
pre-commit install

# 手动运行所有检查
pre-commit run --all-files
```

包含的检查：
- **trailing-whitespace**: 删除行尾空白
- **end-of-file-fixer**: 确保文件以换行符结尾
- **check-yaml**: YAML 语法检查
- **check-added-large-files**: 防止大文件（>1MB）
- **detect-private-key**: 检测私钥泄露
- **swift-format**: Swift 代码格式化（需单独安装：`brew install swift-format`）

跳过检查（紧急情况）：
```bash
git commit --no-verify -m "message"
```

---

## Meet 会议助手使用

### 1. 启动 Daemon

#### 后台模式（推荐）
```bash
# 后台运行 + 新 interval 格式
ikit meet daemon ~/recordings --background --interval=15m

# 检查状态
ikit meet status
# ✅ Daemon running (PID: 12345)
# 💚 Heartbeat: 5s ago
# 📁 Output: /Users/xxx/recordings/2026-01-25

# 停止 daemon（优雅退出，保存当前录音）
ikit meet stop
```

#### 录制模式
```bash
# 默认模式（麦克风 + 系统音频）
ikit meet daemon ~/recordings

# 只录系统音频（无回声风险）
ikit meet daemon --system-only ~/recordings

# 只录麦克风
ikit meet daemon --mic-only ~/recordings
```

#### 新 Interval 格式
- `60s` - 60 秒
- `5m` - 5 分钟
- `1h` - 1 小时

**旧格式已弃用**: `--interval=60` (分钟) 将在 v3.0.0 移除

#### 启动前预检查
Daemon 启动时会自动运行：
- ✅ 磁盘空间检查（需要至少 5GB）
- ✅ FunASR 可用性检查
- ✅ 输出目录权限检查

#### 心跳文件
Daemon 每 10 秒更新一次 `.heartbeat` 文件：
- 💚 Heartbeat: 5s ago（正常）
- 💔 Heartbeat stale: 45s ago（进程可能卡死）

### 2. 输出文件结构
```
~/recordings/
├── 2026-01-12T080000Z_mic.m4a   # 麦克风录音
└── 2026-01-12T080000Z_sys.m4a   # 系统音频录音
```

### 3. 转录（带 Gating）
```bash
# 双轨转录 + 自动回声消除 + 说话人分离
python scripts/transcribe.py \
  ~/recordings/2026-01-12T080000Z_mic.m4a \
  ~/recordings/2026-01-12T080000Z_sys.m4a \
  -o transcript.json

# 输出 JSON：
{
  "sentence_info": [
    {"text": "大家好", "speaker": "Remote", "start": 0, "end": 1000},
    {"text": "请继续", "speaker": "Local", "start": 1500, "end": 2500}
  ]
}
```

### 4. 会议纪要生成

#### 说话人映射管理
```bash
# 映射说话人 ID 到真实姓名
python scripts/speaker_mapper.py set 2026-01-25 afternoon 0 "张三" \
  --context "产品经理，负责需求讨论"

# 查看映射
python scripts/speaker_mapper.py get 2026-01-25 afternoon 0

# 列出所有会议的映射
python scripts/speaker_mapper.py list
```

#### 生成会议纪要
```bash
# 生成带说话人识别的会议纪要
python scripts/generate_meeting_summary.py \
  ~/recordings/2026-01-25 \
  --date 2026-01-25 \
  --session afternoon \
  --interactive

# 输出包含：
# - 执行摘要
# - 讨论要点（带说话人）
# - 决策记录（带提议者）
# - 行动项（带负责人）
# - 时间线
```

### 5. OCR 工具
```bash
# 使用 Vision 框架进行 OCR
swift scripts/ocr_images.swift ~/recordings/2026-01-25/*.png

# 简化的 Python OCR 封装
python scripts/ocr_simple.py ~/recordings/2026-01-25/screenshot.png
```

---

## ⏰ Timer (定时任务)

基于 macOS LaunchAgents 的定时提醒和自动化工具。

### 功能特点
- **灵活调度**: 支持一次性、每日、每周重复
- **多文件支持**: 可同时打开多个文件或应用
- **自动化工作流**: 打开文件 + 运行命令组合
- **用户确认**: 触发时显示对话框，避免误操作
- **执行日志**: 记录每次触发的详细历史

### 使用示例

#### 1. 每日提醒
```bash
# 每天下午 5 点提醒写日报
ikit timer new --time 17:00 --daily --title "Daily Report" \
  --message "Time to write your daily report"
```

#### 2. 多文件打开
```bash
# 每周一早上 9 点打开会议文档
ikit timer new --time 09:00 --weekday 1 --title "Weekly Standup" \
  --open ~/docs/agenda.md \
  --open ~/docs/notes.txt \
  --open ~/spreadsheet/budget.xlsx
```

#### 3. 打开 URL + 运行命令
```bash
# 周三下午 2 点打开会议链接，然后启动开发环境
ikit timer new --time 14:00 --weekday 3 \
  --open "https://meeting.url/join" \
  --with "Google Chrome" \
  --then-run "cd ~/work && npm start" \
  --title "Team Meeting"
```

#### 4. 指定日期任务
```bash
# 2025-01-20 晚上 8 点提醒参加线上会议
ikit timer new --time 20:00 --date 2025-01-20 \
  --open "https://zoom.us/j/123456" \
  --title "Product Review"
```

### 命令参考

| 子命令 | 功能 | 示例 |
|--------|------|------|
| `new` | 创建定时任务 | `ikit timer new --time 09:00 --daily` |
| `list` | 列出所有定时任务 | `ikit timer list` |
| `cancel` | 取消定时任务 | `ikit timer cancel timer-daily-0900` |
| `logs` | 查看执行日志 | `ikit timer logs timer-daily-0900` |

### 参数说明

| 参数 | 说明 | 示例 | 是否必需 |
|------|------|------|----------|
| `--time HH:MM` | 触发时间（24小时制）| `--time 09:30` | ✅ 是 |
| `--daily` | 每天重复 | `--daily` | ❌ 否 |
| `--date YYYY-MM-DD` | 指定日期（一次性）| `--date 2025-01-20` | ❌ 否 |
| `--weekday N` | 每周重复（0=周日, 1=周一, ..., 6=周六）| `--weekday 1` | ❌ 否 |
| `--open FILE` | 触发时打开文件（可多次使用）| `--open file.md` | ❌ 否 |
| `--with APP` | 指定打开文件的应用 | `--with "Typora"` | ❌ 否 |
| `--run COMMAND` | 直接运行命令（无确认）| `--run "notify-send Hello"` | ❌ 否 |
| `--then-run COMMAND` | 确认后运行命令 | `--then-run "npm test"` | ❌ 否 |
| `--terminal APP` | 运行命令的终端 | `--terminal Ghostty` | ❌ 否 |
| `--title TITLE` | 对话框标题 | `--title "Meeting"` | ❌ 否 |
| `--message TEXT` | 对话框内容 | `--message "Start?"` | ❌ 否 |

### 工作原理

1. **创建**: 生成 `~/Library/LaunchAgents/com.user.timer-<name>.plist`
2. **加载**: 自动加载到 launchd（登录后自动生效）
3. **触发**: 到达指定时间时执行 AppleScript：
   - 记录触发日志
   - 打开文件（如果指定）
   - 显示确认对话框
   - 运行命令（如果用户确认）
4. **日志**: 执行历史保存在 `~/Library/Logs/com.user.ikit.timer/`

### 注意事项

- ⚠️ `--daily`、`--date`、`--weekday` 三者互斥，只能指定一个
- ⚠️ 时间必须采用 24 小时制（09:00 表示上午 9 点，21:00 表示晚上 9 点）
- ⚠️ 文件路径支持 `~` 展开为用户主目录
- ⚠️ 使用 `launchctl list` 可查看系统级别的定时任务
- 💡 定时任务在登录后自动加载，无需手动操作

### 常见问题

**Q: 如何查看定时任务是否已加载？**
```bash
# 方法 1: 使用 iKit
ikit timer list

# 方法 2: 使用 launchctl
launchctl list | grep timer
```

**Q: 定时任务没有触发怎么办？**
```bash
# 1. 检查任务是否已加载
launchctl list | grep timer

# 2. 查看系统日志
log show --predicate 'process == "launchd"' --last 1h | grep timer

# 3. 查看执行日志
ikit timer logs <identifier>
```

**Q: 如何永久删除定时任务？**
```bash
# 1. 取消任务（卸载 + 删除文件）
ikit timer cancel <identifier>

# 2. 手动清理（如果上述命令失败）
launchctl bootout gui/$(id -u)/com.user.timer-<name>
rm ~/Library/LaunchAgents/com.user.timer-<name>.plist
```

---

## Aggressive Gating 原理

### 问题：回声导致重复转录
```
对方说话 → Speaker → 空气 → Mic
                          ↓
                      回声（模糊）
                          ↓
                    ASR 识别两次 ❌
```

### 解决：Aggressive Gating
```
对方说话时：
  System Energy > threshold → Mic 静音

  结果：对方说话只被识别一次 ✅
```

### 参数
- **threshold**: 0.05 (-26dB) - 触发静音的能量阈值
- **margin**: 0.1s (100ms) - 前后扩展时间，彻底消灭残留

---

## 录制模式对比

| 模式 | 适用场景 | 回声风险 |
|------|----------|----------|
| `--system-only` | 会议记录（无麦克风） | 无 |
| `both` (戴耳机) | 需要麦克风输入 | 无 |
| `both` (扬声器) | 需要麦克风 + Gating | Gating 消除 |

---

Copyright © 2026 Kyle Li. All rights reserved.
