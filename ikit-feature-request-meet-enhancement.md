# iKit Meet 功能增强需求

**版本**: v2.6.0+
**日期**: 2026-01-20
**优先级**: 高

---

## 需求概述

增强 `ikit meet daemon` 模式的自动化处理能力，实现从录制到智能会议纪要的全流程自动化。

---

## 需求详情

### 1. Daemon 自动转录 + OCR

**当前行为**: Daemon 仅录制音频，OCR 已禁用（代码注释：防止 CPU 峰值）

**期望行为**:
```bash
ikit meet daemon --interval=1m ~/recordings/today
```

| 功能 | 状态 | 说明 |
|------|------|------|
| 自动切片 | ✅ 已有 | 默认 15 分钟，改为支持 1 分钟 |
| 自动转录 | ❌ 需新增 | 切片完成后自动调用 transcribe |
| 自动 OCR | ❌ 需新增 | 恢复截图 OCR 功能 |
| 并行处理 | ✅ 已有 | 转录和 OCR 可并行 |

**实现建议**:
- 每个切片保存后立即触发 `transcribe(audio)`
- OCR 任务保持异步，使用 delta 压缩减少 CPU
- 增加配置项控制是否启用自动处理

---

### 2. 转录输出精简

**当前 JSON 结构** (实测):
```json
{
  "key": "20260120-160118_mic",
  "text": "完整转录文本...",
  "timestamp": [
    [14250, 14390],   // 词级时间戳 1
    [14390, 14550],   // 词级时间戳 2
    ...               // 约 1300+ 个词条
  ],
  "sentence_info": [
    {
      "text": "我现在对其其，",
      "start": 14250,
      "end": 52770,
      "timestamp": [[14250,14390], ...],  // 词级细分（冗余）
      "spk": 0
    },
    ...
  ]
}
```

**问题分析**:
- `timestamp` 顶层字段：**1300+ 词条**，占用大量空间
- `sentence_info[].timestamp`：与顶层 `timestamp` **重复**
- 会议纪要生成只需句子级信息，不需要词级时间戳

**期望行为**:
```json
{
  "key": "20260120-160118_mic",
  "text": "完整转录文本...",
  "sentences": [
    {
      "text": "我现在对其其，",
      "start": 14250,
      "end": 52770,
      "spk": 0
    }
  ]
}
```

**实现**: 修改 `transcribe.py` 输出格式，移除词级时间戳

---

### 3. LLM 智能会议纪要生成

**当前行为**: `process` 命令的 LLM 总结功能存在问题（幻觉）

**期望流程**:

```
┌─────────────────┐
│  切片完成       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  自动转录       │ → 20260120-160118_mic.json
│  自动 OCR       │ → screenshots_metadata.json
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│  LLM 步骤1: 图片筛选            │
│  - 输入: 转录文本 + OCR结果      │
│  - 输出: 最相关的1-3张图片ID    │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  LLM 步骤2: 多模态理解          │
│  - 图片模型: 分析筛选的图片      │
│  - 文本模型: 总结转录内容        │
│  - 输出: 图文并茂的会议纪要      │
└─────────────────────────────────┘
```

**实现要点**:

1. **图片筛选 Prompt**:
   ```
   根据会议转录内容和OCR识别的截图文字，
   挑选出1-3张与会议主题最相关的截图。

   考虑因素：
   - 屏幕内容是否与讨论话题相关
   - 是否包含关键信息（代码、图表、决策点）
   - 时间戳是否与关键讨论对应

   返回图片文件名列表。
   ```

2. **双模型调用**:
   - 图片用 `litellm_vision_model` (qwen3-vl-30b)
   - 文字用 `litellm_model` (qwen-max)
   - **关键**: 两个模型的输出需要融合

3. **输出格式**:
   ```markdown
   # 会议主题

   ## 讨论要点

   ## 关键截图
   ![相关截图](shot_xxx.jpg)

   ## 决策事项

   ## 行动项
   ```

---

## 配置项建议

```json
{
  "meet": {
    "auto_transcribe": true,
    "auto_ocr": true,
    "auto_summary": true,
    "summary_max_images": 3,
    "transcribe_output": "simple"  // "full" | "simple" (无词级时间戳)
  }
}
```

---

## 伪代码

```swift
// daemon 模式 - 切片完成回调
func onSegmentComplete(micPath: URL, sysPath: URL, screenshots: [Screenshot]) {
    // 1. 保存文件
    saveFiles(micPath, sysPath, screenshots)

    // 2. 触发自动处理
    if config.auto_transcribe {
        Task {
            // 并行转录双轨道
            async let micJson = transcribe(micPath)
            async let sysJson = transcribe(sysPath)

            // 等待转录完成
            let (mic, sys) = await (micJson, sysJson)

            // 3. 触发 LLM 处理
            if config.auto_summary {
                await generateSmartSummary(
                    micJson: mic,
                    sysJson: sys,
                    screenshots: screenshots
                )
            }
        }
    }
}

// 智能会议纪要生成
func generateSmartSummary(micJson: String, sysJson: String, screenshots: [Screenshot]) async {
    // 步骤1: LLM 筛选图片
    let selectedImages = await callLLM(
        prompt: imageSelectionPrompt(transcript, screenshots),
        model: config.textModel
    )

    // 步骤2: 并行调用视觉和文本模型
    async let visualContext = callVisionModel(images: selectedImages)
    async let textSummary = callTextModel(transcript: combineJson(micJson, sysJson))

    let (visual, text) = await (visualContext, textSummary)

    // 步骤3: 融合输出
    let summary = fuseSummary(text: text, visual: visual)

    // 保存
    saveSummary(summary)
}
```

---

## 兼容性

- 保持现有 `transcribe` 和 `process` 命令独立可用
- Daemon 模式添加 `--no-auto` 标志禁用自动处理
- 所有新功能通过配置项可开关

---

## 测试场景

1. **1分钟切片 + 自动处理**: 验证完整流程
2. **长会议 (2小时+)**: 验证内存和性能
3. **无截图会议**: 验证纯音频处理
4. **多语言会议**: 验证转录准确性

---

## 优先级排序

| 需求 | 优先级 | 复杂度 |
|------|--------|--------|
| 移除词级时间戳 | 中 | 低 |
| Daemon 自动转录 | 高 | 中 |
| Daemon 自动 OCR | 中 | 中 |
| 图片筛选 | 高 | 高 |
| 双模型融合 | 高 | 高on |
