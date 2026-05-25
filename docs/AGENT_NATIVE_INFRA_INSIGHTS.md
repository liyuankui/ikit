# Agent-Native Infra 设计启发

> 来源：c4pt0r (TiDB) 《如何做 AI Agent 喜欢的基础软件》
> 分析时间：2026-01-16
> 关联意图：[[intent/active.md#Agentic Engineering Exploration]]

---

## 文章核心观点

**主要趋势**：基础软件的主要使用者正在从人类开发者转向 AI Agent

**三个关键维度**：
1. **心智模型** - 软件应贴合已被 LLM 训练内化的经典模型
2. **接口设计** - 可被自然语言描述、可被符号逻辑固化、可交付确定性结果
3. **Infra 特征** - 日抛型代码、极致低成本、单位时间能撬动的算力

---

## 对 iKit 的启发分析

### 1. 心智模型 ✅ **验证现有设计**

| 文章观点 | iKit 现状 | 评价 |
|---------|----------|------|
| 贴合经典心智模型 | CLI = `ikit [command] [subcommand] [args]` | ✅ 符合 Bash/Unix 传统 |
| 稳定的接口抽象 | `--json` 输出模式 | ✅ 管道友好的结构化数据 |
| 可扩展性 | CQRS 设计（读镜像 + 写命令） | ✅ Notes sync 是典范 |

**结论**：iKit 已经走在正确道路上 —— **CLI + JSON** 正是 Agent 最喜欢的组合。

---

### 2. 接口设计 ⚠️ **可优化方向**

#### 2.1 增加 Agent Discovery API

```bash
# 建议新增：--semantic 模式
ikit note --semantic
# 输出：
{
  "capability": "create_note",
  "description": "Create a new Apple Note in specified folder",
  "parameters": {
    "path": "Local path to notes mirror",
    "folder": "Target folder in Apple Notes",
    "title": "Note title",
    "content": "Note content (markdown supported)"
  },
  "examples": [
    "ikit note new \"~/Notebooks/AppleNotes\" \"Work\" \"Meeting Notes\" \"# Discussion\\n\\n- Point 1\"",
    "ikit note update ... \"\" \"Append new content\""
  ]
}
```

**好处**：让 Agent 能"猜对"意图，减少试错成本。

#### 2.2 Query-First 数据访问

```bash
# 当前：需要先 sync 所有数据
ikit note sync

# 建议：直接查询，按需拉取
ikit note query --filter "folder=Work AND modified>7days" --json
# 返回虚拟视图，不需要物理同步所有数据
```

---

### 3. Infra 特征 🔥 **战略升级方向**

#### 3.1 日抛型代码：支持 Agent 分支探索

文章观点：
> Agent 喜欢并行探索、快速试错、能跑就接受

**iKit 机会**：
```bash
# 假设：Agent 想测试不同的 Note 组织方式
ikit note create-branch "experiment-A"
# ... 在分支中疯狂操作 ...
ikit note discard-branch "experiment-A"  # 一键丢弃
```

**定位**：让 iKit 成为 **"Apple 世界的 Git"** —— Agent 敢于在 Notes/Calendar/Reminders 中快速试错。

---

#### 3.2 极致低成本：虚拟化多租户

文章观点：
> 你不可能为每个 Agent 提供真实物理实例，必须虚拟化

**iKit 现状**：Smart Sync 已经走在正确路上

**进一步方向**：
- 虚拟视图（Virtual Views）—— 不同 Agent 看到不同的数据子集
- Query-First —— 只拉取需要的数据，而非全量同步
- 命名空间隔离 —— Agent A 的实验不影响 Agent B

---

#### 3.3 单位时间撬动的算力：并行调度

文章观点：
> Agent 天然倾向并行探索，系统要让低成本开 1000 个工位

**iKit 机会**：
```bash
# 从"单进程工具"升级为"Agent 编排平台"
ikit photo batch-ocr --parallel 10 \
  --filter "date>2025-01-01" \
  --callback "webhook://agent-123"
```

---

## 三层建议

### Layer 1: 保持不变 ✅
- **CLI + JSON** 架构 —— Agent 最喜欢的心智模型
- **CQRS 设计** —— 读镜像分离，符合 Agent 使用模式
- **Dry-run** —— 给 Agent 试错空间

### Layer 2: 轻量增强 📝
1. **`--semantic` 元数据输出** —— Agent Discovery API
2. **`--query` 过滤能力** —— Query-First 数据访问
3. **`--batch` 并发模式** —— 支持批量操作

### Layer 3: 战略升级 🚀

**重新定位 iKit**：从 "Apple 生态 CLI" 升级为 **"Agent 的 Apple 世界虚拟化层"**

| 当前定位 | 新定位 |
|---------|--------|
| 工具 | 平台 |
| 单用户 | Multi-Agent |
| 物理操作 | 虚拟化 |
| 命令执行 | 编排调度 |

---

## 具体行动

| 优先级 | 任务 | 说明 |
|-------|------|------|
| P0 | 完善 JSON 输出覆盖 | 确保所有命令都有 `--json` 模式 |
| P1 | 增加 `--semantic` 模式 | 让 Agent 能自发现系统能力 |
| P1 | 增加 `--query` 能力 | 支持 Query-First 数据访问 |
| P2 | 增加 `--batch` 并发 | 支持批量并行操作 |
| P3 | 设计虚拟化架构 | Apple World Virtualization |

---

## 关键引述

> "如果你希望设计的是'给 AI Agent 使用的软件'，那你必须尽可能去贴合这些古老、却被一再验证的心智模型。"

> "Agent 不是在等待一个更聪明强大的系统，而是更喜欢一个'它已经懂的系统'然后用比人类娴熟1000倍的效率写胶水代码扩展它。"

> "日抛型代码...能不能开箱即用、能不能随时创建、失败了是不是可以毫无负担地扔掉，这些都比'长期稳定运行'重要得多。"

---

## 相关链接

- 原文：`/tmp/20260116-173214-rtf-_如何做_AI_Agent_喜欢的基础软件-809d1178.md`
- iKit 仓库：`~/Work/iKit`
- 相关意图：`intent/active.md#Agentic Engineering Exploration`

---

**Last Updated**: 2026-01-16
**Version**: 1.0
