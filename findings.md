# Findings & Decisions

## Requirements

### 用户报告的问题
- daemon 使用 `&` 后台运行时，只录了 90 秒就中断（会议时长 27 分钟）
- `--interval=60` 被误解为 60 秒，实际是 60 分钟
- 无法检查 daemon 是否还在运行
- 崩溃后无法追溯原因

### 提案中的核心需求 (来自 ikit-meet-daemon-reliability-proposal.md)

**P0 优先级:**
- 信号处理与优雅退出（防止录音丢失）
- 明确 interval 单位（60s/5m/1h 格式）

**P1 优先级:**
- 真正的 background 模式
- 状态检查命令 (status/stop)

**P2 优先级:**
- 日志文件持久化
- 预检查与错误提示

**P3 优先级:**
- 配置文件支持

## Research Findings

### 当前 daemon 实现 (main.swift)
- 使用 SIGQUIT (Ctrl+\) 作为优雅停止信号
- **已实现** SIGTERM 处理（用于 killall 命令）
- **已实现** SIGINT 忽略（防止 Ctrl+C 终止）
- `--interval=N` 参数，单位是**分钟**
- 输出目录自动按日期创建: `~/recordings/YYYY-MM-DD/`

### 信号处理现状（第 38-53 行）
```swift
func setupSignalHandlers() {
  signal(SIGQUIT) { _ in
    isShuttingDown = true
    print("\n🛑 Shutdown signal received (Ctrl+\\), finishing current work...")
  }
  signal(SIGTERM) { _ in
    isShuttingDown = true
    print("\n🛑 Termination signal received, finishing current work...")
  }
  signal(SIGINT, SIG_IGN)  // 忽略 Ctrl+C
}
```
- ✓ SIGQUIT - 优雅关闭
- ✓ SIGTERM - 优雅关闭
- ✓ SIGINT - 忽略
- ✗ **缺少 SIGHUP 处理**（后台运行时需要）

### Interval 参数现状（第 4497-4526 行）
```swift
// 支持 --interval N 或 --interval=N
// 支持 "5m" 后缀表示分钟
// 默认 15 分钟
var segmentMinutes = 15

// 解析逻辑
if intervalStr.hasSuffix("m") || intervalStr.hasSuffix("M") {
  segmentMinutes = Int(intervalStr.dropLast()) ?? 15
} else {
  segmentMinutes = Int(intervalStr) ?? 15  // 默认单位是分钟！
}
```
- **问题 1**: 默认单位是分钟，用户容易误解为秒
- **问题 2**: 不支持秒（s）和小时（h）单位
- **问题 3**: 没有弃用警告

### 状态管理现状
- 无 PID 文件
- 无状态检查命令
- 无运行日志

## Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Interval 使用单位后缀 (60s/5m/1h) | 明确无歧义，避免用户误解 |
| 使用 nohup + PID 文件实现后台 | 简单可靠，无需 launchd 复杂性 |
| 日志放在录音目录 | 便于问题排查，与录音一起归档 |
| 保持旧 API 兼容 | 向后兼容，平滑迁移 |
| 心跳文件每 10 秒更新 | 快速检测崩溃，低开销 |

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| FunASR transcribe 首次运行卡住 | ✅ 已修复 v2.8.1 - 添加进度提示和日志转发 |
| meet process 输出文件未创建 | ✅ 已修复 v2.8.1 - 添加目录创建和文件验证 |

## Resources

### 相关文件
- `~/Work/iKit/Sources/iKit/main.swift` - 主代码文件（~2400 行）
- `~/Work/iKit/ikit-meet-daemon-reliability-proposal.md` - 可靠性提案
- `~/.config/ikit/meet.pid` - PID 文件位置（待创建）
- `~/.config/ikit/config.json` - 配置文件

### Swift 信号处理
- `SignalSource.trap(signal:)` - Swift 信号捕获
- 需要处理的信号: SIGTERM, SIGINT, SIGHUP, SIGQUIT

### macOS 后台运行
- `nohup` - 简单后台运行
- `launchd` - 更专业但复杂（P2 考虑）

## Visual/Browser Findings

---
*Update this file after every 2 view/browser/search operations*
