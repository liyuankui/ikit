# Meeting Recorder - Decisions Log

记录 Meeting Recorder 的重要架构决策和设计变更。

---

## Decision 1: 截屏间隔设置为 3 分钟

**Date**: 2026-02-09
**Status**: Accepted

### Context
- 原截屏 OCR 功能因 CPU 峰值被禁用
- 参会人识别需要从窗口标题提取
- 用户需要平衡 CPU 占用和信息捕获

### Decision
将截屏间隔设置为 **3 分钟** (180秒)

### Rationale
| 选项 | CPU 占用 | 信息密度 | 用户体验 |
|------|----------|----------|----------|
| 1 分钟 | 高 | 高 | 可能卡顿 |
| **3 分钟** | **中** | **中** | **平衡** |
| 5 分钟 | 低 | 低 | 可能遗漏 |

### Alternatives Considered
1. **1 分钟**: 信息捕获最全，但 CPU 峰值风险高
2. **5 分钟**: CPU 占用最低，但可能错过会议关键变化
3. **动态调整**: 根据会议类型自动调整（复杂度高，暂不实现）

### Implementation
- iKit 配置: `screenshot_interval: 180.0`
- 位置: `~/.config/ikit/config.json`

### Impact
- CPU 占用适中
- 能捕获会议进程中的变化
- 平衡了性能和信息密度

---

## Decision 2: 合并脚本使用 Node.js 而非 Swift

**Date**: 2026-02-09
**Status**: Accepted

### Context
- JSON 合并脚本最初用 Swift 编写
- 用户反馈：为何不用 Shell 或 Node.js？

### Decision
**使用 Node.js 重写脚本** (`merge-transcripts.js`)

### Rationale
| 方案 | JSON 处理 | 环境依赖 | 可维护性 |
|------|-----------|----------|----------|
| Swift | 一般 | macOS 原生 | 不常见 |
| **Node.js** | **原生** | **已有** | **主流** |
| Shell + jq | 需 jq | 需安装 jq | 复杂逻辑难写 |

### Alternatives Considered
1. **Swift (原方案)**: macOS 原生，但不是主流脚本语言，JSON 处理不如 JS
2. **Shell + jq**: jq 专为 JSON 设计，但需额外安装，复杂逻辑难写
3. **Python**: 也很好，但用户环境已有 Node.js

### Implementation
- 文件: `scripts/merge-transcripts.js`
- 使用 ES6 modules (`import` 语法)
- 原生 `JSON.parse`，无外部依赖

### Impact
- JSON 处理更自然
- 与用户技术栈一致
- 更易维护和扩展

---

## Template for Future Decisions

### Context
[背景和问题陈述]

### Decision
[决策内容]

### Rationale
[决策理由，包括权衡考虑]

### Alternatives Considered
1. [选项1]
2. [选项2]
3. [选项3]

### Implementation
[实现细节]

### Impact
[影响评估]

---

**Tags**: #meeting-recorder #decisions
