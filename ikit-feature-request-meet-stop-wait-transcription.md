# iKit Meet: stop 命令等待转录完成

**版本**: v2.7.0+
**日期**: 2026-02-04
**优先级**: 高
**状态**: 新需求

---

## 问题描述

**当前行为**: `ikit meet stop` 只等待录音文件保存，不等待自动转录完成

**影响**:
- 用户停止 daemon 后，转录任务被中断
- 需要手动补充转录未完成的片段
- 自动化流程不完整

---

## 实际案例

```
[17:04:06] ✅ Saved: 20260204-164949_merged.m4a
[17:04:06] 🎤 Auto-transcribing dual-track: 20260204-164949_mic.m4a + ...
[17:04:06] 💔 (stop 命令退出，转录中断)
```

结果：第二个录音片段未转录，需手动运行 `ikit meet transcribe`

---

## 期望行为

```bash
# 停止命令
$ ikit meet stop

[17:04:06] 🛑 Stop signal received, finalizing recording...
[17:04:06] ✅ All recordings saved
[17:04:06] 🎤 Auto-transcribing: 20260204-164949_mic.m4a + 20260204-164949_sys.m4a
[17:04:20] ✅ Transcription complete: 20260204-164949.json
[17:04:21] ✅ Summary generated: 2026-02-04T09:04:21Z-20260204-164949.json.md
[17:04:21] ✅ Daemon stopped - all recordings transcribed
```

**关键变化**: stop 命令阻塞直到所有转录任务完成

---

## 实现方案

### 方案 A: 同步等待（推荐）

```swift
// MeetCommand.swift
func stop() async throws {
    print("🛑 Stop signal received...")

    // 1. 停止录音
    try await recorder.stop()
    print("✅ All recordings saved")

    // 2. 等待待转录队列
    let pendingTranscriptions = transcriber.getPendingTasks()
    if !pendingTranscriptions.isEmpty {
        print("🎤 Transcribing \(pendingTranscriptions.count) segment(s)...")

        for task in pendingTranscriptions {
            _ = try await task.value  // 等待完成
        }
        print("✅ All transcriptions complete")
    }

    // 3. 清理
    try cleanup()
}
```

### 方案 B: 增加标志位

```bash
# 添加 --no-wait 标志跳过等待
$ ikit meet stop --no-wait
```

---

## 配置项

```json
{
  "meet": {
    "stop_wait_transcription": true,   // stop 时等待转录
    "stop_timeout_seconds": 300         // 超时时间（5分钟）
  }
}
```

---

## 用户反馈

**痛点**:
- "会议结束了，stop 之后以为转录完了，结果发现少了一段"
- "每次都要手动检查哪些文件没转录，很麻烦"

**期望**:
- "stop 后确认所有转录都完成"
- "给我一个选项选择是否等待"

---

## 兼容性

- 默认行为：等待转录完成（向后兼容改善）
- 添加 `--no-wait` 标志：快速退出（原有行为）
- 保持所有现有功能不变

---

## 测试场景

1. **正常停止**: 验证转录完成后才退出
2. **长录音**: 验证等待时间合理（5分钟超时）
3. **--no-wait**: 验证快速退出
4. **无待转录任务**: 验证快速退出

---

## 优先级

| 功能 | 优先级 | 复杂度 |
|------|--------|--------|
| stop 等待转录 | 高 | 低 |
| --no-wait 标志 | 中 | 低 |
| 配置项支持 | 中 | 低 |
