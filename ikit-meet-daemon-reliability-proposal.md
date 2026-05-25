# iKit Meet Daemon 可靠性设计提案

**版本**: v2.6.0 → v2.7.0
**日期**: 2026-01-22
**问题来源**: 实际使用中发现 daemon 在后台运行时意外中断

---

## 问题复盘

### 实际调用（失败）

```bash
# 用户启动录音
~/.local/bin/ikit meet daemon --mic-only --interval=60 ~/Documents/Meetings/$(date +%Y%m%d) &
# 输出: PID: 60425

# 问题：只录了 90 秒就中断了
# 会议时长: ~27 分钟
# 实际录音: 90 秒
```

### 根本原因分析

1. **后台信号传递问题**
   - 使用 `&` 后台运行时，shell 会话断开会发送 SIGHUP
   - daemon 没有正确处理 SIGHUP/SIGTERM

2. **Interval 参数误导**
   ```bash
   --interval=60   # 实际是 60 分钟，不是 60 秒！
   ```
   用户以为是秒，实际是分钟，导致切片间隔过长

3. **缺少状态管理**
   - 无法检查 daemon 是否还在运行
   - 没有日志文件记录崩溃原因
   - 临时文件路径被清理

---

## 设计改进方案

### 1. 真正的后台 Daemon 模式

#### 当前问题

```bash
# 用户期望的后台运行
ikit meet daemon --mic-only ~/Meetings &

# 实际问题：
# 1. 进程随 shell 退出而终止
# 2. 无法检查运行状态
# 3. 无法优雅停止
```

#### 改进方案

```bash
# 新增真正的 background 模式
ikit meet daemon --mic-only --background ~/Meetings

# 输出:
# ✅ Daemon started (PID: 60425)
# 🔴 Recording to: ~/Meetings/2026-01-22
# ℹ️  Check status: ikit meet status
# ℹ️  Stop recording: ikit meet stop

# 新增状态检查命令
ikit meet status

# 输出:
# ✅ Daemon running (PID: 60425)
# 🔴 Recording since: 2026-01-22 10:46:23
# 📁 Output: ~/Meetings/2026-01-22
# 📊 Segments: 2
# 💾 Last save: 10:48:23 (2m ago)

# 优雅停止命令
ikit meet stop

# 输出:
# ⏸️  Stopping daemon...
# 💾 Finalizing recording...
# ✅ All recordings saved
```

#### 技术实现

```swift
// 使用 launchd 创建真正的后台服务
// 或者使用 nohup + PID 文件管理

struct DaemonController {
    static let pidFile = "~/.config/ikit/meet.pid"

    static func startBackground(mode: RecordMode, output: URL) throws {
        // 1. 检查是否已运行
        if let existing = getRunningPid() {
            print("⚠️  Daemon already running (PID: \(existing))")
            return
        }

        // 2. 使用 nohup 启动
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [
            ikitBinary,
            "meet", "daemon",
            "--mode", mode.rawValue,
            "--foreground",  // daemon 在 nohup 下前台运行
            output.path
        ]

        // 3. 重定向输出
        let logFile = output.deletingLastPathComponent().appendingPathComponent("daemon.log")
        process.standardOutput = try? FileHandle(forWritingTo: logFile)
        process.standardError = try? FileHandle(forWritingTo: logFile)

        try process.run()
        savePid(process.processIdentifier)
    }

    static func stop() throws {
        guard let pid = getRunningPid() else {
            throw DaemonError.notRunning
        }

        // 发送 SIGTERM
        kill(pid, SIGTERM)

        // 等待退出（最多 10 秒）
        for _ in 0..<10 {
            sleep(1)
            if !isPidRunning(pid) {
                break
            }
        }

        // 如果还在运行，强制杀死
        if isPidRunning(pid) {
            kill(pid, SIGKILL)
        }

        removePidFile()
    }
}
```

---

### 2. Interval 参数重构

#### 当前问题

```bash
# 用户期望：每 60 秒保存一个片段
ikit meet daemon --interval=60 ~/Meetings

# 实际行为：每 60 分钟保存一次！
# 问题：单位不明确，用户容易误解
```

#### 改进方案

```bash
# 方案 1: 明确单位后缀
ikit meet daemon --interval=60s ~/Meetings   # 60 秒
ikit meet daemon --interval=5m ~/Meetings    # 5 分钟
ikit meet daemon --interval=1h ~/Meetings    # 1 小时

# 方案 2: 分离参数
ikit meet daemon --segment-interval=60s ~/Meetings
ikit meet daemon --auto-save-interval=5m ~/Meetings

# 方案 3: 友好别名
ikit meet daemon --quick-save ~/Meetings      # 60 秒
ikit meet daemon --normal-save ~/Meetings     # 15 分钟（默认）
ikit meet daemon --long-save ~/Meetings       # 1 小时
```

#### 技术实现

```swift
enum Interval: ExpressibleByArgument {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)

    var inSeconds: Int {
        switch self {
        case .seconds(let s): return s
        case .minutes(let m): return m * 60
        case .hours(let h): return h * 3600
        }
    }

    init?(argument: String) {
        // 解析 "60s", "5m", "1h"
        guard let value = Int(argument.dropLast()) else { return nil }
        let unit = argument.last

        switch unit {
        case "s": self = .seconds(value)
        case "m": self = .minutes(value)
        case "h": self = .hours(value)
        default: return nil
        }
    }
}
```

---

### 3. 信号处理与崩溃恢复

#### 当前问题

```swift
// daemon 收到信号时的行为
// 问题：没有优雅关闭，导致录音丢失
```

#### 改进方案

```swift
// 信号处理
SignalSource.trap(signal: .SIGTERM) { signal in
    log.info("🛑 Termination signal received")

    // 1. 停止录音
    recorder?.stop()

    // 2. 保存当前片段
    if let currentSegment = currentSegment {
        saveSegment(currentSegment)
    }

    // 3. 合并所有片段
    mergeAllSegments()

    // 4. 退出
    exit(0)
}

SignalSource.trap(signal: .SIGHUP) { signal in
    // 忽略 HUP，继续运行
    log.info("📡 SIGHUP ignored, continuing recording")
}

SignalSource.trap(signal: .SIGINT) { signal in
    // Ctrl+C：优雅退出
    log.info("⏸️  User interrupt, finalizing...")
    gracefulShutdown()
}

// 崩溃检测：定期写入心跳文件
let heartbeatFile = outputDir.appendingPathComponent(".heartbeat")
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    try? Date().description.write(to: heartbeatFile, atomically: true, encoding: .utf8)
}
```

---

### 4. 日志与状态持久化

#### 当前问题

- daemon 崩溃后无法追溯原因
- 用户不知道录音是否正常

#### 改进方案

```bash
# 日志文件位置
~/Meetings/2026-01-22/
├── daemon.log           # daemon 运行日志
├── .heartbeat           # 心跳文件（每 10 秒更新）
├── 20260122-104629.m4a  # 录音片段
└── 20260122-104629.json # 转录结果

# 日志格式
[2026-01-22 10:46:23] 🚀 Daemon started (PID: 60425)
[2026-01-22 10:46:23] 🔴 Recording mode: mic-only
[2026-01-22 10:46:23] 📁 Output: ~/Meetings/2026-01-22
[2026-01-22 10:46:23] ⏱️  Segment interval: 60s
[2026-01-22 10:47:23] 💾 Segment saved: 20260122-104723.m4a (60.1s)
[2026-01-22 10:47:23] 🤖 Transcribing: 20260122-104723.m4a
[2026-01-22 10:47:35] ✅ Transcription complete
[2026-01-22 10:48:23] 💾 Segment saved: 20260122-104823.m4a (60.0s)
```

---

### 5. 错误处理与用户提示

#### 当前问题

```bash
# 麦克风权限被拒绝时
# 静默失败，用户不知道
```

#### 改进方案

```bash
# 启动前检查
ikit meet daemon --mic-only ~/Meetings

# 输出详细检查
[INFO] 🔍 Pre-flight checks...
[OK]   ✅ Microphone access granted
[OK]   ✅ Output directory writable
[OK]   ✅ Disk space available (15.2 GB)
[OK]   ✅ FunASR ready
[INFO] 🚀 Starting daemon...

# 错误时明确提示
[ERROR] ❌ Microphone access denied
[HELP]  Grant permission in: System Settings → Privacy → Microphone
[HELP]  Or run: open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

# 权限授予后重试
[INFO] Retry with: ikit meet daemon --mic-only ~/Meetings
```

#### 技术实现

```swift
struct PreFlightChecker {
    static func check() throws {
        // 1. 麦克风权限
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetError.microphoneDenied
        }

        // 2. 输出目录
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MeetError.outputNotWritable
        }

        // 3. 磁盘空间
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: output.path)
        if let freeSize = attributes[.systemFreeSize] as? UInt64,
           freeSize < 1_000_000_000 {  // 1GB
            throw MeetError.lowDiskSpace
        }

        // 4. FunASR 可用性
        guard FileManager.default.fileExists(atPath: funasrPath) else {
            throw MeetError.funasrNotAvailable
        }
    }
}
```

---

## 配置文件支持

```json
// ~/.config/ikit/config.json
{
  "meet": {
    "default_mode": "mic-only",
    "segment_interval": "60s",
    "auto_transcribe": true,
    "auto_ocr": true,
    "log_level": "info",
    "output_dir": "~/Meetings",
    "keep_temp_files": false
  }
}
```

使用配置文件：

```bash
# 使用默认配置
ikit meet daemon

# 覆盖部分配置
ikit meet daemon --system-only --interval=5m
```

---

## 命令行 API 重构

### 当前 API

```bash
ikit meet daemon [--mic-only|--system-only] [--interval=N] <outDir>
ikit meet transcribe <audio>
ikit meet process <json/txt...> <outDir>
```

### 新 API

```bash
# 启动（改进）
ikit meet daemon [options] <outDir>
  Options:
    --mode {mic|system|dual}      # 录音模式
    --interval <duration>          # 片段间隔 (60s, 5m, 1h)
    --background                   # 后台运行
    --auto-transcribe              # 自动转录
    --no-auto                      # 禁用自动处理

# 状态管理（新增）
ikit meet status                   # 查看状态
ikit meet stop                     # 停止 daemon
ikit meet logs                     # 查看日志
ikit meet list                     # 列出所有会话

# 转录（保持）
ikit meet transcribe <audio>       # 转录单个文件
ikit meet transcribe --batch <dir> # 批量转录

# 处理（保持）
ikit meet process <input> <output> # 生成会议纪要
```

---

## 实现优先级

| 优先级 | 功能 | 复杂度 | 影响 |
|--------|------|--------|------|
| P0 | 信号处理与优雅退出 | 中 | 防止录音丢失 |
| P0 | 明确 interval 单位 | 低 | 避免用户误解 |
| P1 | 真正的 background 模式 | 高 | 稳定后台运行 |
| P1 | 状态检查命令 (status/stop) | 中 | 用户体验 |
| P2 | 日志文件持久化 | 低 | 问题排查 |
| P2 | 预检查与错误提示 | 低 | 友好提示 |
| P3 | 配置文件支持 | 中 | 高级用户 |

---

## 测试计划

### 单元测试

```swift
func testIntervalParsing() {
    XCTAssertEqual(Interval(argument: "60s")?.inSeconds, 60)
    XCTAssertEqual(Interval(argument: "5m")?.inSeconds, 300)
    XCTAssertEqual(Interval(argument: "1h")?.inSeconds, 3600)
}

func testSignalHandling() {
    // 模拟 SIGTERM，验证文件正确保存
}
```

### 集成测试

```bash
# 测试 1: 后台运行 5 分钟
ikit meet daemon --background --interval=60s /tmp/test
sleep 300
ikit meet status   # 应该显示 5 个片段
ikit meet stop

# 测试 2: 崩溃恢复
# 启动 daemon，kill -9，检查心跳文件检测崩溃

# 测试 3: 优雅退出
# 启动 daemon，SIGTERM，验证文件正确合并
```

---

## 向后兼容

- 保持旧 API 继续工作
- 添加弃用警告
```bash
# 旧 API（仍然可用）
ikit meet daemon --mic-only --interval=60 ~/Meetings

# 输出警告
[WARN]  ⚠️  --interval=N (minutes) is deprecated
[WARN]  Use --interval=<duration> instead (e.g., --interval=60s)
[WARN]  This will be removed in v3.0.0
```

---

## 总结

本提案解决的核心问题：

1. **可靠性**: daemon 不再意外中断
2. **易用性**: 明确的参数和友好的错误提示
3. **可观测性**: 状态检查和日志记录
4. **向后兼容**: 保持现有 API 继续工作

**目标**: 让 `ikit meet daemon` 成为可信赖的生产级会议录音工具。
