---
name: meeting-recorder
description: 会议录音与转录自动化。支持 iKit + MacWhisper 双工作流，自动转录、生成会议纪要、归档到 journal/intent。当用户说"录个会"/"解读会议"/"生成纪要"时使用。
dependencies:
  - name: outlook-helper
    check: "ls {SKILL_DIR}/../outlook-helper/SKILL.md"
    docs: "Outlook 365 日历集成，用于自动获取会议信息"
---

# Meeting Recorder

## Overview

**Meeting Recorder** 是会议录音与转录自动化的 Agent 接口，支持两种工作流：

1. **iKit Workflow**: 原生录音 → FunASR 实时转录 → Agent 生成纪要
2. **MacWhisper Workflow**: 自动录音/转录 → Inbox 解读 → Agent 处理

## Token Efficiency (Progressive Disclosure)

**Layer 0: Frontmatter** (~100 tokens, always loaded)
- Description 包含所有触发词：录个会、解读会议、生成纪要

**Layer 1: SKILL.md Body** (<5K tokens, on trigger)
- 核心工作流（iKit + MacWhisper）
- Agent 指令（3个场景）
- 配置表格

**Layer 2: Resources** (as needed)
- `scripts/merge-transcripts.js` - 执行而非加载
- `references/` - 按需访问

## When to Use

- "帮我录个会" → 启动 iKit daemon
- "解读一下最新的会议记录" → 处理 MacWhisper inbox
- "生成会议纪要" → 读取转录 JSON 生成纪要
- "参会人都有谁" → 从 iKit 日志提取窗口标题
- "管理定期会议" → list/add/update 定期会议信息

## Configuration

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| **录音位置** | iKit 录音基础目录 | `~/recordings/` |
| **实际目录** | iKit 自动创建 | `~/recordings/YYYY-MM-DD/` |
| **转录位置** | MacWhisper 输出 | `{WORKSPACE_DIR}/inbox/whisper/*.md` |
| **Interval** | 录音片段时长 | `5m` ~ `10m` |
| **截图间隔** | 参会人识别截图 | `3m` (180秒) |
| **Teams 会议** | 音频模式 | `both` (麦克风 + 系统) |
| **非 Teams** | 音频模式 | `mic-only` |
| **用户时区** | 会议时间转换 | `Asia/Shanghai` (UTC+8)，按需修改 |

> 💡 **WORKSPACE_DIR**: 你的工作区根目录，如 `~/Notebooks`。SKILL_DIR: 本 skill 所在目录。

**⚠️ 目录结构重要说明**: iKit 会在用户指定的目录下**自动创建** `YYYY-MM-DD` 格式的日期子目录。传入 `~/recordings/` 即可，不要自己再加日期层。

### 截图间隔配置

**iKit 配置文件**: `~/.config/ikit/config.json`

```json
{
  "screenshot_interval": 180.0,
  "auto_ocr": false
}
```

**决策依据**: 3 分钟平衡 CPU 占用和信息捕获密度（详见 `references/decisions-template.md`）

## Recurrent Meetings Management

定期会议信息自动匹配与历史记录关联。

### 数据结构

**存储位置**: `data/recurrent-meetings.json`

```json
{
  "meetings": [
    {
      "id": "biweekly-planning",
      "name": "Biweekly Planning Meeting",
      "name_zh": "双周计划会议",
      "frequency": "biweekly",
      "day_of_week": "thursday",
      "time_range": "10:00-12:00",
      "timezone": "Asia/Shanghai",
      "description": "Planning and roadmap discussion",
      "calendar_link": "",
      "default_attendees": ["{Name1}", "{Name2}"],
      "keywords": ["planning", "roadmap"],
      "intent_link": "{WORKSPACE_DIR}/intent/active.md#PlanningIntent",
      "workspace_link": "{WORKSPACE_DIR}/workspace/project-folder/",
      "created_at": "2026-01-01",
      "last_updated": "2026-01-01"
    }
  ]
}
```

### 管理命令

```bash
# 列出所有定期会议
node {SKILL_DIR}/scripts/meeting-manager.js list

# 匹配当前时间的会议
node {SKILL_DIR}/scripts/meeting-manager.js match

# 添加新会议
node {SKILL_DIR}/scripts/meeting-manager.js add \
  --name "Weekly Standup" \
  --day monday \
  --time "10:00-11:00" \
  --attendees "Name1,Name2,Name3"

# 查看会议历史记录
node {SKILL_DIR}/scripts/meeting-manager.js history biweekly-planning
```

> **SKILL_DIR**: 本 skill 所在目录，如 `~/.claude/skills/meeting-recorder` 或 `~/.agents/skills/meeting-recorder`

### 工作流集成

**当用户说"录个会"时**：
1. **立即启动录音**（时间敏感，优先）
2. 录音进行中，后台查询 Outlook 获取会议信息
3. 后续生成纪要时使用获取的信息

**生成纪要时**：
1. 根据关键词匹配定期会议
2. 自动添加历史记录链接
3. 归档时关联 intent/workspace 链接

### 匹配规则

| 规则 | 说明 |
|------|------|
| **时间匹配** | 当前星期 + 2小时时间窗口 |
| **关键词匹配** | 会议名称/ID/keywords 在转录中出现 |
| **手动确认** | Agent 询问用户确认匹配结果 |

---

## Outlook 集成

**依赖**: `/outlook-helper` skill

### 自动获取会议信息

**优先级**: Outlook > recurrent-meetings.json

当用户说"录个会"时，优先从 Outlook 获取当前会议信息：

```bash
# 获取当前/即将开始的会议
outlook calendar --days 1 | jq '.data[] | select(.start | fromdate | >= now | and (.start | fromdate | < now + 2h)))'
```

### 会议信息映射

| Outlook 字段 | 会议纪要字段 | 说明 |
|---------------|---------------|------|
| `subject` | 会议主题 | 直接使用 |
| `start` / `end` | 日期/时间 | 按本地时区 |
| `attendees` | 参会人 | 提取姓名 |
| `location` / `body` | 会议背景 | 补充信息 |

### 工作流

**启动录音时**（时间敏感）：
1. **立即启动录音** - 不等待任何查询
2. 后台自动调用 `/outlook-helper` 获取当前/即将开始的会议
3. 解析会议信息：主题、参会人、时间、地点、议程
4. **⚠️ 注意时区**：确认系统时区与工作时区一致

**生成纪要时**：
1. 使用 `/outlook-helper` 获取的会议信息填充纪要头部
2. 参会人从 Outlook attendees 提取（优先级最高）
3. 自动关联会议主题到 intent/workspace

**自动查询命令**：
```bash
# 获取当前时间 ±2 小时内的会议
outlook calendar --days 1 | jq '.data[] | select(.start | fromdate >= now - 7200 and .start | fromdate <= now + 7200)'
```

**查询优先级**：
| 数据源 | 优先级 | 说明 |
|--------|--------|------|
| `/outlook-helper` 实时查询 | 🔴 最高 | 自动获取，覆盖手动输入 |
| `recurrent-meetings.json` | 🟡 中等 | 定期会议备选 |
| 手动输入 | 🟢 最低 | 用户确认/补充 |

---

## Workflow A: iKit

### 1. 启动录音

```bash
# Teams 会议（推荐）
OUTDIR=~/recordings/
mkdir -p $OUTDIR
ikit meet daemon $OUTDIR --background --interval=5m

# 非 Teams 会议
OUTDIR=~/recordings/
ikit meet daemon $OUTDIR --background --interval=5m --mic-only
```

**⚠️ 重要**: iKit 会自动在 `OUTDIR` 下创建 `YYYY-MM-DD` 子目录，不要在传入路径中再加日期。

### 2. 查看状态

```bash
ikit meet status
# 输出示例:
# ✅ Daemon running (PID: 12345)
# 💚 Heartbeat: 5s ago
# 📁 Output: ~/recordings/2026-01-01
# 📊 Last log: [2026-01-01 17:16:10] 🔴 Recording segment: 20260101-171609
```

### 3. 停止录音

```bash
ikit meet stop
```

### 4. 读取转录

iKit 自动生成转录 JSON 文件：
```
~/recordings/YYYY-MM-DD/        # iKit 自动创建的日期目录
├── 20260101-110057_mic.m4a    # 音频
├── 20260101-110057_mic.json   # 转录
├── 20260101-110057_sys.m4a    # 系统音频 (both 模式)
├── 20260101-110057_sys.json
└── ikit-2026-01-01.log        # 日志
```

**目录结构**: `~/recordings/` (用户传入) → `YYYY-MM-DD/` (iKit 自动创建) → 文件

**JSON 结构**:
```json
{
  "key": "20260101-111648_mic",
  "text": "完整转录文本...",
  "sentences": [
    {"text": "句子", "start": 5020, "end": 6520, "spk": 0}
  ]
}
```

### 5. 合并转录

**⚠️ CRITICAL - 时间筛选陷阱**:
- 录音目录可能包含**全天多个会议**的转录文件
- 文件名格式: `20260101-HHMMSS.json`（HH=小时）
- **必须先确认时间范围**，再合并对应文件

**时间筛选流程**:
```bash
# 1. 先列出所有文件，确认时间范围
ls ~/recordings/2026-01-01/*.json | sort

# 2. 确认会议时间段（如 16:00-17:00），只合并对应文件
{SKILL_DIR}/scripts/merge-transcripts.js ~/recordings/2026-01-01 16

# 3. 如果全天只有一个会议，可以合并所有
{SKILL_DIR}/scripts/merge-transcripts.js ~/recordings/2026-01-01
```

**merge-transcripts.js 参数**:
| 参数 | 说明 | 示例 |
|------|------|------|
| directory | 录音目录 | `~/recordings/2026-01-01` |
| hour-prefix | 可选，时间前缀 | `16`（只处理 16:xx 文件） |

输出完整转录文本，供纪要生成使用。

### 6. 生成纪要

**优先从 Outlook 获取会议详细信息**：

```bash
# 根据会议时间查询 Outlook
outlook calendar --days 1 | jq '.data[] | select(.start | fromdate <= now and .end | fromdate >= now - 2h)'

# 提取会议信息
SUBJECT=$(outlook calendar --days 1 | jq -r '.data[0].subject')
ATTENDEES=$(outlook calendar --days 1 | jq -r '.data[0].attendees[].name')
LOCATION=$(outlook calendar --days 1 | jq -r '.data[0].location')
BODY=$(outlook calendar --days 1 | jq -r '.data[0].body' | strip_tags)
```

**会议信息映射**：

| Outlook 字段 | 纪要字段 | 说明 |
|---------------|----------|------|
| `subject` | 会议主题 | 直接使用 |
| `attendees[].name` | 参会人 | 优先于 iKit 日志提取 |
| `body` | 议程/背景 | 补充会议背景 |
| `location` | 地点 | 记录会议地点 |

**生成纪要流程**：
1. 查询 Outlook 获取会议主题、参会人、议程（body）
2. 基于转录文本提取精华、决策、行动项
3. 合并 Outlook 信息 + 转录内容 → 完整纪要
4. 等待用户确认行动项
5. 归档到 journal/

### 7. 归档规则

**归档位置**: `{WORKSPACE_DIR}/journal/YYYY-MM/YYYYMMDD-HHMM-{intent}-{topic}.md`

**双向链接**:
- 纪要 → Intent: `[[{WORKSPACE_DIR}/intent/active.md#IntentName]]`
- 纪要 → Workspace: `[[{WORKSPACE_DIR}/workspace/project-folder/]]`
- Intent → 纪要: `Meetings: [[{WORKSPACE_DIR}/journal/YYYY-MM/file.md]]`

**行动项**: 提取后等待用户确认，不自动写入系统。

## Workflow B: MacWhisper

### 1. MacWhisper 自动转录

MacWhisper 自动将转录结果保存到（可配置）：
```
{WORKSPACE_DIR}/inbox/whisper/
├── Meeting - Teams 2026-01-01 10_02_05.md
├── New Recording 2026-01-06 16_21_18.md
└── ...
```

### 2. 解读会议记录

读取最新的 inbox 文件，分析内容：

```bash
# 找最新文件
ls -t {WORKSPACE_DIR}/inbox/whisper/*.md | head -1
```

**文件结构**:
```markdown
# Meeting - Teams

**Date:** 2026 January 1 at 10:03

---

[完整的转录文本 + 自动生成的总结]

### 任务状态更新
- ...

### 行动项和任务分配
- ...
```

### 3. 处理与归档

**处理流程**:
1. 读取最新 inbox 文件
2. 提取关键信息（行动项、决策、待办）
3. 生成结构化纪要
4. **等待用户确认行动项**
5. 归档到 `{WORKSPACE_DIR}/journal/YYYY-MM/`
6. 原文件移至 `{WORKSPACE_DIR}/inbox/whisper/archive/`

**归档命名**: `YYYYMMDD-HHMM-{intent}-{topic}.md`

## Output Template

### 会议纪要模板

```markdown
# [会议主题]

**日期**: YYYY-MM-DD
**参与人**: 从 Outlook 获取（优先）/ iKit 日志提取（备选）
**地点**: 从 Outlook 获取
**录音**: ~/recordings/...

## 📋 会议议程（从 Outlook body 获取）
- 议程项 1
- 议程项 2

## 🎯 精华 (Highlights)
> **最 Inspiring / 最关心 / 值得传播**

聚焦用户关注领域（根据个人需求自定义）：

格式：
## 🎯 精华 (Highlights)

### 🚀 最 Inspiring
> [引用或洞察]

| 实践/洞察 | 影响/进展 |
|-----------|----------|
| ... | ... |

### 🤔 深度思考
> [核心观点/框架]

| 维度 | 内容 |
|------|------|
| ... | ... |

### 📌 值得关注
| 优先级 | 行动 | 截止 |
|--------|------|------|
| 🔥 | ... | ... |

**提取原则**：
- 少而精：3-5 个要点
- 可行动：能指导后续工作
- 可传播：值得分享给团队

---

## 摘要
简短总结会议核心内容

## 参会人
（从 iKit 日志的 calling app window 标题提取）
- {You} (host)
- {Colleague 1}
- {External Contact} (External - {Company})
- ...

## 讨论要点
- 要点 1
- 要点 2

## 决策
- 决策 1
- 决策 2

## 行动项
- [ ] [谁] [做什么] [截止时间]
- [ ] ...

## 后续跟进
- ...
```

## Troubleshooting

| 问题 | 解决方案 |
|------|----------|
| Daemon 未运行 | 检查 `ikit meet status`，心跳超时说明进程卡死 |
| **FunASR 预检查失败但实际可用** | 启动日志显示 "FunASR not found" 但 `transcribe` 命令成功。这是预检查和实际执行的不一致。直接运行 `ikit meet transcribe` 验证。 |
| **转录内容不对应会议** | **⚠️ 常见错误**：目录包含多个会议，直接合并所有文件导致内容混杂。先 `ls *.json` 确认时间范围，再用时间前缀筛选 |
| 转录为空 | 检查 FunASR 是否可用，音频文件是否损坏 |
| JSON 解析失败 | 验证 JSON 格式，检查编码问题 |
| 归档位置不确定 | 根据你的 intent 文件确定相关意图 |
| Inbox 满了 | 处理后移到 `{WORKSPACE_DIR}/inbox/whisper/archive/` |

### 参会人识别

**现状**: 截屏 OCR 功能已禁用（防止 CPU 峰值）

**推荐方案**: 从 iKit 日志提取窗口标题

```bash
# 提取参会人信息（从日志）
grep "calling app window" ~/recordings/YYYY-MM-DD/ikit-*.log
```

**Teams 窗口标题格式**:
- `Chat | <Name> | <Company> | <Email> | Microsoft Teams`
- `<Meeting Title> | <Org> | <Email> | Microsoft Teams`

**解析示例**:
```python
import re

log_line = "Microsoft Teams: Chat | John Doe | Company | john@company.com"
# 提取参会人姓名
names = re.findall(r'\|\s*([A-Za-z\s]+)\s*\|', log_line)
# 结果: ['John Doe']
```

**未来增强**: 可考虑添加 `--with-attendees` 参数，让 iKit 自动提取并保存参会人列表到 JSON metadata。

## Archive Structure

```
{WORKSPACE_DIR}/inbox/whisper/
├── archive/           # 已处理的文件
│   ├── 2026-02/
│   └── 2026-01/
├── Meeting - Teams 2026-01-01 10_02_05.md  # 待处理
└── ...
```

## Agent Instructions

### CRITICAL - 生成纪要规则

**会议转录前确认时间范围**:
- **必须**先与用户确认精确时间范围，**禁止**假设全录音或猜测时段
- 处理前验证选择的 transcript 文件是否匹配指定会议窗口
- **教训**: 多次因错误时段选择导致需用户纠正（如用了全天文件而非 16:00-17:00）

**日期计算禁止心算**:
- **必须**用 `python3` 计算日期，禁止假设
- 示例：计算周四日期
  ```bash
  python3 -c "from datetime import date, timedelta; d = date(2026, 3, 10); print(d + timedelta(days=4))"
  ```

### 当用户说"录个会"

**CRITICAL - 优先录音原则**:
- **立即启动录音**，会议已经开始，每秒信息都在流失
- **自动调用 `/outlook-helper`** 获取当前会议信息（后台，不阻塞录音）

**CRITICAL - 会议时长规律**:
- 用户会议最短 **15 分钟**，通常 **1 小时**
- **禁止**自动停止录音，除非用户明确指令
- "总结"/"解读"不是停止指令 → 继续录音，同时处理内容
- 停止触发词："停止录音"/"结束录音"/会议明确结束
- 误停后必须**立即重启**并道歉

**工作流程**:
1. **立即启动 iKit daemon**（默认 5m，Teams 用 both，其他用 mic-only）
2. **自动调用 `/outlook-helper` 获取会议信息**：
   ```bash
   # 获取当前时间 ±2 小时内的会议
   outlook calendar --days 1 | jq '.data[] | select(.start | fromdate >= now - 7200 and .start | fromdate <= now + 7200)'
   ```
3. **解析并展示获取到的会议信息**：
   - 主题、参会人、时间、地点、议程
   - **如果 Outlook 无数据** → 回退到手动询问
4. 告知用户录音已启动，会议信息已自动获取
5. 会议结束/生成纪要前确认信息准确性

**CRITICAL - 时区处理**：
- 确认系统时区设置正确（`date` 输出的时间应与当地时间一致）
- 直接用 `date` 获取当前时间，用 `python3` 计算日期时基于本地时区

### 当用户说"解读会议"

1. **主动询问会议信息**（补充元数据）：
   - "会议主题是什么？"
   - "有会议邀请/日历链接吗？"
   - "参会人都有谁？"
2. 检查 `{WORKSPACE_DIR}/inbox/whisper/` 最新文件
3. 读取并分析内容
4. 生成结构化纪要
5. **展示存疑内容等待确认**（专有名词、人名、决策点）
   - **必须包含**：编号(#.)、原文上下文(Context)、推测、需确认
   - **格式示例**：
     | #. | 原文 | Context | 推测 | 需确认 |
     |----|------|---------|------|--------|
     | 1.1 | "ECSRDS" | "就是呃ECSRDS那个比如计算存储那块" | ECS、RDS | ❓ |
6. **展示行动项等待确认**
7. 确认后归档到 `journal/`，原文件移到 `archive/`

### 当用户说"生成纪要"

1. **主动询问会议信息**（补充元数据）：
   - "会议主题是什么？"
   - "有会议邀请/日历链接吗？"
   - "参会人都有谁？"
2. 定位转录 JSON 目录（按日期）
3. 运行 `merge-transcripts.js` 合并转录
4. 使用 LLM 生成纪要
5. **🎯 生成精华部分 (Highlights)** - **必须包含**：
   - **最 Inspiring**: 创新实践、突破性进展
   - **深度思考**: 框架/原则/洞察
   - **值得关注**: 高优先级行动
   - **聚焦领域**（根据个人需求自定义，示例）：
     - Technical Innovation (新技术/工具/最佳实践)
     - Process Improvement (流程改进/效率)
     - Risk & Decisions (风险/决策点)
     - Team & Collaboration (团队/协作)
6. **展示存疑内容等待确认**（专有名词、人名、决策点）
   - **必须包含**：编号(#.)、原文上下文(Context)、推测、需确认
   - **格式示例**：
     | #. | 原文 | Context | 推测 | 需确认 |
     |----|------|---------|------|--------|
     | 1.1 | "ECSRDS" | "就是呃ECSRDS那个比如计算存储那块" | ECS、RDS | ❓ |
7. **展示行动项等待确认**
8. 确认后创建 MD 文件，归档到 `journal/` 并 `open`

### 当用户说"stop"（录音停止后）

**CRITICAL**: 停止录音后必须按此顺序处理：

1. **自动调用 `/outlook-helper` 获取会议信息**：
   ```bash
   # 获取最近结束/当前的会议
   outlook calendar --days 1 | jq '.data[] | select(.start | fromdate >= now - 7200 and .start | fromdate <= now + 7200)'
   ```
   - **解析并展示**：主题、参会人、时间、地点、议程
   - **如果无数据** → 回退到手动询问

2. **确认会议时间段**（用于筛选转录文件）

3. **先检查 iKit 转录结果** (Workflow A)
   ```bash
   # 列出所有转录文件，确认时间范围
   ls ~/recordings/$(date +%Y-%m-%d)/*.json 2>/dev/null | wc -l
   ```

4. **⚠️ 时间筛选步骤**（如果文件数 > 5）
   ```bash
   # 列出文件确认时间段
   ls ~/recordings/$(date +%Y-%m-%d)/*.json | sort

   # 只合并目标时间段的文件（如 16:00-17:00）
   {SKILL_DIR}/scripts/merge-transcripts.js ~/recordings/$(date +%Y-%m-%d) 16
   ```

   **文件数判断**:
   | 文件数 | 可能情况 | 处理方式 |
   |--------|----------|----------|
   | 1-5 | 单个短会议 | 直接合并所有 |
   | 6-20 | 可能是单个 1 小时会议 | 先询问确认时间 |
   | 20+ | 多个会议 | 必须筛选时间 |

   - 如果有 `.json` 文件 → 读取转录 → **生成纪要（含精华部分）** → **存疑内容确认** → 归档
   - 如果没有 → 继续步骤 5

   **生成纪要时必须包含精华部分 (Highlights)**：
   - 🎯 最 Inspiring：创新实践、突破性进展
   - 🤔 深度思考：框架/原则/洞察
   - 📌 值得关注：高优先级行动

   **目录说明**: iKit 在 `~/recordings/` 下自动创建 `YYYY-MM-DD/` 子目录。

5. **再检查 MacWhisper inbox** (Workflow B)
   ```bash
   ls -t {WORKSPACE_DIR}/inbox/whisper/*.md | head -1
   ```

6. **如果都没有** → 询问用户是否需要手动转录

**常见错误**:
- 直接合并所有文件 → 多个会议内容混杂
- 忘记确认时间 → 用了错误的转录内容
- 直接跳到 MacWhisper inbox → 忽略 iKit 已生成的转录
- **双重时区转换** → 确认系统时区后无需额外转换

### 归档决策

- 检查 intent 文件确定相关意图
- 关联 workspace 下的具体项目
- 创建双向链接

---

## 参会人验证流程 (CRITICAL)

### 转录内容的陷阱

**⚠️ 音译汉字 ≠ 真实信息**

| 陷阱类型 | 示例 | 正确处理 |
|----------|------|----------|
| **语音音译** | 音译名字 → 真实姓名的误识别 | 不当别名，需验证 |
| **OCR 误识别** | 截图 OCR 识别错误姓名 | 对照名单验证 |
| **私事内容** | 个人讨论混入会议 | 不记入纪要 |

**原则**: 转录内容必须人工验证，不能直接当真。

### 验证步骤

**Step 1: 从截图 OCR 提取参会人列表**
```bash
# 读取 screenshots_metadata.json（如果存在）
cat ~/recordings/YYYY-MM-DD/screenshots_metadata.json | jq '.[].names'
```

**Step 2: 对照人员名单验证**
- [ ] 姓名拼写是否正确
- [ ] 缩写/ID 是否匹配
- [ ] 角色/团队是否准确

**Step 3: 存疑确认格式**
```markdown
| #. | 原文 | Context | 推测 | 需确认 |
|----|------|---------|------|--------|
| 1.1 | "音译名" | "提到了某人" | 真实姓名? | ❓ |
```

### 新人处理

**如果参会人不在名单中**：

1. **主动询问用户**：
   - "参会人 [姓名] 不在数据库中，是否需要添加？"
   - 收集：姓名、邮箱、角色、团队

2. **更新联系人文件**：
   ```markdown
   ### [姓名] - [职位]

   **Contact:**
   - Email: [邮箱]
   - Location: [地点]

   **Role & Team:**
   - Team: [团队名]
   - Role: [职位]
   - Reports to: [上级]
   ```

3. **保存到工作区**

### 组织汇报关系（以常见结构为例）

**示例汇报线**:

| 类型 | 汇报线 | 说明 |
|------|--------|------|
| **Engineer** | → Engineering Manager (EM) | 工程汇报线 |
| **Product Owner (PO)** | → Director of Product | 产品线，非工程汇报 |

**常见错误** ❌:
- 将 PO 混入工程汇报线

## Continuous Improvement

### Feedback Workflow

当收到用户反馈时：

1. **捕获**: 记录反馈原文到 `references/learnings-YYYYMMDD.md`
2. **分类**: 识别反馈类型
3. **诊断**: 分析根本原因
4. **改进**: 应用修复
5. **文档**: 更新相关模板

### Feedback Categories

| 类型 | 示例 | 响应 |
|------|------|------|
| Trigger | "Skill 没触发" | 更新 frontmatter description |
| 输出格式 | "要的是 X 不是 Y" | 更新示例/模板 |
| 性能 | "太慢了" | 应用 token 效率模式 |
| 配置 | "间隔不合适" | 更新推荐值 |

### Quick Response Checklist

- [ ] 在 `references/learnings-YYYYMMDD.md` 捕获原文
- [ ] 识别症状类别
- [ ] 修复前先诊断根本原因
- [ ] 重大变更：添加到 `references/decisions-YYYYMMDD.md`
- [ ] 应用修复并测试
- [ ] 记录结果

### Related Resources

- `references/learnings-template.md` - 学习捕获模板
- `references/decisions-template.md` - 决策记录模板

---

**Version**: 2.6
**Maintainer**: {Your Name}
**Engine**: iKit + MacWhisper
**Updated**: 2026-03-18
**Changelog**:
- v2.6: 自动 Outlook 集成（录音启动/停止时自动获取会议元数据）
- v2.5: 新增定期会议管理 (Recurrent Meetings)
- v2.4: 会议纪要模板新增"精华 (Highlights)"部分
- v2.3: merge-transcripts.js 新增 hour-prefix 参数，支持按时间段筛选文件
- v2.2: 添加日期计算规则：禁止心算，必须用 python3 验证

---

### 多供应商/多会议录音识别

**诊断步骤**:
1. 列出会议时间表
2. 按时间戳定位录音文件
3. 打开 JSON 验证内容（品牌名、技术术语）
4. 对照供应商/会议特征确认归属

**通用识别规则**:
1. **时间戳第一**: 文件名 HHMMSS 与会议时间表对照
2. **内容验证第二**: 打开 JSON 看关键词、技术术语
3. **会议延伸**: 一个会议可能延伸到下个时段

> 💡 **自定义**: 根据你的常见会议类型，建立自己的关键词特征表，以便快速识别录音归属。
