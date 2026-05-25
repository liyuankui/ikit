# Task Plan: iKit Meet 功能增强

## Goal
增强 `ikit meet daemon` 实现从录音到智能会议纪要的全流程自动化。

## Current Phase
Phase 1: 需求分析与代码探索

## Phases

### Phase 1: 需求分析与代码探索
- [x] 理解需求文档 (ikit-feature-request-meet-enhancement.md)
- [x] 探索当前 Daemon 实现
- [x] 探索 transcribe.py 输出格式
- [x] 探索 process 命令逻辑
- [x] **Status:** complete

**关键发现**:
- ✅ **Daemon 自动转录已存在** (`autoProcessRecordings()` at line 1669)
- ✅ **LLM 自动总结已存在** (`processSummaryIfNeeded()` at line 1738)
- ⚠️ 转录输出需优化 (移除词级时间戳)
- ⚠️ OCR 功能已禁用 (需恢复)

详见 `findings-meet-enhancement.md`

### Phase 2: 转录输出精简
- [x] 修改 transcribe.py 移除词级时间戳
- [x] 更新输出格式为 `sentences`
- [x] 添加 `--simple` 标志 (默认启用)
- [x] 保留 `--full` 标志用于详细时间戳
- [x] 测试新格式
- [x] **Status:** complete

**实现细节**:
- 新增 `simplify_output()` 函数 (line 747)
- `--simple` 标志默认启用 (简洁模式)
- `--full` 标志保留原格式 (详细时间戳)
- 输出格式: `sentence_info` → `sentences`

### Phase 3: Daemon 自动 OCR
- [x] 恢复 OCR 功能（delta 压缩策略）
- [x] 保存 screenshots_metadata.json
- [x] 添加 `meet.auto_ocr` 配置项
- [x] 解决 CPU 峰值问题 (可配置开关)
- [x] **Status:** complete

**实现细节**:
- Config 添加 `auto_ocr: Bool` 字段
- SystemRecorder 添加 `setAutoOcr()` 方法
- Daemon.run() 读取配置并启用/禁用 OCR
- Delta 压缩已存在 (hash-based deduplication)
- 默认: **禁用** (防止 CPU 峰值)

### Phase 4: 智能会议纪要增强
- [x] 实现 LLM 图片筛选
- [x] 实现双模型调用（视觉 + 文本）
- [x] 融合输出 Markdown 纪要
- [x] 添加配置项 (`summary_max_images`)
- [x] **Status:** complete

**实现细节**:
- `selectRelevantImages()` - LLM 筛选相关图片
- `callLLMWithRetry()` - API 重试逻辑 (最多 2 次)
- `callVisionModel()` / `callTextModel()` - 双模型并行调用
- `fuseSummary()` - 图文融合输出
- 加载 `screenshots_metadata.json` 用于图片筛选

### Phase 6: 集成测试
- [x] 1分钟切片测试
- [x] 长会议测试 (2小时+)
- [x] 无截图会议测试
- [x] **Status:** complete

**测试结果**:
- ✅ 图片筛选: 从 137 张截图中 LLM 筛选出 1 张相关图片
- ✅ 双模型并行: 视觉模型 (LiteLLM) + 文本模型 (Ollama)
- ✅ Markdown 输出: 图文并茂的会议纪要
- ✅ 测试数据: ~/recordings/2026-01-20/

**输出示例**:
```markdown
## 关键截图
![shot_20260120-160949.jpg](shot_20260120-160949.jpg)

---

# 会议纪要：门店下线后订单详情页导航功能讨论

## 1. 会议基本信息
* 会议主题: 门店下线后订单详情页信息展示策略讨论
...

## 2. 关键截图分析
### 图1：订单详情页面展示
...

## 3. 讨论要点
...

## 4. 决策事项与行动项
| 项目 | 决策/行动 | 负责人 | 截止日期 |
...
```

## Key Questions

1. **自动处理触发时机**
   - ✅ 切片保存后立即触发
   - ✅ 如果处理时长 > interval，使用队列；否则不需要队列

2. **OCR CPU 峰值**
   - ✅ 做成可配置项，后面再调整

3. **LLM 调用顺序**
   - ✅ 先筛选图片，再带着图片和文稿找 LLM 处理
   - ✅ API 失败重试 2 次，然后报错给用户，用户修复后可重试

4. **输出格式**
   - ✅ Markdown 会议纪要即可

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| 跳过 Daemon 自动转录实现 | 已存在于 `autoProcessRecordings()` (line 1669) |
| 跳过 LLM 自动总结实现 | 已存在于 `processSummaryIfNeeded()` (line 1738) |
| 切片保存后立即触发 | 快速反馈，不需要额外触发机制 |
| 队列处理仅在超时需要 | 大部分情况处理时间 < interval |
| OCR 功能可配置 | 后续调整，不阻塞 Phase 2 |
| 先筛选图片再 LLM | 减少视觉模型调用，降低成本 |
| LLM API 失败重试 2 次 | 提高容错性，失败后允许用户重试 |
| Markdown 输出格式 | 简洁易读，满足需求 |

## Errors Encountered

| Error | Attempt | Resolution |
|-------|---------|------------|
| - | - | - |
