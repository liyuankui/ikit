# Findings: iKit Meet 功能增强 - Phase 1

## 当前实现状态 (2026-01-20)

### 1. Daemon 自动转录 ✅ **已实现**

**发现位置**: `main.swift:1669` - `autoProcessRecordings()`

**当前实现**:
```swift
private func autoProcessRecordings(_ files: [URL], outputDir: String) async {
  // 支持双轨和单轨录制
  // 自动调用 transcribe.py
  // 转录完成后自动触发 LLM 总结
}
```

**触发时机**: 每个切片保存后立即触发 (line 1658-1663)

**处理逻辑**:
- 双轨模式 (2 files): 传递 mic + sys 给 transcribe.py
- 单轨模式 (1 file): 传递单个音频文件
- 自动跳过已转录的文件
- 转录完成后调用 `processSummaryIfNeeded()`

---

### 2. LLM 自动总结 ✅ **已实现**

**发现位置**: `main.swift:1738` - `processSummaryIfNeeded()`

**当前实现**:
- 检测 LiteLLM 服务可用性
- 检测 Ollama 服务可用性
- 使用 SecretaryTool 处理转录结果
- 生成 Markdown 格式总结

**服务检测逻辑**:
```swift
// LiteLLM health check
if let (data, _) = try? await URLSession.shared.data(for: request),
  let response = String(data: data, encoding: .utf8),
  response.contains("I'm alive") {
  llmURL = litellmUrlConfig
}
```

---

### 3. Transcribe 输出格式问题 ⚠️ **需优化**

**当前输出格式** (FunASR 默认):
```json
{
  "key": "20260120-160118_mic",
  "text": "完整转录文本...",
  "timestamp": [[14250, 14390], ...],  // ❌ 1300+ 词级时间戳
  "sentence_info": [
    {
      "text": "...",
      "start": 14250,
      "end": 52770,
      "timestamp": [[...], ...],  // ❌ 与顶层重复
      "spk": 0
    }
  ]
}
```

**问题**:
- `timestamp` 顶层字段包含 **1300+ 词条**，占用大量空间
- `sentence_info[].timestamp` 与顶层 `timestamp` **重复**
- 会议纪要生成只需要句子级信息

**解决方案**:
- 修改 `transcribe.py` 移除词级时间戳
- 新增 `--simple` 标志（默认启用）输出简洁格式
- 保留 `--full` 标志用于需要详细时间戳的场景

---

### 4. OCR 功能 ⚠️ **已禁用**

**代码注释**: "防止 CPU 峰值"

**相关文件**:
- `scripts/transcribe.py:36` - `load_screenshots_metadata()`
- `scripts/transcribe.py:63` - `match_speaker_names_from_ocr()`

**OCR 功能存在但未在 Daemon 中触发**:
- `transcribe.py` 已支持 OCR 名称匹配
- 需要恢复 `screenshots_metadata.json` 生成
- 需要解决 CPU 峰值问题（delta 压缩策略）

---

### 5. Daemon 类结构

**位置**: `main.swift:1344` - `class Daemon`

**关键属性**:
```swift
class Daemon {
  let mic = MicRecorder()
  let sys = SystemRecorder()
  let mode: RecordingMode  // both, micOnly, sysOnly
  let segmentDuration: UInt64  // 可配置切片时长
  private var processedSegments: Set<String>  // 防止重复处理
}
```

**生命周期**:
```
run() → runLoop() → [录制 segmentDuration] → stopRecording()
  → processSegment() → autoProcessRecordings() → processSummaryIfNeeded()
```

**防重复处理**:
```swift
private var processedSegments: Set<String> = []

if self.processedSegments.contains(segmentId) {
  Logger.info("⏭️ Segment already processed, skipping")
  return
}
```

---

### 6. 配置管理

**配置文件位置**: `~/.config/ikit/config.json`

**相关配置项**:
```json
{
  "python_path": "/opt/homebrew/bin/python3",
  "transcribe_script": ".../scripts/transcribe.py",
  "litellm_url": "http://localhost:4000",
  "litellm_api_key": "...",
  "litellm_model": "...",
  "litellm_vision_model": "..."
}
```

---

## 关键发现总结

| 功能 | 状态 | 说明 |
|------|------|------|
| 自动转录 | ✅ **已实现** | `autoProcessRecordings()` |
| 自动 LLM 总结 | ✅ **已实现** | `processSummaryIfNeeded()` |
| 转录输出优化 | ⚠️ **需修改** | 移除词级时间戳 |
| 自动 OCR | ❌ **未启用** | 需恢复 + 优化 CPU |
| 图片筛选 | ❌ **未实现** | 需新增 LLM 调用 |
| 双模型融合 | ❌ **未实现** | 需新增视觉模型调用 |

---

## 代码位置索引

| 功能 | 文件 | 行号 |
|------|------|------|
| Daemon 类 | main.swift | 1344 |
| 自动转录 | main.swift | 1669 |
| LLM 总结 | main.swift | 1738 |
| SecretaryTool | main.swift | 3600 |
| meet 命令处理 | main.swift | 4074 |
| transcribe.py | scripts/ | 全文 |

---

## 下一步行动 (Phase 2)

基于以上发现，原计划需要调整:

**已实现，跳过**:
- ~~Phase 3: Daemon 自动转录~~ (已存在)

**需要调整的 Phase**:
- **Phase 2**: 优化 transcribe.py 输出格式 (移除词级时间戳)
- **Phase 3**: 恢复 OCR 功能 (解决 CPU 峰值)
- **Phase 4**: 实现图片筛选 (新增 LLM 步骤)
- **Phase 5**: 实现双模型融合 (视觉 + 文本)

**新增配置项建议**:
```json
{
  "meet": {
    "auto_transcribe": true,
    "auto_ocr": false,
    "auto_summary": true,
    "transcribe_simple": true,  // 简洁输出模式
    "summary_max_images": 3
  }
}
```
