import AVFoundation
import AudioToolbox
import Cocoa
import Contacts
import Darwin
import EventKit
import Foundation
// import HealthKit  // Removed: causes Signal 9 in CLI without App Bundle (issue #17)
import IOKit
import Photos
import ScreenCaptureKit
// import Speech  // Removed: unused in CLI context, was only used by deleted speech_recorder.swift
import SwiftEdgeTTS
import Vision

// MARK: - IOKit Power Management Declarations
typealias IOPMAssertionID = UInt32
typealias IOPMAssertionLevel = UInt32

let kIOPMAssertionTypePreventUserIdleSystemSleep: CFString =
  "PreventUserIdleSystemSleep" as CFString
let kIOPMAssertionLevelOn: IOPMAssertionLevel = 255
let kIOPMAssertionLevelOff: IOPMAssertionLevel = 0

@_silgen_name("IOPMAssertionCreateWithName")
func IOPMAssertionCreateWithName(
  _ AssertionType: CFString,
  _ AssertionName: CFString,
  _ AssertionLevel: IOPMAssertionLevel,
  _ AssertionID: UnsafeMutablePointer<IOPMAssertionID>
) -> IOReturn

@_silgen_name("IOPMAssertionRelease")
func IOPMAssertionRelease(_ AssertionID: IOPMAssertionID) -> IOReturn

// MARK: - Global Signal Handling
/// Global flag for graceful shutdown (non-isolated)
nonisolated(unsafe) var isShuttingDown = false

// MARK: - Transcription Process Manager
/// Manages transcription child processes to ensure they are terminated when daemon stops
class TranscriptionManager {
  static let shared = TranscriptionManager()
  private var activeProcesses: [Int32: Process] = [:]
  private let lock = NSLock()
  private let maxTranscriptionTime: TimeInterval = 3600  // 1 hour timeout

  private init() {}

  /// Run a transcription process with tracking and timeout
  func runTranscription(
    executable: String, args: [String], outputPipe: Pipe, errorPipe: Pipe
  ) -> (output: String?, error: String?, exitCode: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    do {
      try task.run()

      // Track the process
      let pid = task.processIdentifier
      lock.lock()
      activeProcesses[pid] = task
      lock.unlock()

      Logger.info("🎤 Started transcription process (PID: \(pid))")

      // Setup timeout monitoring
      let timeoutWork = DispatchWorkItem { [weak self] in
        if task.isRunning {
          Logger.warn("⏰ Transcription timeout (1h), terminating PID: \(pid)")
          task.terminate()
          self?.removeProcess(pid)
        }
      }
      DispatchQueue.global().asyncAfter(
        deadline: .now() + maxTranscriptionTime, execute: timeoutWork)

      // Wait for completion
      task.waitUntilExit()

      // Remove from tracking
      removeProcess(pid)

      // Cancel timeout work if still pending
      timeoutWork.cancel()

      let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      return (
        String(data: outData, encoding: .utf8),
        String(data: errData, encoding: .utf8),
        task.terminationStatus
      )
    } catch {
      return (nil, "Failed to start transcription: \(error)", -1)
    }
  }

  private func removeProcess(_ pid: Int32) {
    lock.lock()
    activeProcesses.removeValue(forKey: pid)
    lock.unlock()
  }

  /// Wait for all active transcription processes to complete (with timeout)
  /// Returns true if all completed within timeout, false if some are still running
  func waitForCompletion(timeout: TimeInterval = 300) async -> Bool {
    let startTime = Date()
    let checkInterval: TimeInterval = 1.0

    while Date().timeIntervalSince(startTime) < timeout {
      lock.lock()
      let count = activeProcesses.count
      lock.unlock()

      if count == 0 {
        Logger.info("✅ All transcriptions completed")
        return true
      }

      // Check if any processes are still running
      var runningCount = 0
      lock.lock()
      for (_, process) in activeProcesses {
        if process.isRunning {
          runningCount += 1
        }
      }
      lock.unlock()

      if runningCount == 0 {
        Logger.info("✅ All transcriptions completed (processes finished, cleaning up...)")
        // Clean up stale entries
        lock.lock()
        let pids = Array(activeProcesses.keys)
        for pid in pids {
          activeProcesses.removeValue(forKey: pid)
        }
        lock.unlock()
        return true
      }

      Logger.debug("⏳ Waiting for \(runningCount) transcription(s) to complete...")

      try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
    }

    // Timeout reached
    lock.lock()
    let remainingCount = activeProcesses.count
    lock.unlock()

    Logger.warn(
      "⚠️  Timeout waiting for transcriptions (\(Int(timeout))s), \(remainingCount) still active")
    return false
  }

  /// Terminate all active transcription processes (called on daemon shutdown)
  func terminateAllChildren() {
    lock.lock()
    let processes = activeProcesses
    lock.unlock()

    guard !processes.isEmpty else {
      Logger.info("✅ No active transcription processes to terminate")
      return
    }

    Logger.info("🛑 Terminating \(processes.count) transcription process(es)...")

    // Send SIGTERM first
    for (pid, process) in processes {
      if process.isRunning {
        Logger.info("   Sending SIGTERM to PID: \(pid)")
        process.terminate()
      }
    }

    // Wait up to 10 seconds for graceful termination
    Thread.sleep(forTimeInterval: 5)

    // Force kill any remaining processes
    lock.lock()
    for (pid, process) in activeProcesses {
      if process.isRunning {
        Logger.warn("   Force killing PID: \(pid)")
        kill(pid, SIGKILL)
        activeProcesses.removeValue(forKey: pid)
      }
    }
    lock.unlock()

    Logger.info("✅ All transcription processes terminated")
  }

  /// Get count of active transcription processes
  func activeProcessCount() -> Int {
    lock.lock()
    let count = activeProcesses.count
    lock.unlock()
    return count
  }
}

/// Setup signal handlers for graceful shutdown
func setupSignalHandlers() {
  // SIGQUIT (Ctrl+\) is more reliable than SIGINT (Ctrl+C) for graceful shutdown
  signal(SIGQUIT) { _ in
    isShuttingDown = true
    print("\n🛑 Shutdown signal received (Ctrl+\\), finishing current work...")
    // Terminate child transcription processes
    TranscriptionManager.shared.terminateAllChildren()
    fflush(stdout)
  }
  // Also handle SIGTERM for `killall -TERM ikit` or system shutdown
  signal(SIGTERM) { _ in
    isShuttingDown = true
    print("\n🛑 Termination signal received, finishing current work...")
    // Terminate child transcription processes
    TranscriptionManager.shared.terminateAllChildren()
    fflush(stdout)
  }
  // Ignore SIGHUP to keep daemon running when shell session ends
  signal(SIGHUP, SIG_IGN)
  // Ignore SIGINT (Ctrl+C) to prevent immediate termination
  signal(SIGINT, SIG_IGN)
}

// MARK: - Logger
struct Logger {
  static var verbose = false
  private static var logFile: FileHandle?

  /// 初始化日志文件（在指定目录）
  static func setupLogging(outputDir: String? = nil) {
    // 生成带日期的日志文件名
    let logFileName = "ikit-\(beijingDate()).log"

    // 确定日志文件位置
    let logPath: String
    if let dir = outputDir {
      logPath = URL(fileURLWithPath: dir).appendingPathComponent(logFileName).path
    } else {
      // 默认位置 ~/recordings/ikit-YYYY-MM-DD.log
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      logPath = URL(fileURLWithPath: home + "/recordings").appendingPathComponent(logFileName).path
    }

    // 确保目录存在
    let logDir = URL(fileURLWithPath: logPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

    // 打开日志文件
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
      logFile = handle
      handle.seekToEndOfFile()
    } else if let handle = FileHandle(forWritingAtPath: logPath) {
      logFile = handle
      handle.seekToEndOfFile()
    } else {
      // 创建新文件
      FileManager.default.createFile(atPath: logPath, contents: nil)
      if let handle = FileHandle(forWritingAtPath: logPath) {
        logFile = handle
      }
    }
  }

  /// 写入日志到文件和终端
  private static func log(_ msg: String, level: String = "") {
    let timestamp = beijingDateTime()
    let logMessage = "[\(timestamp)] \(level)\(msg)"

    // 输出到终端
    fputs(logMessage + "\n", stderr)
    fflush(stderr)

    // 输出到文件
    if let file = logFile {
      if let data = (logMessage + "\n").data(using: .utf8) {
        file.write(data)
      }
    }
  }

  static func debug(_ msg: String) {
    if verbose {
      log("🔍 [DEBUG] \(msg)")
    }
  }

  static func error(_ msg: String, exitCode: Int32 = 1) {
    log("❌ [ERROR] \(msg)")
    exit(exitCode)
  }

  static func warn(_ msg: String) { log("⚠️ [WARN] \(msg)") }

  static func info(_ msg: String) { log(msg) }

  /// 关闭日志文件
  static func closeLogging() {
    logFile?.closeFile()
    logFile = nil
  }
}

// MARK: - Timezone Helper
/// 生成 UTC+8（北京时间）格式的文件名时间戳
/// 格式：YYYYMMDD-HHmmss（例如：20250114-160845）
func beijingTimestamp() -> String {
  let formatter = DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)  // UTC+8
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  return formatter.string(from: Date())
}

/// 生成 UTC+8 格式的 ISO 8601 时间戳
/// 格式：YYYY-MM-DD HH:mm:ss（例如：2025-01-14 16:08:45）
func beijingDateTime() -> String {
  let formatter = DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)  // UTC+8
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return formatter.string(from: Date())
}

/// 生成 UTC+8 格式的日期（用于 daily 文件夹）
/// 格式：YYYY-MM-DD（例如：2025-01-16）
func beijingDate() -> String {
  let formatter = DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)  // UTC+8
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter.string(from: Date())
}

// MARK: - IKit Directory
/// iKit 目录管理类 - 统一管理 ~/.ikit/ 目录结构
class IKitDir {
  static let root = FileManager.default.homeDirectoryForCurrentUser.path + "/.ikit"

  // 子目录
  static let timer = root + "/timer"
  static let timerActive = timer + "/active"
  static let meet = root + "/meet"
  static let meetSessions = meet + "/sessions"
  static let note = root + "/note"
  static let noteCache = note + "/cache"
  static let claude = root + "/claude"
  static let logs = root + "/logs"
  static let logsTimer = logs + "/timer"
  static let config = root + "/config"
  static let run = root + "/run"

  /// 创建目录结构
  static func setup() {
    let dirs = [
      root,
      timer, timerActive,
      meet, meetSessions,
      note, noteCache,
      claude,
      logs, logsTimer,
      config,
      run,
    ]

    for dir in dirs {
      try? FileManager.default.createDirectory(
        atPath: dir,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    Logger.info("✅ iKit 目录已创建: \(root)")
    print("  ├─ timer/")
    print("  ├─ meet/")
    print("  ├─ note/")
    print("  ├─ claude/")
    print("  ├─ logs/")
    print("  ├─ config/")
    print("  └─ run/")

    // 检查模型缓存
    let (modelscope, hf) = checkModelCache()
    print("")
    print("💾 ASR 模型缓存状态:")
    if modelscope.exists {
      print("   ✅ ModelScope: \(modelscope.size) (FunASR - 中文)")
    } else {
      print("   ⏳ ModelScope: 未缓存 (首次 transcribe 时自动下载)")
    }
    if hf.exists {
      print("   ✅ HuggingFace: \(hf.size) (Whisper, MLX, pyannote - 英文)")
    } else {
      print("   ⏳ HuggingFace: 未缓存 (首次 transcribe 时自动下载)")
    }
    if !modelscope.exists || !hf.exists {
      print("   💡 提示: 运行 ikit meet transcribe 时会自动下载 ASR 模型 (~12GB)")
    }
  }

  /// 路径方法
  static func sessionResumeFile() -> String { return run + "/session-resume.txt" }
  static func timerConfig(_ name: String) -> String { return timerActive + "/\(name).json" }
  static func timerLog(_ name: String) -> String { return timerActive + "/\(name).log" }
  static func timerHistory() -> String { return timer + "/history.json" }
  static func meetSession(_ id: String) -> String { return meetSessions + "/\(id)" }
  static func mainLog() -> String { return logs + "/ikit.log" }
  static func configFile() -> String { return config + "/config.json" }

  /// 检查模型缓存状态
  static func checkModelCache() -> (
    modelscope: (size: String, exists: Bool), huggingface: (size: String, exists: Bool)
  ) {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path

    // 检查 ModelScope
    let modelscopeDir = home + "/.cache/modelscope"
    let modelscopeExists = fm.fileExists(atPath: modelscopeDir)
    let modelscopeSize = modelscopeExists ? getDirectorySize(path: modelscopeDir) : "0B"

    // 检查 HuggingFace
    let hfDir = home + "/.cache/huggingface/hub"
    let hfExists = fm.fileExists(atPath: hfDir)
    let hfSize = hfExists ? getDirectorySize(path: hfDir) : "0B"

    return (
      (modelscopeSize, modelscopeExists),
      (hfSize, hfExists)
    )
  }

  /// 获取目录大小
  private static func getDirectorySize(path: String) -> String {
    var totalSize: UInt64 = 0
    let fm = FileManager.default

    if let enumerator = fm.enumerator(
      at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey])
    {
      for case let url as URL in enumerator {
        if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let fileSize = resourceValues.fileSize
        {
          totalSize += UInt64(fileSize)
        }
      }
    }

    // 转换为可读格式
    if totalSize < 1024 {
      return "\(totalSize)B"
    } else if totalSize < 1024 * 1024 {
      return "\(totalSize / 1024)KB"
    } else if totalSize < 1024 * 1024 * 1024 {
      return String(format: "%.1fMB", Double(totalSize) / (1024 * 1024))
    } else {
      return String(format: "%.2fGB", Double(totalSize) / (1024 * 1024 * 1024))
    }
  }
}

// MARK: - Config
struct MeetConfig: Codable {
  var default_interval: String?  // e.g., "15m", "1h"
  var default_mode: String?  // "both", "mic-only", "system-only"
  var auto_transcribe: Bool?  // Whether to auto-transcribe segments
  var auto_summary: Bool?  // Whether to auto-generate meeting summary (default: true)
  var transcribe_engine: String?  // "ollama" | "litellm" (default: "ollama")
}

struct Config: Codable {
  var notes_root: String?
  var python_path: String?
  var transcribe_script: String?
  var ollama_url: String?
  var ollama_model: String?
  var litellm_url: String?
  var litellm_api_key: String?
  var litellm_model: String?
  var litellm_vision_model: String?
  var screenshot_interval: Double?
  var auto_ocr: Bool?
  var summary_max_images: Int?
  var meet: MeetConfig?  // Meet daemon configuration
}

class ConfigManager {
  static let shared = ConfigManager()
  var current: Config

  private init() {
    self.current = Config(
      notes_root: nil,
      python_path: nil,
      transcribe_script: nil,
      ollama_url: "http://localhost:11434/api/generate",
      ollama_model: "qwen2.5:14b",
      litellm_url: "http://localhost:4444/v1/completions",
      litellm_api_key: nil,
      litellm_model: "qwen-max",
      litellm_vision_model: "qwen3-vl-30b",
      screenshot_interval: 10.0,
      auto_ocr: false,  // Default: disabled to prevent CPU spikes
      summary_max_images: 3,  // Default: max 3 images for summary
      meet: MeetConfig(
        default_interval: "15m",
        default_mode: "both",
        auto_transcribe: true,
        auto_summary: true,
        transcribe_engine: "ollama"
      )
    )
    load()
  }

  func load() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let path = home.appendingPathComponent(".config/ikit/config.json")
    if let data = try? Data(contentsOf: path),
      let decoded = try? JSONDecoder().decode(Config.self, from: data)
    {
      self.current = decoded
    }
  }

  func save() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".config/ikit")
    let path = dir.appendingPathComponent("config.json")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(self.current) {
      try? data.write(to: path)
      Logger.info("💾 Config saved to \(path.path)")
    }
  }

  // MARK: - Meet Configuration Helpers
  func getMeetDefaultInterval() -> String {
    return current.meet?.default_interval ?? "15m"
  }

  func getMeetDefaultMode() -> String {
    return current.meet?.default_mode ?? "both"
  }

  func getMeetAutoTranscribe() -> Bool {
    return current.meet?.auto_transcribe ?? true
  }

  func getMeetAutoSummary() -> Bool {
    return current.meet?.auto_summary ?? true
  }

  func getMeetTranscribeEngine() -> String {
    return current.meet?.transcribe_engine ?? "ollama"
  }
}

// MARK: - Recorder Module
class MicRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let session = AVCaptureSession()
  private let output = AVCaptureMovieFileOutput()
  private var audioEngine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var mixerNode: AVAudioMixerNode?
  private var aecEnabled = false

  func start(outputURL: URL) {
    // Check if AEC should be enabled
    aecEnabled = shouldEnableAEC()

    if aecEnabled {
      startWithAEC(outputURL: outputURL)
    } else {
      startSimple(outputURL: outputURL)
    }
  }

  private func shouldEnableAEC() -> Bool {
    // Enable AEC if recording in "both" mode and using speakers
    // This is checked from the daemon's mode
    // For now, we'll use a simple heuristic
    var deviceAddress: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize,
        &deviceAddress) == noErr
    else {
      Logger.debug("AEC: Could not get default output device")
      return false
    }

    var name: CFString = "" as CFString
    propertySize = UInt32(MemoryLayout<CFString>.size)
    propertyAddress.mSelector = kAudioObjectPropertyName
    if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name)
      == noErr
    {
      let deviceName = name as String
      let isBuiltInSpeaker =
        deviceName.localizedCaseInsensitiveContains("built-in")
        || deviceName.localizedCaseInsensitiveContains("内建")
        || deviceName.localizedCaseInsensitiveContains("扬声器")
        || deviceName.localizedCaseInsensitiveContains("MacBook Pro")
        || (deviceName.localizedCaseInsensitiveContains("MacBook")
          && deviceName.localizedCaseInsensitiveContains("Speakers"))

      if isBuiltInSpeaker {
        Logger.info("🔊 AEC: Built-in speaker detected, enabling echo cancellation")
        Logger.info("   Output device: \(deviceName)")
      } else {
        Logger.debug("AEC: External audio output detected, AEC disabled")
        Logger.debug("   Output device: \(deviceName)")
      }

      return isBuiltInSpeaker
    }
    return false
  }

  private func startWithAEC(outputURL: URL) {
    Logger.info("🎙️ MicRecorder: AEC enabled for echo cancellation")
    Logger.info("🔊 Using VoiceProcessing mode with AVAudioEngine")
    audioEngine = AVAudioEngine()
    guard let engine = audioEngine else { return }

    // Get the built-in microphone input
    let inputNode = engine.inputNode

    // Use the input node's actual format to avoid format mismatch
    // AVAudioEngine will apply system voice processing automatically
    let inputFormat = inputNode.outputFormat(forBus: 0)
    Logger.debug("Input format: \(inputFormat)")

    // Create a mixer for Voice Processing
    let mixer = AVAudioMixerNode()
    mixerNode = mixer
    engine.attach(mixer)

    // Connect input to mixer using input's native format
    // This ensures format compatibility while still getting voice processing benefits
    engine.connect(inputNode, to: mixer, format: inputFormat)

    Logger.info("✅ Configured voice processing I/O (AEC enabled)")

    // Create audio file for writing with optimized settings
    // Force 48kHz output to ensure compatibility across all input devices
    let outputSampleRate = 48000.0
    guard
      let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      Logger.error("Failed to create recording format")
      return
    }

    do {
      audioFile = try AVAudioFile(
        forWriting: outputURL,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: outputSampleRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 64000,
        ])
    } catch {
      Logger.error("Failed to create audio file: \(error)")
      return
    }

    // Install tap to record audio
    // Use larger buffer for stability
    // Note: mixer output will be converted to outputSampleRate (48kHz)
    mixer.installTap(onBus: 0, bufferSize: 8192, format: fileFormat) { [weak self] buffer, time in
      guard let self = self, let file = self.audioFile else { return }
      do {
        try file.write(from: buffer)
      } catch {
        Logger.debug("Error writing audio buffer: \(error)")
      }
    }

    // Start the engine
    do {
      try engine.start()
      Logger.info("✅ MicRecorder: Recording with AEC started")
      Logger.info("   Input sample rate: \(inputFormat.sampleRate) Hz")
      Logger.info("   Output sample rate: \(outputSampleRate) Hz")
      Logger.info("   Bit rate: 64kbps (speech optimized)")
      Logger.info("   AEC: Enabled (Voice Processing mode)")
    } catch {
      Logger.error("Failed to start audio engine: \(error)")
    }
  }

  private func startSimple(outputURL: URL) {
    // Use AVAudioEngine for consistent bitrate control
    // This ensures we always use the 32kbps setting even without AEC
    Logger.info("🎙️ MicRecorder: Starting recording (AEC disabled)")
    Logger.info("🔊 Using standard mode with AVAudioEngine")
    audioEngine = AVAudioEngine()
    guard let engine = audioEngine else { return }

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    Logger.debug("Input format: \(inputFormat)")
    Logger.info("   Channels: \(inputFormat.channelCount), Sample rate: \(inputFormat.sampleRate)")

    // Create file for recording
    // Force 48kHz output to ensure compatibility across all input devices
    // AVAudioFile will automatically convert from input sample rate if needed
    let outputSampleRate = 48000.0
    do {
      audioFile = try AVAudioFile(
        forWriting: outputURL,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: outputSampleRate,
          AVNumberOfChannelsKey: inputFormat.channelCount,
          AVEncoderBitRateKey: 64000,
        ])
    } catch {
      Logger.error("Failed to create audio file: \(error)")
      return
    }

    // Install tap directly on input node with its native format
    // AVAudioFile will handle sample rate conversion automatically
    inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) {
      [weak self] buffer, time in
      guard let self = self, let file = self.audioFile else { return }
      do {
        try file.write(from: buffer)
      } catch {
        Logger.debug("Error writing audio buffer: \(error)")
      }
    }

    do {
      try engine.start()
      Logger.info("✅ MicRecorder: Recording started (no AEC)")
      Logger.info("   Input sample rate: \(inputFormat.sampleRate) Hz")
      Logger.info("   Output sample rate: \(outputSampleRate) Hz")
      Logger.info("   Channels: \(inputFormat.channelCount)")
      Logger.info("   Bit rate: 64kbps (speech optimized)")
      Logger.info("   AEC: Disabled (external audio output)")
    } catch {
      Logger.error("Failed to start audio engine: \(error)")
    }
  }

  func stop() {
    if let engine = audioEngine {
      // Remove tap from input node (used by startSimple)
      engine.inputNode.removeTap(onBus: 0)
      Logger.info("🎙️ MicRecorder: Audio tap removed from input node")

      // Remove tap from mixer if used (used by startWithAEC)
      if let mixer = mixerNode {
        mixer.removeTap(onBus: 0)
        Logger.info("🎙️ MicRecorder: Audio tap removed from mixer")
      }

      // Then stop the engine
      engine.stop()
      Logger.info("🎙️ MicRecorder: Audio engine stopped")

      // Give a moment for file to finalize
      Thread.sleep(forTimeInterval: 0.1)

      // Release resources
      audioEngine = nil
      audioFile = nil
      mixerNode = nil
      Logger.info("🎙️ MicRecorder: Resources released")
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    if let err = error { Logger.debug("Mic recording finished with info: \(err)") }
  }
}

// MARK: - Screenshot Metadata
struct ScreenshotMetadata: Codable {
  let timestamp: Int
  let path: String
  var ocrText: String
  var ocrDelta: String  // Incremental text (new since last screenshot)
  var ocrHash: String  // Perceptual hash for deduplication
  var names: [String]
}

@available(macOS 13.0, *)
class SystemRecorder: NSObject, SCStreamOutput {
  private var stream: SCStream?
  private var assetWriter: AVAssetWriter?
  private var audioInput: AVAssetWriterInput?
  private var startTime: CMTime?
  private var recordingStartTime: Date?
  private var lastScreenshotTime = Date()
  private var lastScreenshotHash: String = ""  // For delta OCR
  private var lastOcrText: String = ""  // Previous OCR text for delta
  private var outputDir: String = ""
  private var audioSampleCount = 0
  private var screenFrameCount = 0
  private var screenshots: [ScreenshotMetadata] = []
  private var ocrTasks: [Task<Void, Never>] = []
  private var autoOcr: Bool = false  // OCR enabled/disabled via config

  // Calling app keywords for window filtering
  private let callingAppKeywords = [
    "Microsoft Teams", "Teams",
    "Zoom",
    "Google Meet", "Meet",
    "WebEx",
    "Skype",
    "FaceTime",
    "Discord",
    "Slack",
    "Lark",
    "钉钉",
    "腾讯会议",
    "飞书",
  ]

  /// Enable or disable automatic OCR during recording
  func setAutoOcr(_ enabled: Bool) {
    self.autoOcr = enabled
    if enabled {
      Logger.info("📸 Auto-OCR: ENABLED (screenshots + OCR during recording)")
    } else {
      Logger.info("📸 Auto-OCR: DISABLED (screenshots disabled)")
    }
  }

  func start(outputURL: URL) async throws {
    // Reset state for new recording session
    self.audioSampleCount = 0
    self.screenFrameCount = 0
    self.startTime = nil
    self.recordingStartTime = nil
    self.outputDir = outputURL.deletingLastPathComponent().path
    self.lastScreenshotHash = ""
    self.lastOcrText = ""
    Logger.info("🎬 SystemRecorder: Starting...")

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    Logger.info("🎬 SystemRecorder: Got shareable content")
    guard let display = content.displays.first else { return }

    // Detect calling app windows
    let callingWindows = content.windows.filter { window in
      let appName = window.owningApplication?.applicationName ?? ""
      return callingAppKeywords.contains { appName.contains($0) }
    }

    if !callingWindows.isEmpty {
      Logger.info("📞 Detected \(callingWindows.count) calling app window(s):")
      for window in callingWindows {
        let title = window.title ?? "<no title>"
        let appName = window.owningApplication?.applicationName ?? "<unknown>"
        Logger.info("   - \(appName): \(title)")
      }
    } else {
      Logger.warn("⚠️  No calling app windows detected, capturing full screen")
      let keywords = callingAppKeywords.prefix(5).joined(separator: ", ")
      Logger.info("   Looking for: \(keywords)...")
    }

    // 智能捕获模式：检测到 calling app 时只捕获该应用，否则全屏
    let filter: SCContentFilter
    if !callingWindows.isEmpty {
      // 获取 calling app 的应用对象
      let callingApps = Set(callingWindows.compactMap { $0.owningApplication })

      // 创建只包含 calling app 的 filter
      // 注意：macOS 14+ 可以直接指定要包含的应用
      if #available(macOS 14.0, *) {
        // 使用新的 API 只捕获特定应用
        let otherApps = content.applications.filter { app in
          !callingApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier })
        }
        filter = SCContentFilter(
          display: display, excludingApplications: otherApps, exceptingWindows: [])
        Logger.info("🎬 SystemRecorder: Using APP-SPECIFIC capture (only calling app audio)")
      } else {
        // macOS 13 回退到全屏
        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        Logger.warn("⚠️  macOS 13 detected, falling back to FULL SCREEN capture")
      }
    } else {
      // 没有检测到 calling app，使用全屏捕获
      filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      Logger.info("🎬 SystemRecorder: Using FULL SCREEN capture (all apps audio included)")
    }

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = false  // Jeff: 改为 false 进行测试
    config.width = 1920
    config.height = 1080
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    // Note: Screen capture is enabled by adding .screen stream output

    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 2,
      AVSampleRateKey: 48000,
      AVEncoderBitRateKey: 128000,
    ]
    audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    audioInput?.expectsMediaDataInRealTime = true
    if let input = audioInput, assetWriter?.canAdd(input) == true {
      assetWriter?.add(input)
      Logger.info("🎬 SystemRecorder: Audio input added to writer")
    } else {
      Logger.warn("⚠️  Failed to add audio input to writer")
    }

    assetWriter?.startWriting()
    // ⭐ 修复：立即启动 session，不等待首个样本
    assetWriter?.startSession(atSourceTime: .zero)
    Logger.info("🎬 SystemRecorder: AssetWriter started")
    Logger.info("🎬 SystemRecorder: Session started at kCMTimeZero")

    stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
    try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
    Logger.info("🎬 SystemRecorder: Stream outputs added")

    try await stream?.startCapture()
    Logger.info("✅ SystemRecorder: Capture started successfully")

    // Issue #18: Detect silent permission failure
    // If no audio samples arrive within 5 seconds, Screen Recording permission is likely missing
    Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
      if self.audioSampleCount == 0 {
        Logger.error("❌ Screen Recording 权限未授予，系统音频无法录制")
        Logger.error("   5 秒内未收到任何音频样本")
        Logger.error("   请前往: System Settings → Privacy & Security → Screen Recording → 授权当前应用")
        Logger.error("   授权后需重启启动应用")
        Logger.warn("⚠️  当前仅麦克风录音可用，aggressive_gating 将无法工作")
      }
    }
  }

  func stop() async {
    Logger.info("🎬 SystemRecorder: Stopping capture...")
    try? await stream?.stopCapture()
    audioInput?.markAsFinished()

    Logger.info("🎬 SystemRecorder: Finalizing file...")
    Logger.info("🎵 System audio: Total \(audioSampleCount) samples received")

    // CRITICAL: Ensure moov atom is written before returning
    // Use polling approach which is more reliable in signal handling
    if let writer = assetWriter {
      // Start the finishWriting process
      writer.finishWriting(completionHandler: {})
      Logger.info("🎬 SystemRecorder: Waiting for finishWriting to complete...")

      // Poll status until complete or timeout (max 10 seconds)
      let startTime = Date()
      var attempts = 0
      while writer.status == .writing && Date().timeIntervalSince(startTime) < 10 {
        attempts += 1
        if attempts % 10 == 0 {
          Logger.debug("🎬 Still waiting... (attempt \(attempts))")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
      }

      Logger.info("🎬 SystemRecorder: finishWriting completed")
      Logger.info("🎬 SystemRecorder: Final status: \(writer.status.rawValue)")

      if writer.status == .completed {
        Logger.info("✅ SystemRecorder: File finalized successfully")
      } else if writer.status == .failed {
        Logger.error("❌ SystemRecorder: finishWriting failed!")
        if let error = writer.error {
          Logger.error("   Error: \(error)")
        }
      } else {
        Logger.warn("⚠️  SystemRecorder: finishWriting timeout, status: \(writer.status.rawValue)")
      }
    } else {
      Logger.info("✅ SystemRecorder: No writer, nothing to finalize")
    }

    // Wait for all OCR tasks to complete
    Logger.info("🔍 Waiting for OCR tasks to complete...")
    for task in ocrTasks {
      _ = await task.value
    }
    Logger.info("✅ OCR completed. \(screenshots.count) screenshots processed")

    // Save metadata.json
    saveMetadata()

    // Clean up for next session
    self.assetWriter = nil
    self.audioInput = nil
    self.stream = nil
    self.screenshots.removeAll()
    self.ocrTasks.removeAll()
  }

  private func saveMetadata() {
    let metadataUrl = URL(fileURLWithPath: outputDir).appendingPathComponent(
      "screenshots_metadata.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .secondsSince1970

    do {
      let data = try encoder.encode(screenshots)
      try data.write(to: metadataUrl)
      Logger.info("💾 Saved screenshots_metadata.json with \(screenshots.count) entries")
    } catch {
      Logger.warn("Failed to save metadata.json: \(error)")
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    if type == .audio {
      audioSampleCount += 1
      if audioSampleCount == 1 {
        Logger.info("🎵 System audio: First sample received")
      }
      if startTime == nil {
        startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordingStartTime = Date()
        // startSession 已经在 startWriting() 后立即调用，不再重复
      }
      if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sampleBuffer) }
    } else if type == .screen {
      screenFrameCount += 1
      if screenFrameCount == 1 {
        Logger.info("🖥️  Screen: First frame received")
      }
      // Only capture screenshots if auto-OCR is enabled
      if autoOcr {
        let now = Date()
        if now.timeIntervalSince(lastScreenshotTime) >= 10 {
          lastScreenshotTime = now
          saveScreenshot(buffer: sampleBuffer)
        }
      }
    }
  }

  private func saveScreenshot(buffer: CMSampleBuffer) {
    guard let cv = CMSampleBufferGetImageBuffer(buffer) else { return }
    let ci = CIImage(cvImageBuffer: cv)
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }

    // Use UTC+8 timestamp for filename consistency with audio files
    let fileTimestamp = beijingTimestamp()
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("shot_\(fileTimestamp).jpg")
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .jpeg, properties: [:])?.write(to: url)

    Logger.debug("📸 Screenshot saved: \(url.lastPathComponent)")

    // Use relative time (seconds from recording start) for metadata
    let relativeTimestamp = recordingStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0

    // Create metadata entry with new fields
    let metadata = ScreenshotMetadata(
      timestamp: relativeTimestamp,
      path: url.path,
      ocrText: "",
      ocrDelta: "",
      ocrHash: "",
      names: []
    )
    screenshots.append(metadata)

    // Launch OCR task asynchronously with delta compression
    let task = Task {
      // Compute perceptual hash for similarity detection
      let imageHash = computePerceptualHash(imagePath: url.path)

      // Check if image is similar to previous one
      let isSimilarToPrevious =
        !lastScreenshotHash.isEmpty && hashesSimilar(imageHash, lastScreenshotHash)

      // Always OCR, but use delta compression
      let ocrText = await performOCR(on: url.path)
      let ocrDelta =
        isSimilarToPrevious ? computeDelta(currentText: ocrText, previousText: lastOcrText) : ""

      let names = extractNames(from: ocrText)

      await MainActor.run {
        if let index = self.screenshots.firstIndex(where: { $0.timestamp == relativeTimestamp }) {
          self.screenshots[index].ocrText = ocrText
          self.screenshots[index].ocrDelta = ocrDelta
          self.screenshots[index].ocrHash = imageHash
          self.screenshots[index].names = names
        }

        // Update state for next comparison
        self.lastScreenshotHash = imageHash
        self.lastOcrText = ocrText

        let deltaPreview = ocrDelta.isEmpty ? "" : " | Δ: \(ocrDelta.prefix(30))..."
        Logger.debug(
          "🔍 OCR completed for shot_\(fileTimestamp): \(ocrText.prefix(30))...\(deltaPreview)")
      }
    }
    ocrTasks.append(task)
  }

  private func extractNames(from text: String) -> [String] {
    // Simple heuristic: extract words that look like names (Capitalized, 2-20 chars)
    // This will be refined by the fuzzy_join algorithm in transcribe.py
    let namePattern = "\\b[A-Z][a-z]{1,19}\\b"
    guard let regex = try? NSRegularExpression(pattern: namePattern) else { return [] }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    return matches.compactMap { String(text[Range($0.range, in: text)!]) }
  }

  private func performOCR(on imagePath: String) async -> String {
    let url = URL(fileURLWithPath: imagePath)
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else { return "" }

    return await withCheckedContinuation { continuation in
      let request = VNRecognizeTextRequest { req, _ in
        let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap {
          $0.topCandidates(1).first?.string
        }
        continuation.resume(returning: strings?.joined(separator: " ") ?? "")
      }
      request.recognitionLanguages = ["zh-Hans", "en-US"]
      request.recognitionLevel = .accurate
      try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }
  }

  // MARK: - OCR Delta Compression

  /// Compute perceptual hash of image for similarity detection
  private func computePerceptualHash(imagePath: String) -> String {
    guard
      let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else { return "" }

    // Resize to 8x8 for simple hash (faster than full perceptual hash)
    let width = 8
    let height = 8
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return "" }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height) else {
      return ""
    }

    // Compute average and generate hash
    var sum = 0
    for i in 0..<(width * height) {
      sum += Int(pixels[i])
    }
    let avg = sum / (width * height)

    var hash = ""
    for i in 0..<(width * height) {
      hash += pixels[i] > avg ? "1" : "0"
    }
    return hash
  }

  /// Compute delta between current and previous OCR text
  private func computeDelta(currentText: String, previousText: String) -> String {
    guard !previousText.isEmpty else { return currentText }

    let currentWords = Set(
      currentText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
    let previousWords = Set(
      previousText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })

    // Find new words (in current but not in previous)
    let newWords = currentWords.subtracting(previousWords)

    // Also find removed words (for context)
    let removedWords = previousWords.subtracting(currentWords)

    var deltaParts: [String] = []
    if !newWords.isEmpty {
      deltaParts.append("+ " + Array(newWords.sorted()).joined(separator: " "))
    }
    if !removedWords.isEmpty && removedWords.count < 20 {  // Only track removals if not too many
      deltaParts.append("- " + Array(removedWords.sorted()).joined(separator: " "))
    }

    return deltaParts.isEmpty ? "" : deltaParts.joined(separator: " | ")
  }

  /// Check if two hashes are similar (Hamming distance)
  private func hashesSimilar(_ hash1: String, _ hash2: String, threshold: Int = 10) -> Bool {
    guard hash1.count == hash2.count else { return false }
    var distance = 0
    for (c1, c2) in zip(hash1, hash2) where c1 != c2 {
      distance += 1
      if distance > threshold { return false }
    }
    return true
  }
}

@available(macOS 13.0, *)  // MARK: - Meet Session (Single Recording)
class MeetSession {
  let mic = MicRecorder()
  let sys = SystemRecorder()
  let name: String
  let mode: RecordingMode
  private var startTime: Date?
  private var timestamp: String = ""

  // Retention policy: keep recordings for N days
  private let retentionDays: Int = 7

  init(name: String, mode: RecordingMode = .both) {
    self.name = name.isEmpty ? "meeting" : name
    self.mode = mode
  }

  func run(outputDir: String) async {
    // Setup logging to file
    Logger.setupLogging(outputDir: outputDir)
    defer { Logger.closeLogging() }

    Logger.info("📹 Meet Session: \(name)")
    Logger.info("📁 Output: \(outputDir)")

    // Generate timestamp for recording (UTC+8)
    let timestamp = beijingTimestamp()
    self.timestamp = timestamp

    // Create session subdirectory: ~/recordings/20250114-140800_product-review/
    let sessionDir = URL(fileURLWithPath: outputDir)
      .appendingPathComponent("\(timestamp)_\(name)")

    let fm = FileManager.default
    try? fm.createDirectory(atPath: sessionDir.path, withIntermediateDirectories: true)

    // Clean up old recordings based on retention policy
    cleanupOldRecordings(in: outputDir, retentionDays: retentionDays)

    // Generate file paths in session subdirectory
    let micPath = sessionDir.appendingPathComponent("\(timestamp)_\(name)_mic.m4a")
    let sysPath = sessionDir.appendingPathComponent("\(timestamp)_\(name)_sys.m4a")

    Logger.info("📂 Session folder: \(sessionDir.lastPathComponent)")

    self.startTime = Date()

    // Show recording mode
    switch mode {
    case .both:
      Logger.info("🎙️ Recording mode: Mic + System Audio")
      checkAudioOutput()
    case .micOnly:
      Logger.info("🎙️ Recording mode: Mic Only")
    case .sysOnly:
      Logger.info("🎙️ Recording mode: System Audio Only")
    }

    Logger.info("🎬 Starting recording...")
    Logger.info("Press Ctrl+\\ to stop")

    // Setup signal handling with proper task completion
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    var isStopping = false
    var stopTask: Task<Void, Never>?

    signalSource.setEventHandler {
      if !isStopping {
        Logger.info("\n🛑 Stopping recording...")
        isStopping = true
        stopTask = Task {
          await self.stop(micPath: micPath, sysPath: sysPath, outputDir: outputDir)
        }
      }
    }
    termSource.setEventHandler {
      if !isStopping {
        Logger.info("\n🛑 Stopping recording...")
        isStopping = true
        stopTask = Task {
          await self.stop(micPath: micPath, sysPath: sysPath, outputDir: outputDir)
        }
      }
    }

    signalSource.resume()
    termSource.resume()

    // Start recording
    switch mode {
    case .both:
      try? await mic.start(outputURL: micPath)
      try? await sys.start(outputURL: sysPath)
    case .micOnly:
      try? await mic.start(outputURL: micPath)
    case .sysOnly:
      try? await sys.start(outputURL: sysPath)
    }

    // Keep running until interrupted
    while !isStopping {
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    }

    // Wait for stop task to complete
    if let task = stopTask {
      await task.value
    }

    signalSource.cancel()
    termSource.cancel()
  }

  private func stop(micPath: URL, sysPath: URL, outputDir: String) async {
    Logger.info("💾 Finalizing recordings...")

    // Stop recorders
    switch mode {
    case .both:
      await mic.stop()
      await sys.stop()
    case .micOnly:
      await mic.stop()
    case .sysOnly:
      await sys.stop()
    }

    Logger.info("✅ Recordings saved:")
    if mode == .both || mode == .micOnly {
      Logger.info("   Mic: \(micPath.path)")
    }
    if mode == .both || mode == .sysOnly {
      Logger.info("   Sys: \(sysPath.path)")
    }

    // Auto-transcribe (save in same session subdirectory)
    Logger.info("🤖 Starting transcription...")
    let pythonPath = ConfigManager.shared.current.python_path ?? "python3"
    let transcribeScript = ConfigManager.shared.current.transcribe_script ?? "scripts/transcribe.py"

    // Output transcript in the session subdirectory
    let sessionDir = micPath.deletingLastPathComponent()
    let transcriptPath = sessionDir.appendingPathComponent("\(timestamp)_\(name)_transcript.json")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)

    // Get transcribe engine from config (Issue #3)
    let transcribeEngine = ConfigManager.shared.getMeetTranscribeEngine()

    // Build arguments based on engine
    var args = [
      transcribeScript,
      "-o", transcriptPath.path,
      "--engine", transcribeEngine,
      "--language", "auto",
    ]

    // Add LiteLLM parameters if using litellm engine
    if transcribeEngine == "litellm" {
      if let litellmUrl = ConfigManager.shared.current.litellm_url {
        args += ["--litellm-url", litellmUrl]
      }
      if let litellmModel = ConfigManager.shared.current.litellm_model {
        args += ["--litellm-model", litellmModel]
      }
      if let litellmApiKey = ConfigManager.shared.current.litellm_api_key {
        args += ["--litellm-api-key", litellmApiKey]
      }
    }

    // Add audio files
    if mode == .both || mode == .micOnly {
      args.append(micPath.path)
    }
    if mode == .both || mode == .sysOnly {
      args.append(sysPath.path)
    }

    process.arguments = args

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        Logger.info("✅ Transcription complete!")
      } else {
        Logger.warn("⚠️ Transcription failed with exit code \(process.terminationStatus)")
      }
    } catch {
      Logger.warn("⚠️ Failed to run transcription: \(error)")
    }

    // Show duration
    if let start = startTime {
      let duration = Date().timeIntervalSince(start)
      Logger.info("⏱ Session duration: \(Int(duration))s")
    }

    // Clean up old audio files (keep only 24 hours)
    cleanupOldAudioFiles(in: outputDir, retentionHours: 24)

    Logger.info("🎉 Meet session complete!")
  }

  private func checkAudioOutput() {
    // Check if using built-in speaker (not headphones/external)
    var deviceAddress: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize,
        &deviceAddress) == noErr
    else {
      return
    }

    var name: CFString = "" as CFString
    propertySize = UInt32(MemoryLayout<CFString>.size)
    propertyAddress.mSelector = kAudioObjectPropertyName
    if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name)
      == noErr
    {
      let deviceName = name as String
      let isBuiltInSpeaker =
        deviceName.localizedCaseInsensitiveContains("built-in")
        || deviceName.localizedCaseInsensitiveContains("内建")
        || deviceName.localizedCaseInsensitiveContains("扬声器")
        || deviceName.localizedCaseInsensitiveContains("MacBook Pro")
        || (deviceName.localizedCaseInsensitiveContains("MacBook")
          && deviceName.localizedCaseInsensitiveContains("Speakers"))

      if isBuiltInSpeaker {
        Logger.warn("⚠️ 警告: 正在使用扬声器录制，可能会录到回声")
        Logger.warn("   建议: 使用耳机，或添加 --system-only 只录制系统音频")
      }
    }
  }

  private func cleanupOldRecordings(in baseDir: String, retentionDays: Int) {
    let fm = FileManager.default
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

    guard let contents = try? fm.contentsOfDirectory(atPath: baseDir) else { return }

    var deletedCount = 0
    var freedSpace: Int64 = 0

    for item in contents {
      let itemPath = URL(fileURLWithPath: baseDir).appendingPathComponent(item)

      // Get modification date
      var attributes: [FileAttributeKey: Any]?
      do {
        attributes = try fm.attributesOfItem(atPath: itemPath.path)
      } catch {
        continue
      }

      guard let modDate = attributes?[.modificationDate] as? Date else { continue }

      // Delete if older than retention days
      if modDate < cutoffDate {
        do {
          // Get file size before deletion
          if let fileSize = attributes?[.size] as? Int64 {
            freedSpace += fileSize
          }

          try fm.removeItem(atPath: itemPath.path)
          deletedCount += 1

          let daysOld = Calendar.current.dateComponents([.day], from: modDate, to: Date()).day ?? 0
          Logger.debug("🗑️  Deleted old recording: \(item) (\(daysOld) days old)")
        } catch {
          Logger.warn("Failed to delete \(item): \(error)")
        }
      }
    }

    if deletedCount > 0 {
      let freedMB = freedSpace / 1024 / 1024
      Logger.info("🧹 Cleaned up \(deletedCount) old recording(s), freed \(freedMB)MB")
    }
  }

  private func cleanupOldAudioFiles(in baseDir: String, retentionHours: Int) {
    let fm = FileManager.default
    let cutoffDate = Calendar.current.date(byAdding: .hour, value: -retentionHours, to: Date())!

    guard let contents = try? fm.contentsOfDirectory(atPath: baseDir) else { return }

    var deletedAudioCount = 0
    var freedSpace: Int64 = 0

    for item in contents {
      let itemPath = URL(fileURLWithPath: baseDir).appendingPathComponent(item)

      // Skip if not a directory
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: itemPath.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }

      // Check each file in the session directory
      guard let files = try? fm.contentsOfDirectory(atPath: itemPath.path) else { continue }

      for file in files {
        // Only delete .m4a files (audio), keep JSON and screenshots
        guard file.hasSuffix("_mic.m4a") || file.hasSuffix("_sys.m4a") else {
          continue
        }

        let filePath = itemPath.appendingPathComponent(file)

        var attributes: [FileAttributeKey: Any]?
        do {
          attributes = try fm.attributesOfItem(atPath: filePath.path)
        } catch {
          continue
        }

        guard let modDate = attributes?[.modificationDate] as? Date else { continue }

        // Delete if older than retention hours
        if modDate < cutoffDate {
          do {
            if let fileSize = attributes?[.size] as? Int64 {
              freedSpace += fileSize
            }

            try fm.removeItem(atPath: filePath.path)
            deletedAudioCount += 1

            let hoursOld =
              Calendar.current.dateComponents([.hour], from: modDate, to: Date()).hour ?? 0
            Logger.debug("🗑️  Deleted old audio: \(file) (\(hoursOld)h old)")
          } catch {
            Logger.warn("Failed to delete \(file): \(error)")
          }
        }
      }
    }

    if deletedAudioCount > 0 {
      let freedMB = freedSpace / 1024 / 1024
      Logger.info("🧹 Cleaned up \(deletedAudioCount) old audio file(s), freed \(freedMB)MB")
      Logger.info("   (Transcripts and screenshots preserved)")
    }
  }
}

@available(macOS 13.0, *)  // MARK: - Daemon
enum RecordingMode {
  case both  // Mic + System audio (default)
  case micOnly  // Mic only
  case sysOnly  // System audio only
}

// MARK: - Daemon PID Management
@available(macOS 13.0, *)
let PID_FILE = "~/.config/ikit/meet.pid"

func getPidFilePath() -> String {
  return NSString(string: PID_FILE).expandingTildeInPath
}

func savePidFile(pid: Int32) {
  let pidPath = getPidFilePath()
  let pidDir = URL(fileURLWithPath: pidPath).deletingLastPathComponent().path
  try? FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)

  do {
    try String(pid).write(toFile: pidPath, atomically: true, encoding: .utf8)
    Logger.info("📝 PID file saved: \(pidPath)")
  } catch {
    Logger.error("❌ Failed to save PID file: \(error)")
  }
}

func removePidFile() {
  let pidPath = getPidFilePath()
  try? FileManager.default.removeItem(atPath: pidPath)
}

func getDaemonPid() -> Int32? {
  let pidPath = getPidFilePath()
  guard FileManager.default.fileExists(atPath: pidPath),
    let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
    let pid = Int32(pidStr)
  else {
    return nil
  }

  // Verify process is actually running using kill(pid, 0)
  // kill(pid, 0) returns 0 if process exists, -1 if not
  if kill(pid, 0) == 0 {
    return pid
  }

  return nil
}

func isDaemonRunning() -> Bool {
  return getDaemonPid() != nil
}

@available(macOS 13.0, *)
func showDaemonStatus() {
  if let pid = getDaemonPid() {
    print("✅ Daemon running (PID: \(pid))")

    // Check heartbeat file
    let logPath = NSString(string: "~/recordings").expandingTildeInPath
    var outputDir: String? = nil

    // Get only directories that match date pattern (YYYY-MM-DD)
    if let allItems = try? FileManager.default.contentsOfDirectory(atPath: logPath) {
      let dateDirs = allItems.filter { item in
        // Match YYYY-MM-DD pattern
        let regex = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
        let range = NSRange(location: 0, length: item.utf16.count)
        let isMatch = regex?.firstMatch(in: item, range: range) != nil

        // Also check it's a directory
        var isDir: ObjCBool = false
        let isDirectory =
          FileManager.default.fileExists(atPath: "\(logPath)/\(item)", isDirectory: &isDir)
          && isDir.boolValue

        return isMatch && isDirectory
      }.sorted()

      if let dateDir = dateDirs.last {
        outputDir = "\(logPath)/\(dateDir)"
        let heartbeatPath = "\(outputDir!)/.heartbeat"
        if let heartbeatStr = try? String(contentsOfFile: heartbeatPath, encoding: .utf8),
          let heartbeatDate = ISO8601DateFormatter().date(from: heartbeatStr)
        {
          let now = Date()
          let interval = now.timeIntervalSince(heartbeatDate)
          if interval < 30 {
            print("💚 Heartbeat: \(Int(interval))s ago")
          } else {
            print("💔 Heartbeat stale: \(Int(interval))s ago (daemon may be frozen)")
          }
        }
      }
    }

    // Try to get more info from the log file
    if let dir = outputDir {
      let actualLogFile = "\(dir)/ikit-\(URL(fileURLWithPath: dir).lastPathComponent).log"
      if let content = try? String(contentsOfFile: actualLogFile, encoding: .utf8),
        let lastLine = content.components(separatedBy: "\n").last, !lastLine.isEmpty
      {
        print("📁 Output: \(dir)")
        print("📊 Last log: \(lastLine)")
      } else {
        print("📁 Output: \(dir)")
      }
    }
  } else {
    print("⚠️  Daemon is not running")
    print("   Start with: ikit meet daemon <outputDir>")
  }
}

@available(macOS 13.0, *)
func stopDaemon() {
  guard let pid = getDaemonPid() else {
    print("⚠️  No daemon found running")
    print("   Start with: ikit meet daemon <outputDir>")
    return
  }

  print("⏸️  Stopping daemon (PID: \(pid))...")

  // Send SIGQUIT for graceful shutdown
  kill(pid, SIGQUIT)

  // Wait for process to exit (max 10 seconds)
  for _ in 0..<10 {
    usleep(1_000_000)  // 1 second
    if getDaemonPid() == nil {
      print("✅ Daemon stopped successfully")
      return
    }
  }

  // If still running, force kill
  if getDaemonPid() != nil {
    print("⚠️  Daemon did not stop gracefully, forcing...")
    kill(pid, SIGKILL)
    usleep(500_000)
    if getDaemonPid() == nil {
      print("✅ Daemon forced to stop")
    } else {
      print("❌ Failed to stop daemon")
    }
  }

  removePidFile()
}

@available(macOS 13.0, *)
class Daemon {
  let mic = MicRecorder()
  let sys = SystemRecorder()
  let queue = DispatchQueue(label: "ikit.daemon")
  private var isRecording = false
  private var currentMicPath: URL?
  private var currentSysPath: URL?
  private var cancellableTask: Task<Void, Never>?
  private let mode: RecordingMode
  private var powerAssertionID: IOPMAssertionID = 0
  private let segmentDuration: UInt64  // Segment duration in nanoseconds
  private var processedSegments: Set<String> = []  // Track processed segments to prevent duplicate transcription
  private let backgroundMode: Bool  // Whether running in background mode
  private var heartbeatPath: String?  // Path to heartbeat file

  init(mode: RecordingMode = .both, segmentMinutes: Int = 15, background: Bool = false) {
    self.mode = mode
    self.segmentDuration = UInt64(segmentMinutes * 60 * 1_000_000_000)
    self.backgroundMode = background
  }

  // MARK: - Heartbeat Management
  private func setupHeartbeat(outputDir: String) {
    let heartbeatFile = URL(fileURLWithPath: outputDir).appendingPathComponent(".heartbeat").path
    self.heartbeatPath = heartbeatFile
    updateHeartbeat()
  }

  private func updateHeartbeat() {
    guard let path = heartbeatPath else { return }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    do {
      try timestamp.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
      Logger.debug("Failed to update heartbeat: \(error)")
    }
  }

  private func removeHeartbeat() {
    guard let path = heartbeatPath else { return }
    try? FileManager.default.removeItem(atPath: path)
    heartbeatPath = nil
  }

  // MARK: - Power Management (防止睡眠)
  private func preventSleep() -> Bool {
    let reason = "iKit Daemon: Preventing system sleep during recording" as CFString
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep,
      reason,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      &powerAssertionID
    )
    return result == kIOReturnSuccess
  }

  private func allowSleep() {
    if powerAssertionID != 0 {
      IOPMAssertionRelease(powerAssertionID)
      powerAssertionID = 0
      Logger.info("💤 Sleep prevention disabled")
    }
  }

  func run(outputDir: String) async {
    // Create/get daily folder (UTC+8)
    let dailyFolderName = beijingDate()
    let dailyDir = URL(fileURLWithPath: outputDir).appendingPathComponent(dailyFolderName).path

    let fm = FileManager.default
    try? fm.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

    // Setup logging to file in daily folder
    Logger.setupLogging(outputDir: dailyDir)
    defer {
      Logger.closeLogging()
      allowSleep()
      removePidFile()  // Clean up PID file on exit
      removeHeartbeat()  // Clean up heartbeat file on exit
    }

    // Save PID file
    savePidFile(pid: Int32(getpid()))

    // Setup heartbeat file
    setupHeartbeat(outputDir: dailyDir)

    // Run pre-flight checks
    let _ = runPreflightChecks(outputDir: dailyDir)

    Logger.info("👻 Daemon started. Output: \(dailyDir)")

    if backgroundMode {
      Logger.info("🔄 Background mode enabled")
      print("✅ Daemon started in background (PID: \(getpid()))")
      print("   Check status: ikit meet status")
      print("   Stop recording: ikit meet stop")
    }

    // Configure auto-OCR from config
    let configManager = ConfigManager.shared
    let autoOcrEnabled = configManager.current.auto_ocr ?? false
    sys.setAutoOcr(autoOcrEnabled)

    // Prevent system sleep
    // TODO: IOKit sleep prevention causes issues, disabled for now
    // if preventSleep() {
    //     Logger.info("⚡ Sleep prevention enabled")
    // } else {
    //     Logger.warn("⚠️ Failed to enable sleep prevention")
    // }

    // Show recording mode
    switch mode {
    case .both:
      Logger.info("🎙️ Recording mode: Mic + System Audio")
      checkAudioOutput()
    case .micOnly:
      Logger.info("🎙️ Recording mode: Mic Only")
    case .sysOnly:
      Logger.info("🎙️ Recording mode: System Audio Only")
    }

    Logger.info("Press Ctrl+\\ to stop recording and save files")
    let intervalMinutes = segmentDuration / 60 / 1_000_000_000
    Logger.info("⚠️  Files will be auto-saved every \(intervalMinutes) minutes")
    Logger.info("⚠️  Wait for 'All recordings saved and finalized' before force quitting")

    // Run the main loop with daily directory
    await runLoop(outputDir: dailyDir, fm: fm)

    // ⭐ Wait for any ongoing transcriptions to complete before exit
    let activeCount = TranscriptionManager.shared.activeProcessCount()
    if activeCount > 0 {
      Logger.info("⏳ Waiting for \(activeCount) transcription(s) to complete...")
      Logger.info("   (Press Ctrl+C again to force quit)")
      let completed = await TranscriptionManager.shared.waitForCompletion(timeout: 300)
      if !completed {
        Logger.warn("⚠️  Some transcriptions did not complete in time, terminating...")
        TranscriptionManager.shared.terminateAllChildren()
      }
    }

    // Normal exit cleanup
    Logger.info("✅ All recordings saved and finalized")

    // ⭐ Generate integrated meeting summary from all segments
    await generateIntegratedSummary(outputDir: dailyDir, configManager: configManager)
  }

  private func checkAudioOutput() {
    // Check if using built-in speaker (not headphones/external)
    var deviceAddress: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize,
        &deviceAddress) == noErr
    else {
      Logger.debug("Failed to get default output device")
      return
    }

    // Get device name
    var name: CFString = "" as CFString
    propertySize = UInt32(MemoryLayout<CFString>.size)
    propertyAddress.mSelector = kAudioObjectPropertyName
    if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name)
      == noErr
    {
      let deviceName = name as String
      Logger.debug("🔊 Audio output device: \(deviceName)")
      // Check if it's built-in speaker
      let isBuiltInSpeaker =
        deviceName.localizedCaseInsensitiveContains("built-in")
        || deviceName.localizedCaseInsensitiveContains("内建")
        || deviceName.localizedCaseInsensitiveContains("扬声器")
        || deviceName.localizedCaseInsensitiveContains("MacBook Pro")
        || (deviceName.localizedCaseInsensitiveContains("MacBook")
          && deviceName.localizedCaseInsensitiveContains("Speakers"))

      if isBuiltInSpeaker {
        Logger.warn("⚠️ 警告: 正在使用扬声器录制，可能会录到回声")
        Logger.warn("   建议: 使用耳机，或添加 --system-only 只录制系统音频")
      }
    }
  }

  private func checkIsUsingSpeaker() -> Bool {
    var deviceAddress: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize,
        &deviceAddress) == noErr
    else {
      return false
    }

    var name: CFString = "" as CFString
    propertySize = UInt32(MemoryLayout<CFString>.size)
    propertyAddress.mSelector = kAudioObjectPropertyName
    if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name)
      == noErr
    {
      let deviceName = name as String
      return deviceName.localizedCaseInsensitiveContains("built-in")
        || deviceName.localizedCaseInsensitiveContains("内建")
        || deviceName.localizedCaseInsensitiveContains("扬声器")
    }
    return false
  }

  // MARK: - Pre-flight Checks
  private func checkMicrophonePermission() -> Bool {
    // This check happens during actual recording attempt
    // We'll rely on AVFoundation's permission system
    return true
  }

  private func checkDiskSpace(requiredGB: Double = 5.0) -> (available: Bool, freeGB: Double)? {
    do {
      let fm = FileManager.default
      let urls = fm.urls(for: .documentDirectory, in: .userDomainMask)
      guard let homeURL = urls.first else { return nil }

      let values = try homeURL.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ])
      if let capacity = values.volumeAvailableCapacityForImportantUsage {
        let freeGB = Double(capacity) / (1024 * 1024 * 1024)
        return (freeGB >= requiredGB, freeGB)
      }
    } catch {
      Logger.debug("Failed to check disk space: \(error)")
    }
    return nil
  }

  private func checkFunASRAvailability() -> Bool {
    let pythonPath = ConfigManager.shared.current.python_path ?? "/usr/local/bin/python3"

    let process = Process()
    process.launchPath = pythonPath
    process.arguments = ["-c", "import funasr; print('OK')"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        return true
      }
    } catch {
      Logger.debug("Failed to check FunASR: \(error)")
    }
    return false
  }

  private func runPreflightChecks(outputDir: String) -> Bool {
    var allPassed = true

    Logger.info("🔍 Running pre-flight checks...")

    // Check disk space
    if let (available, freeGB) = checkDiskSpace(requiredGB: 5.0) {
      if available {
        Logger.info("✅ Disk space: \(String(format: "%.1f", freeGB)) GB available")
      } else {
        Logger.error(
          "❌ Insufficient disk space: \(String(format: "%.1f", freeGB)) GB (need 5.0 GB)")
        allPassed = false
      }
    } else {
      Logger.warn("⚠️  Could not check disk space")
    }

    // Check FunASR availability
    if checkFunASRAvailability() {
      Logger.info("✅ FunASR is available")
    } else {
      Logger.warn("⚠️  FunASR not found - transcription will be disabled")
      Logger.warn("   Install with: pip install funasr")
    }

    // Check if output directory is writable
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: outputDir, isDirectory: &isDir) {
      if fm.isWritableFile(atPath: outputDir) {
        Logger.info("✅ Output directory is writable: \(outputDir)")
      } else {
        Logger.error("❌ Output directory is not writable: \(outputDir)")
        allPassed = false
      }
    } else {
      // Try to create the directory
      do {
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        Logger.info("✅ Output directory created: \(outputDir)")
      } catch {
        Logger.error("❌ Cannot create output directory: \(error)")
        allPassed = false
      }
    }

    if allPassed {
      Logger.info("✅ All pre-flight checks passed")
    } else {
      Logger.error("❌ Pre-flight checks failed - daemon may not work correctly")
    }

    return allPassed
  }

  private func runLoop(outputDir: String, fm: FileManager) async {
    // ⭐ Store cleanup info for potential use by signal handlers
    var activeSegment: (mic: URL, sys: URL, final: URL)? = nil

    while !Task.isCancelled {
      // Check for cancellation explicitly
      do {
        try Task.checkCancellation()
      } catch {
        Logger.info("🛑 Recording stopped by user (Ctrl+\\)")
        if isRecording, let seg = activeSegment {
          await stopRecording()
          processSegment(micPath: seg.mic, sysPath: seg.sys, finalPath: seg.final, fm: fm)
        }
        break
      }

      let ts = beijingTimestamp()
      let micPath = URL(fileURLWithPath: outputDir).appendingPathComponent("\(ts)_mic.m4a")
      let sysPath = URL(fileURLWithPath: outputDir).appendingPathComponent("\(ts)_sys.m4a")
      let finalPath = URL(fileURLWithPath: outputDir).appendingPathComponent("\(ts)_merged.m4a")

      self.currentMicPath = micPath
      self.currentSysPath = sysPath
      isRecording = true
      activeSegment = (mic: micPath, sys: sysPath, final: finalPath)

      Logger.info("🔴 Recording segment: \(ts)")

      // Start recording based on mode
      if mode == .both || mode == .micOnly {
        mic.start(outputURL: micPath)
      }
      if mode == .both || mode == .sysOnly {
        try? await sys.start(outputURL: sysPath)
      }

      // Segment duration with periodic shutdown checks (1 second intervals)
      let totalDuration: UInt64 = segmentDuration  // Configurable segment duration
      let checkInterval: UInt64 = 1_000_000_000  // 1 second in nanoseconds
      var elapsed: UInt64 = 0
      var heartbeatCounter = 0  // For updating heartbeat every 10 seconds

      while elapsed < totalDuration && !isShuttingDown {
        do {
          let remaining = min(totalDuration - elapsed, checkInterval)
          try await Task.sleep(nanoseconds: remaining)
          elapsed += remaining

          // Update heartbeat every 10 seconds
          heartbeatCounter += 1
          if heartbeatCounter >= 10 {
            updateHeartbeat()
            heartbeatCounter = 0
          }
        } catch is CancellationError {
          Logger.info("🛑 Recording stopped by task cancellation")
          await stopRecording()
          if let seg = activeSegment {
            processSegment(micPath: seg.mic, sysPath: seg.sys, finalPath: seg.final, fm: fm)
          }
          break
        } catch {
          Logger.error("Unexpected error: \(error)")
          await stopRecording()
          if let seg = activeSegment {
            processSegment(micPath: seg.mic, sysPath: seg.sys, finalPath: seg.final, fm: fm)
          }
          break
        }
      }

      // If shutdown was signaled, exit gracefully
      if isShuttingDown {
        Logger.info("🛑 Shutdown signal received, finalizing recording...")
        await stopRecording()
        if let seg = activeSegment {
          processSegment(micPath: seg.mic, sysPath: seg.sys, finalPath: seg.final, fm: fm)
        }
        break
      }

      await stopRecording()
      processSegment(micPath: micPath, sysPath: sysPath, finalPath: finalPath, fm: fm)
      activeSegment = nil
    }
  }

  private func stopRecording() async {
    guard isRecording else { return }
    isRecording = false

    // Stop based on mode
    if mode == .both || mode == .micOnly {
      mic.stop()
    }
    if mode == .both || mode == .sysOnly {
      await sys.stop()
    }

    Logger.info("💾 Recordings finalized")

    // Process the current segment if it exists
    if let micPath = currentMicPath, let sysPath = currentSysPath {
      let fm = FileManager.default
      let ts = micPath.deletingPathExtension().lastPathComponent.replacingOccurrences(
        of: "_mic", with: "")
      let finalPath = URL(fileURLWithPath: micPath.deletingLastPathComponent().path)
        .appendingPathComponent("\(ts)_merged.m4a")

      processSegment(micPath: micPath, sysPath: sysPath, finalPath: finalPath, fm: fm)
    }

    Logger.info("✅ All recordings saved")
  }

  private func processSegment(micPath: URL, sysPath: URL, finalPath: URL, fm: FileManager) {
    queue.async {
      // Create unique identifier for this segment
      let segmentId = finalPath.lastPathComponent

      // Check if already processed to prevent duplicate transcription
      defer {
        // Mark as processed regardless of success/failure
        self.processedSegments.insert(segmentId)
      }

      // Skip if already processed
      if self.processedSegments.contains(segmentId) {
        Logger.info("⏭️  Segment \(segmentId) already processed, skipping transcription")
        return
      }

      // Merge logic based on mode
      let ffmpeg = "/usr/local/bin/ffmpeg"

      // Determine which files exist based on mode
      let hasMic =
        (self.mode == .both || self.mode == .micOnly) && fm.fileExists(atPath: micPath.path)
      let hasSys =
        (self.mode == .both || self.mode == .sysOnly) && fm.fileExists(atPath: sysPath.path)

      var filesToProcess: [URL] = []

      if hasMic && hasSys {
        // Both files exist - keep them separate for Python aggressive_gating
        Logger.info("✅ Dual-track recording ready for auto-processing")
        filesToProcess.append(micPath)
        filesToProcess.append(sysPath)
      } else if hasMic {
        // Only mic file - rename to merged
        try? fm.moveItem(at: micPath, to: finalPath)
        filesToProcess.append(finalPath)
      } else if hasSys {
        // Only sys file - rename to merged
        try? fm.moveItem(at: sysPath, to: finalPath)
        filesToProcess.append(finalPath)
      }

      Logger.info("✅ Saved: \(finalPath.lastPathComponent)")

      // ⭐ Auto-process: Always trigger, even during shutdown
      // Transcription runs in background, independent of recording lifecycle
      Task {
        await self.autoProcessRecordings(
          filesToProcess, outputDir: finalPath.deletingLastPathComponent().path)
      }
    }
  }

  // MARK: - Auto-processing (自动转录)
  // Runs in background, independent of recording lifecycle
  private func autoProcessRecordings(_ files: [URL], outputDir: String) async {
    let configManager = ConfigManager.shared

    guard let python = configManager.current.python_path,
      let script = configManager.current.transcribe_script
    else {
      Logger.warn("⚠️  Python/Script not configured, skipping auto-transcription")
      return
    }

    // Handle dual-track (2 files) or single-track (1 file)
    if files.count == 2 {
      // Dual-track: both mic and sys files
      let micPath = files.first { $0.path.contains("_mic.") } ?? files[0]
      let sysPath = files.first { $0.path.contains("_sys.") } ?? files[1]

      // Output based on timestamp (strip _mic or _sys suffix)
      let timestamp = micPath.deletingPathExtension().lastPathComponent.replacingOccurrences(
        of: "_mic", with: "")
      let out = URL(fileURLWithPath: outputDir).appendingPathComponent("\(timestamp).json")

      // Check if already transcribed
      if FileManager.default.fileExists(atPath: out.path) {
        Logger.info("⏭️  Already transcribed: \(timestamp)")
        return
      }

      Logger.info(
        "🎤 Auto-transcribing dual-track: \(micPath.lastPathComponent) + \(sysPath.lastPathComponent)"
      )

      // Use TranscriptionManager for tracked process with timeout
      let outPipe = Pipe()
      let errPipe = Pipe()
      let result = TranscriptionManager.shared.runTranscription(
        executable: python,
        args: [script, micPath.path, sysPath.path, "--output", out.path],
        outputPipe: outPipe,
        errorPipe: errPipe
      )

      if result.exitCode == 0 {
        Logger.info("✅ Transcription complete: \(out.lastPathComponent)")
        await processSummaryIfNeeded(
          result: result, output: out, configManager: configManager, outputDir: outputDir)
      } else {
        Logger.error("❌ Transcription failed for \(timestamp)")
      }
    } else if files.count == 1 {
      // Single-track: only one file
      let audioFile = files[0]
      let out = audioFile.deletingPathExtension().appendingPathExtension("json")

      // Check if already transcribed
      if FileManager.default.fileExists(atPath: out.path) {
        Logger.info("⏭️  Already transcribed: \(audioFile.lastPathComponent)")
        return
      }

      Logger.info("🎤 Auto-transcribing: \(audioFile.lastPathComponent)")

      // Use TranscriptionManager for tracked process with timeout
      let outPipe = Pipe()
      let errPipe = Pipe()
      let result = TranscriptionManager.shared.runTranscription(
        executable: python,
        args: [script, audioFile.path, "--output", out.path],
        outputPipe: outPipe,
        errorPipe: errPipe
      )

      if result.exitCode == 0 {
        Logger.info("✅ Transcription complete: \(out.lastPathComponent)")
        await processSummaryIfNeeded(
          result: result, output: out, configManager: configManager, outputDir: outputDir)
      } else {
        Logger.error("❌ Transcription failed for: \(audioFile.lastPathComponent)")
      }
    } else {
      Logger.warn("⚠️  No audio files to process")
    }
  }

  // Helper function to process summary if LLM is available
  private func processSummaryIfNeeded(
    result: (output: String?, error: String?, exitCode: Int32), output: URL,
    configManager: ConfigManager, outputDir: String
  ) async {
    var llmURL: String? = nil
    var llmType = ""
    var llmApiKey: String? = nil

    // Priority 1: Try LiteLLM if configured (higher priority)
    if let litellmUrlConfig = configManager.current.litellm_url {
      // Use dedicated health endpoint for LiteLLM
      var healthUrlString = litellmUrlConfig
      // Replace /v1/completions or similar with /health/liveliness
      if let range = healthUrlString.range(of: "/v1/", options: .caseInsensitive) {
        healthUrlString = String(healthUrlString[..<range.lowerBound])
      }
      // Remove trailing slash if present
      healthUrlString = healthUrlString.trimmingCharacters(in: ["/"])
      healthUrlString += "/health/liveliness"

      if let healthUrl = URL(string: healthUrlString) {
        var request = URLRequest(url: healthUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        if let apiKey = configManager.current.litellm_api_key, !apiKey.isEmpty {
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
          let (_, response) = try await URLSession.shared.data(for: request)
          let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
          if statusCode == 200 {
            llmURL = litellmUrlConfig
            llmType = "LiteLLM"
            llmApiKey = configManager.current.litellm_api_key
            Logger.info("🤖 Using LiteLLM (configured priority)")
          }
        } catch {
          Logger.debug("LiteLLM health check failed: \(error.localizedDescription)")
        }
      }
    }

    // Priority 2: Fallback to Ollama only if LiteLLM not configured
    if llmURL == nil {
      llmURL = configManager.current.ollama_url
      llmType = "Ollama"
      Logger.info("🤖 Using Ollama (fallback)")
    }

    guard let url = llmURL, let apiUrl = URL(string: url) else {
      Logger.warn("⚠️ No LLM service configured")
      return
    }

    // Skip additional health check - already verified above
    Logger.info("🤖 \(llmType) connected, processing summary...")
    let secretary = SecretaryTool()
    await secretary.process(files: [output.path], outputDir: outputDir)
  }

  // Generate integrated summary from all segments
  private func generateIntegratedSummary(outputDir: String, configManager: ConfigManager) async {
    // Check if auto-summary is disabled (Issue #2)
    guard configManager.getMeetAutoSummary() else {
      Logger.info("📋 Auto-summary disabled by config (meet.auto_summary = false)")
      return
    }

    let fm = FileManager.default

    // Find all JSON transcription files
    guard let files = try? fm.contentsOfDirectory(atPath: outputDir) else { return }

    let jsonFiles =
      files
      .filter { $0.hasSuffix(".json") && $0.contains("_merged") }
      .sorted()

    guard !jsonFiles.isEmpty else {
      Logger.debug("📋 No transcriptions found for integrated summary")
      return
    }

    guard jsonFiles.count > 1 else {
      Logger.debug("📋 Only 1 segment found, skipping integrated summary")
      return
    }

    Logger.info("📋 Generating integrated summary from \(jsonFiles.count) segments...")

    // Merge all transcriptions
    var mergedText = ""
    var allScreenshots: [String] = []
    var allOcrMetadata: [[String: Any]] = []

    for jsonFile in jsonFiles {
      let jsonPath = URL(fileURLWithPath: outputDir).appendingPathComponent(jsonFile).path

      guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
        let items = try? JSONDecoder().decode([FunASRItem].self, from: data)
      else { continue }

      // Add segment separator
      if !mergedText.isEmpty {
        mergedText += "\n---\n"
      }

      // Format dialogue
      for item in items {
        if let sentences = item.sentence_info {
          for s in sentences {
            mergedText += "[Speaker \(s.spk ?? 0)]: \(s.text)\n"
          }
        } else if let text = item.text {
          mergedText += text + "\n"
        }
      }

      // Collect screenshots
      let screenshots =
        (try? fm.contentsOfDirectory(atPath: outputDir))?
        .filter { $0.hasPrefix("shot_") && $0.hasSuffix(".jpg") }
        .sorted() ?? []
      allScreenshots.append(contentsOf: screenshots.map { "\(outputDir)/\($0)" })
    }

    // Load OCR metadata if available
    let metadataPath = "\(outputDir)/screenshots_metadata.json"
    if let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
      let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [[String: Any]]
    {
      allOcrMetadata = metadata
      Logger.info("📸 Loaded \(allOcrMetadata.count) OCR metadata entries")
    }

    // Generate integrated summary using SecretaryTool
    let secretary = SecretaryTool()

    // Call summarize directly with merged content
    let summary = await secretary.summarize(
      text: mergedText,
      screenshots: Array(Set(allScreenshots)).sorted(),  // Deduplicate
      ocrMetadata: allOcrMetadata
    )

    if !summary.isEmpty {
      let dateStr = ISO8601DateFormatter().string(from: Date())
      let outPath = URL(fileURLWithPath: outputDir).appendingPathComponent(
        "\(dateStr)-INTEGRATED-meeting-summary.md"
      ).path

      // Ensure output directory exists
      try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

      if (try? summary.write(toFile: outPath, atomically: true, encoding: String.Encoding.utf8))
        != nil
      {
        Logger.info("✅ Integrated summary saved: \(outPath)")
      } else {
        Logger.warn("⚠️ Failed to save integrated summary")
      }
    } else {
      Logger.warn("⚠️ Integrated summary generation failed (empty result)")
    }
  }
}

// MARK: - Notes Bridge
class NotesBridge: NSObject {
  static let shared = NotesBridge()
  private override init() { super.init() }

  private func executeAppleScript(_ script: String, timeout: TimeInterval = 30) -> String? {
    // 使用 osascript 命令行，比 NSAppleScript 快 700 倍！
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
      try task.run()

      // 使用超时机制，防止 AppleScript 挂起
      let deadline = Date().addingTimeInterval(timeout)
      while task.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
      }

      if task.isRunning {
        task.terminate()
        Logger.warn("⚠️  AppleScript timeout after \(Int(timeout))s, killed")
        return nil
      }

      let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
      let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)

      if task.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
          Logger.debug("AppleScript Error: \(err)")
        }
        return nil
      }

      return out
    } catch {
      Logger.debug("Failed to run osascript: \(error)")
      return nil
    }
  }

  private func escape(_ string: String) -> String {
    let bs = String(Character(UnicodeScalar(92)!))
    let qt = String(Character(UnicodeScalar(34)!))
    return string.replacingOccurrences(of: bs, with: bs + bs).replacingOccurrences(
      of: qt, with: bs + qt)
  }

  /// Convert Markdown to HTML using pandoc
  private func convertMarkdownToHTML(_ markdown: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pandoc")
    // --strip-empty-paragraphs removes empty paragraphs
    // Output is single-line HTML (no newlines) for AppleScript compatibility
    task.arguments = ["--from=markdown", "--to=html", "--wrap=none"]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    task.standardInput = inputPipe
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    do {
      try task.run()

      // Write markdown to stdin
      if let data = markdown.data(using: .utf8) {
        inputPipe.fileHandleForWriting.write(data)
      }
      try inputPipe.fileHandleForWriting.close()

      task.waitUntilExit()

      if task.terminationStatus == 0 {
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let html = String(data: outputData, encoding: .utf8) ?? markdown
        // Remove newlines for AppleScript compatibility
        return html.replacingOccurrences(of: "\n", with: "").replacingOccurrences(
          of: "\r", with: "")
      } else {
        Logger.warn("⚠️  Pandoc conversion failed, using raw content")
        return markdown
      }
    } catch {
      Logger.warn("⚠️  Failed to run pandoc: \(error), using raw content")
      return markdown
    }
  }

  /// List notes in a specific folder (much faster than filtering all notes)
  func listNotesInFolder(folderName: String) -> [(
    id: String, name: String, path: String, modDate: Date?
  )] {
    Logger.info("⏳ Fetching notes from folder '\(folderName)'...")
    let script = """
      tell application "Notes"
          if (count of accounts) = 0 then return ""
          set targetAccount to first account
          try
              set targetFolder to folder "\(folderName)" of targetAccount
              set noteList to every note in targetFolder
              set resultList to {}
              repeat with n in noteList
                  set nid to id of n
                  set nname to name of n
                  set d to modification date of n
                  set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)
                  set end of resultList to nid & "|||" & nname & "|||" & "\(folderName)" & "|||" & dStr
              end repeat
              set AppleScript's text item delimiters to "###"
              return resultList as string
          on error err
              return "Error: " & err
          end try
      end tell
      """
    guard let out = executeAppleScript(script, timeout: 30), !out.isEmpty else { return [] }
    if out.starts(with: "Error:") {
      Logger.debug(out)
      return []
    }

    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    let results = out.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap { item in
      let p = item.components(separatedBy: "|||")
      return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
    }

    Logger.info("✅ Fetched \(results.count) notes from '\(folderName)'")
    return results
  }

  func listAllNotesSafe() -> [(id: String, name: String, path: String, modDate: Date?)] {
    Logger.info("⏳ Fetching all notes from Apple Notes...")
    // 优化方案：分两步执行
    // 1. 先构建文件夹 ID→路径 映射表（只遍历文件夹一次）
    // 2. 再获取所有笔记，直接查映射表（不再递归）
    let script = """
      tell application "Notes"
          if (count of accounts) = 0 then return ""
          set targetAccount to first account
          try
              -- Step 1: Build folder ID -> path mapping
              set folderMap to {}
              set allFolders to every folder of targetAccount
              repeat with aFolder in allFolders
                  set folderId to id of aFolder
                  set currentFolder to aFolder
                  set folderPath to name of currentFolder
                  repeat while container of currentFolder is not missing value
                      set parentContainer to container of currentFolder
                      if class of parentContainer is folder then
                          set folderPath to (name of parentContainer) & "/" & folderPath
                          set currentFolder to parentContainer
                      else
                          exit repeat
                      end if
                  end repeat
                  set end of folderMap to folderId & ":::" & folderPath
              end repeat

              -- Step 2: Get all notes and lookup folder path from map
              set allNotes to every note of targetAccount
              set resultList to {}
              repeat with n in allNotes
                  set nid to id of n
                  set nname to name of n
                  set d to modification date of n
                  set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)

                  set noteContainer to container of n
                  set containerId to id of noteContainer
                  set folderPath to "Unknown"

                  -- Lookup folder path from map (O(1) instead of recursive traversal)
                  repeat with mapEntry in folderMap
                      if mapEntry starts with containerId then
                          set folderPath to text ((offset of ":::" in mapEntry) + 3) thru -1 of mapEntry
                          exit repeat
                      end if
                  end repeat

                  set end of resultList to nid & "|||" & nname & "|||" & folderPath & "|||" & dStr
              end repeat
              set AppleScript's text item delimiters to "###"
              return resultList as string
          on error err
              return "Error: " & err
          end try
      end tell
      """
    guard let out = executeAppleScript(script, timeout: 180), !out.isEmpty else { return [] }
    if out.starts(with: "Error:") {
      Logger.debug(out)
      return []
    }

    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    let results = out.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap { item in
      let p = item.components(separatedBy: "|||")
      return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
    }

    Logger.info("✅ Fetched \(results.count) notes")
    return results
  }

  // Deprecated: Slow version that iterates one by one
  func listAllNotesSafe_Deprecated() -> [(id: String, name: String, path: String, modDate: Date?)] {
    guard let countStr = executeAppleScript("tell application \"Notes\" to count of notes"),
      let total = Int(countStr)
    else { return [] }

    var results: [(String, String, String, Date?)] = []
    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    let startTime = Date()

    for i in 1...total {
      let percent = Int((Double(i) / Double(total)) * 100)
      Logger.info("   [\(i)/\(total) (\(percent)%)] Scanning...")
      let script = """
        tell application \"Notes\"
            try
                set n to note \(i)
                set nid to id of n
                set nname to name of n
                set d to modification date of n
                set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)

                set folderPath to \"Root\"
                try
                    set folderPath to name of container of n
                    set currentFolder to container of n
                    repeat while container of currentFolder is not missing value
                        set parentContainer to container of currentFolder
                        if class of parentContainer is folder then
                            set folderPath to (name of parentContainer) & "/" & folderPath
                            set currentFolder to parentContainer
                        else
                            exit repeat
                        end if
                    end repeat
                end try

                return nid & \"|||\" & nname & \"|||\" & folderPath & \"|||\" & dStr
            on error
                return ""
            end try
        end tell
        """
      if let out = executeAppleScript(script), !out.isEmpty {
        let p = out.components(separatedBy: "|||")
        if p.count >= 4 {
          results.append((p[0], p[1], p[2], f.date(from: p[3])))
        }
      }
    }
    Logger.info("✅ Scan complete: \(results.count) notes")
    return results
  }

  func listRecentlyModified(since date: Date) -> [(
    id: String, name: String, path: String, modDate: Date?
  )] {
    let c = Calendar.current
    let script = """
      tell application \"Notes\"
          set targetDate to current date
          set year of targetDate to \(c.component(.year, from: date))
          set month of targetDate to \(c.component(.month, from: date))
          set day of targetDate to \(c.component(.day, from: date))
          set hours of targetDate to \(c.component(.hour, from: date))
          set minutes of targetDate to \(c.component(.minute, from: date))
          set seconds of targetDate to \(c.component(.second, from: date))
          if (count of accounts) = 0 then return ""
          set targetAccount to first account
          try
              set recentNotes to every note of targetAccount whose modification date > targetDate
              set resultList to {}
              repeat with n in recentNotes
                  set nid to id of n
                  set nname to name of n
                  set d to modification date of n
                  set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)

                  set currentFolder to container of n
                  set folderPath to name of currentFolder
                  repeat while container of currentFolder is not missing value
                      set parentContainer to container of currentFolder
                      if class of parentContainer is folder then
                          set folderPath to (name of parentContainer) & "/" & folderPath
                          set currentFolder to parentContainer
                      else
                          exit repeat
                      end if
                  end repeat
                  set end of resultList to nid & \"|||\" & nname & \"|||\" & folderPath & \"|||\" & dStr
              end repeat
              set AppleScript's text item delimiters to "###"
              return resultList as string
          on error err
              return "Error: " & err
          end try
      end tell
      """
    guard let out = executeAppleScript(script, timeout: 120), !out.isEmpty else { return [] }
    if out.starts(with: "Error:") {
      Logger.debug(out)
      return []
    }

    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    return out.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap { item in
      let p = item.components(separatedBy: "|||")
      return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
    }
  }

  func listFoldersWithIds() -> [(id: String, path: String)] {
    let script = """
      tell application \"Notes\"
          set allFolders to every folder
          set resultList to {}
          repeat with aFolder in allFolders
              set currentFolder to aFolder
              set folderPath to name of currentFolder
              set folderId to id of aFolder
              try
                  repeat while container of currentFolder is not missing value
                      set parentContainer to container of currentFolder
                      if class of parentContainer is folder then
                          set folderPath to (name of parentContainer) & "/" & folderPath
                          set currentFolder to parentContainer
                      else
                          exit repeat
                      end if
                  end repeat
              end try
              set end of resultList to folderId & \"|||\" & folderPath
          end repeat
          set AppleScript's text item delimiters to "###"
          return resultList as string
      end tell
      """
    guard let output = executeAppleScript(script) else { return [] }
    return output.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap {
      let p = $0.components(separatedBy: "|||")
      return p.count >= 2 ? (p[0], p[1]) : nil
    }
  }

  func listNotesMetadata(inFolderId folderId: String) -> [(name: String, modDate: Date?)] {
    let script = """
      tell application \"Notes\"
          try
              set targetFolder to folder id \"\(folderId)\"
              set noteList to every note in targetFolder
              set resultList to {}
              repeat with n in noteList
                  set d to modification date of n
                  set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)
                  set end of resultList to (name of n) & \"|||\" & dStr
              end repeat
              set AppleScript's text item delimiters to "###"
              return resultList as string
          on error
              return ""
          end try
      end tell
      """
    guard let output = executeAppleScript(script) else { return [] }
    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    return output.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap {
      let p = $0.components(separatedBy: "|||")
      return p.count >= 2 ? (p[0], f.date(from: p[1])) : nil
    }
  }

  /// Search notes by keyword using native AppleScript filter (fast)
  func searchNotes(keyword: String, folderId: String? = nil) -> [(
    id: String, name: String, path: String, modDate: Date?
  )] {
    let escapedKeyword = escape(keyword)
    let script: String
    if let fid = folderId {
      script = """
        tell application \"Notes\"
            try
                set targetFolder to folder id \"\(fid)\"
                set matchingNotes to every note in targetFolder whose name contains \"\(escapedKeyword)\"
                set resultList to {}
                repeat with n in matchingNotes
                    set nid to id of n
                    set nname to name of n
                    set d to modification date of n
                    set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)
                    set end of resultList to nid & \"|||\" & nname & \"|||\" & \"\(fid)\" & \"|||\" & dStr
                end repeat
                set AppleScript's text item delimiters to "###"
                return resultList as string
            on error
                return ""
            end try
        end tell
        """
    } else {
      script = """
        tell application \"Notes\"
            try
                set matchingNotes to every note whose name contains \"\(escapedKeyword)\"
                set resultList to {}
                repeat with n in matchingNotes
                    set nid to id of n
                    set nname to name of n
                    set d to modification date of n
                    set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)

                    set folderPath to "Unknown"
                    try
                        set currentFolder to container of n
                        set folderPath to name of currentFolder
                    end try

                    set end of resultList to nid & \"|||\" & nname & \"|||\" & folderPath & \"|||\" & dStr
                end repeat
                set AppleScript's text item delimiters to "###"
                return resultList as string
            on error
                return ""
            end try
        end tell
        """
    }
    guard let out = executeAppleScript(script, timeout: 30), !out.isEmpty else { return [] }
    let f = DateFormatter()
    f.dateFormat = "yyyy-M-d H:m:s"
    return out.components(separatedBy: "###").filter { !$0.isEmpty }.compactMap { item in
      let p = item.components(separatedBy: "|||")
      return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
    }
  }

  func readNote(id: String) -> String? {
    executeAppleScript(
      "tell application \"Notes\" to get plaintext of note id \"\(id)\"", timeout: 5)
  }
  func readNote(name: String, fromFolderId folderId: String) -> String? {
    let escName = escape(name)
    return executeAppleScript(
      "tell application \"Notes\" to get plaintext of first note in folder id \"\(folderId)\" whose name is \"\(escName)\"",
      timeout: 5)
  }

  func createNote(name: String, folderId: String, content: String) -> String {
    let escName = escape(name)
    // Convert Markdown to HTML using pandoc
    let htmlContent = convertMarkdownToHTML(content)
    let escContent = escape(htmlContent)
    let script = """
      tell application \"Notes\"
          try
              set targetFolder to folder id \"\(folderId)\"
              make new note at targetFolder with properties {name:\"\(escName)\", body:\"\(escContent)\"}
              return \"success\"
          on error err
              return \"Error: \" & err
          end try
      end tell
      """
    return executeAppleScript(script) ?? "Error: Script failed"
  }

  func appendToNote(name: String, folderId: String, content: String) -> String {
    let escName = escape(name)
    // Convert Markdown to HTML using pandoc
    let htmlContent = convertMarkdownToHTML(content)
    let escContent = escape(htmlContent)
    let script = """
      tell application \"Notes\"
          try
              set theNote to first note in folder id \"\(folderId)\" whose name is \"\(escName)\"
              set body of theNote to (body of theNote) & "<br>" & \"\(escContent)\"
              return \"success\"
          on error err
              return \"Error: \" & err
          end try
      end tell
      """
    return executeAppleScript(script) ?? "Error: Script failed"
  }

  func updateNote(name: String, folderId: String, content: String) -> String {
    let escName = escape(name)
    // Convert Markdown to HTML using pandoc
    let htmlContent = convertMarkdownToHTML(content)
    let escContent = escape(htmlContent)
    let script = """
      tell application \"Notes\"
          try
              set theNote to first note in folder id \"\(folderId)\" whose name is \"\(escName)\"
              set body of theNote to \"\(escContent)\"
              return \"success\"
          on error err
              return \"Error: \" & err
          end try
      end tell
      """
    return executeAppleScript(script) ?? "Error: Script failed"
  }

  func deleteNote(name: String, folderId: String) -> String {
    let escName = escape(name)
    let script = """
      tell application \"Notes\"
          try
              delete (first note in folder id \"\(folderId)\" whose name is \"\(escName)\")
              return \"success\"
          on error err
              return \"Error: \" & err
          end try
      end tell
      """
    return executeAppleScript(script) ?? "Error: Script failed"
  }

  func moveNote(name: String, fromFolderId: String, toFolderId: String) -> String {
    let escName = escape(name)
    let script = """
      tell application \"Notes\"
          try
              set sourceFolder to folder id \"\(fromFolderId)\"
              set targetFolder to folder id \"\(toFolderId)\"
              set theNote to first note in sourceFolder whose name is \"\(escName)\"
              move theNote to end of notes of targetFolder
              return \"success\"
          on error err
              return \"Error: \" & err
          end try
      end tell
      """
    return executeAppleScript(script) ?? "Error: Script failed"
  }
}

// MARK: - Time Parsing Helper
/// Parse relative time expressions like "4 hours ago", "-2h", "yesterday" into Date
/// - Parameter expression: Time expression to parse
/// - Returns: Date representing the parsed time, or nil if parsing failed
func parseRelativeTime(_ expression: String) -> Date? {
  let now = Date()
  let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

  // Handle "X ago" format
  if trimmed.hasSuffix("ago") {
    let parts = trimmed.dropLast(4).trimmingCharacters(in: .whitespaces)
    return parseTimeOffset(parts, now: now)
  }

  // Handle "-X" format (negative offset)
  if trimmed.hasPrefix("-") {
    let offset = String(trimmed.dropFirst())
    return parseTimeOffset(offset, now: now)
  }

  // Handle absolute date formats (before bare offset to avoid treating "2026-03-14" as offset)
  let dateFormatter = DateFormatter()
  dateFormatter.locale = Locale(identifier: "en_US_POSIX")

  // Try "YYYY-MM-DD HH:mm" format
  dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
  if let date = dateFormatter.date(from: expression) {
    return date
  }

  // Try "YYYY-MM-DD" format
  dateFormatter.dateFormat = "yyyy-MM-dd"
  if let date = dateFormatter.date(from: expression) {
    return date
  }

  // Handle bare offset format like "30m", "2h", "1d" (assume past)
  // Check if it starts with a number (but not a raw Unix timestamp > 1000000000)
  if let firstChar = trimmed.first, firstChar.isNumber {
    // Check if this might be a Unix timestamp (10+ digits)
    if trimmed.count < 10 {
      if let result = parseTimeOffset(trimmed, now: now) {
        return result
      }
    }
  }

  // Handle "yesterday"
  if trimmed == "yesterday" {
    return Calendar.current.date(byAdding: .day, value: -1, to: now)
  }

  // Handle "today"
  if trimmed == "today" {
    return Calendar.current.startOfDay(for: now)
  }

  // Try raw Unix timestamp
  if let timestamp = TimeInterval(trimmed) {
    return Date(timeIntervalSince1970: timestamp)
  }

  return nil
}

/// Parse time offset like "2h", "30m", "1d" into a Date
private func parseTimeOffset(_ offset: String, now: Date) -> Date? {
  let cal = Calendar.current
  let trimmed = offset.trimmingCharacters(in: .whitespaces)

  // Match patterns like "2h", "30m", "1d", "4 hours", "30 minutes"
  if trimmed.isEmpty { return nil }

  // Extract number and unit
  var numberStr = ""
  var unitStr = ""

  var i = trimmed.startIndex
  while i < trimmed.endIndex {
    let c = trimmed[i]
    if c.isNumber || c == "." {
      numberStr.append(c)
    } else {
      unitStr = String(trimmed[i...])
      break
    }
    i = trimmed.index(after: i)
  }

  guard let value = Double(numberStr) else { return nil }

  // Parse unit
  let unit = unitStr.trimmingCharacters(in: .whitespaces)
  let unitChar = unit.isEmpty ? "" : String(unit.prefix(1))

  switch unitChar {
  case "s", "second", "seconds":
    return cal.date(byAdding: .second, value: -Int(value), to: now)
  case "m", "minute", "minutes":
    return cal.date(byAdding: .minute, value: -Int(value), to: now)
  case "h", "hour", "hours":
    return cal.date(byAdding: .hour, value: -Int(value), to: now)
  case "d", "day", "days":
    return cal.date(byAdding: .day, value: -Int(value), to: now)
  case "w", "week", "weeks":
    return cal.date(byAdding: .day, value: -Int(value * 7), to: now)
  default:
    // If no unit specified, assume hours (common case)
    return cal.date(byAdding: .hour, value: -Int(value), to: now)
  }
}

// MARK: - Notes Tool
class NotesTool {
  let bridge = NotesBridge.shared
  let fm = FileManager.default

  func sync(targetDir: String, folderFilter: String? = nil, since: String? = nil) {
    if let filter = folderFilter {
      Logger.info("🧠 Smart Sync to: \(targetDir) (folder: \(filter))")
    } else {
      Logger.info("🧠 Smart Sync to: \(targetDir)")
    }
    try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
    let timeFile = (targetDir as NSString).appendingPathComponent(".last_sync_time")
    var lastSync = Date(timeIntervalSince1970: 0)
    var hasHistory = fm.fileExists(atPath: timeFile)

    if hasHistory, let ts = try? String(contentsOfFile: timeFile, encoding: .utf8),
      let t = TimeInterval(ts.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      lastSync = Date(timeIntervalSince1970: t)
    }

    // Override lastSync if --since parameter is provided
    var customSince: Date?
    if let sinceExpr = since {
      if let parsedDate = parseRelativeTime(sinceExpr) {
        customSince = parsedDate
        Logger.info("⏰ Using custom time: \(parsedDate) (from: \(sinceExpr))")
      } else {
        Logger.error("❌ Failed to parse time expression: \(sinceExpr)")
        Logger.error(
          "   Supported formats: \"4 hours ago\", \"-2h\", \"2026-03-14 12:00\", \"yesterday\"")
        return
      }
    }

    var notes: [(id: String, name: String, path: String, modDate: Date?)]

    // Use customSince if provided, otherwise use file-based lastSync
    if let filter = folderFilter {
      // Fast path: directly query folder in AppleScript (avoid fetching all notes)
      Logger.info("📁 Fast path: querying folder '\(filter)' directly...")
      notes = bridge.listNotesInFolder(folderName: filter)
    } else if let custom = customSince {
      // Custom time override
      hasHistory = true  // Treat as incremental sync
      let checkDate = custom.addingTimeInterval(-60)
      Logger.info("🚀 Custom incremental check since: \(checkDate)")
      notes = bridge.listRecentlyModified(since: checkDate)
    } else if !hasHistory {
      // First run: use folder-by-folder approach to avoid timeout
      Logger.info("🐢 First run detected. Syncing folder-by-folder...")
      let folders = bridge.listFoldersWithIds()
      Logger.info("📂 Found \(folders.count) folders")

      var allNotes: [(id: String, name: String, path: String, modDate: Date?)] = []
      for (fid, folderPath) in folders {
        if folderPath.isEmpty { continue }
        // Skip system folders
        if ["Recently Deleted", "Quick Notes"].contains(folderPath) { continue }

        Logger.info("  📁 Syncing folder: \(folderPath)")
        let folderNotes = bridge.listNotesInFolder(folderName: folderPath)
        allNotes.append(contentsOf: folderNotes)
      }
      notes = allNotes
      Logger.info("✅ Total: \(notes.count) notes from all folders")
    } else {
      let checkDate = lastSync.addingTimeInterval(-60)
      Logger.info("🚀 Incremental check since: \(checkDate)")
      notes = bridge.listRecentlyModified(since: checkDate)
    }

    if !notes.isEmpty {
      Logger.info("⚡️ Syncing \(notes.count) notes...")
      var skipped = 0
      for (nid, name, folderPath, _) in notes {
        let folderName = folderPath.isEmpty ? "Unknown" : folderPath
        let fullFolderPath = (targetDir as NSString).appendingPathComponent(folderName)
        try? fm.createDirectory(atPath: fullFolderPath, withIntermediateDirectories: true)

        // Use Short ID in filename to prevent collisions
        let shortId = String(nid.suffix(8)).replacingOccurrences(of: "/", with: "-")
        let safeName = name.replacingOccurrences(of: "/", with: ":")
        let filename = "\(safeName) [\(shortId)].md"
        let filePath = (fullFolderPath as NSString).appendingPathComponent(filename)

        if fm.fileExists(atPath: filePath) {
          try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filePath)
        }
        if let content = bridge.readNote(id: nid) {
          try? content.write(toFile: filePath, atomically: true, encoding: String.Encoding.utf8)
          try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: filePath)
          Logger.info("  ⬇️ [\(folderName)] \(name)")
        } else {
          skipped += 1
          Logger.warn("  ⏭️ [\(folderName)] \(name) (timeout/error, skipped)")
        }
      }
      if skipped > 0 {
        Logger.info("⚠️  Skipped \(skipped) notes due to timeout")
      }
    } else {
      Logger.info("✅ Up to date.")
    }
    // Only update sync time if no folder filter (full sync)
    if folderFilter == nil {
      try? String(Date().timeIntervalSince1970).write(
        toFile: timeFile, atomically: true, encoding: String.Encoding.utf8)
    }
  }

  func findFolderId(path: String) -> String? {
    let folders = bridge.listFoldersWithIds()
    return folders.first(where: { $0.path == path })?.id
      ?? folders.first(where: { $0.path.hasSuffix(path) })?.id
  }

  /// Find note name with fuzzy matching support
  /// Returns (exactName, shouldProceed) - exactName is the matched note name, shouldProceed indicates if operation should continue
  func findNoteWithFuzzyMatch(title: String, folderId: String) -> (
    exactName: String?, message: String?
  ) {
    // First, get all notes in the folder
    let notes = bridge.listNotesMetadata(inFolderId: folderId)

    // Check for exact match first
    if notes.contains(where: { $0.name == title }) {
      return (title, nil)
    }

    // Try fuzzy match (case-insensitive partial match)
    let matches = notes.filter { $0.name.localizedCaseInsensitiveContains(title) }

    if matches.isEmpty {
      return (nil, "❌ Note not found: '\(title)'")
    } else if matches.count == 1 {
      // Single match - use it
      let matchedName = matches[0].name
      Logger.info("🔍 Fuzzy matched: '\(title)' → '\(matchedName)'")
      return (matchedName, nil)
    } else {
      // Multiple matches - show suggestions
      var msg = "⚠️  Multiple notes match '\(title)':\n"
      for (i, (name, _)) in matches.enumerated() {
        msg += "   \(i + 1). \(name)\n"
      }
      msg += "Please use the exact note name."
      return (nil, msg)
    }
  }

  func create(targetDir: String, folder: String, title: String, content: String) {
    guard let fid = findFolderId(path: folder) else {
      Logger.error("Folder not found: \(folder)")
      return
    }
    let res = bridge.createNote(name: title, folderId: fid, content: content)
    if res == "success" {
      Logger.info("✅ Created.")
      sync(targetDir: targetDir)
    } else {
      Logger.error("Failed: \(res)")
    }
  }
  func append(targetDir: String, folder: String, title: String, content: String) {
    guard let fid = findFolderId(path: folder) else {
      Logger.error("Folder not found: \(folder)")
      return
    }

    // Try fuzzy matching for note title
    let (exactTitle, errorMsg) = findNoteWithFuzzyMatch(title: title, folderId: fid)
    guard let actualTitle = exactTitle else {
      if let msg = errorMsg { print(msg) }
      return
    }

    let res = bridge.appendToNote(name: actualTitle, folderId: fid, content: content)
    if res == "success" {
      Logger.info("✅ Appended to '\(actualTitle)'.")
      sync(targetDir: targetDir)
    } else {
      Logger.error("Failed: \(res)")
    }
  }
  func update(targetDir: String, folder: String, title: String, content: String) {
    guard let fid = findFolderId(path: folder) else {
      Logger.error("Folder not found: \(folder)")
      return
    }

    // Try fuzzy matching for note title
    let (exactTitle, errorMsg) = findNoteWithFuzzyMatch(title: title, folderId: fid)
    guard let actualTitle = exactTitle else {
      if let msg = errorMsg { print(msg) }
      return
    }

    let res = bridge.updateNote(name: actualTitle, folderId: fid, content: content)
    if res == "success" {
      Logger.info("✅ Updated '\(actualTitle)'.")
      sync(targetDir: targetDir)
    } else {
      Logger.error("Failed: \(res)")
    }
  }
  func delete(targetDir: String, folder: String, title: String) {
    guard let fid = findFolderId(path: folder) else {
      Logger.error("Folder not found: \(folder)")
      return
    }

    // Try fuzzy matching for note title
    let (exactTitle, errorMsg) = findNoteWithFuzzyMatch(title: title, folderId: fid)
    guard let actualTitle = exactTitle else {
      if let msg = errorMsg { print(msg) }
      return
    }

    let res = bridge.deleteNote(name: actualTitle, folderId: fid)
    if res == "success" {
      Logger.info("✅ Deleted '\(actualTitle)'.")
      let safeName = actualTitle.replacingOccurrences(of: "/", with: ":")
      let localPath = (targetDir as NSString).appendingPathComponent(folder).appending(
        "/\(safeName).md")
      if fm.fileExists(atPath: localPath) {
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localPath)
        try? fm.removeItem(atPath: localPath)
      }
    } else {
      Logger.error("Failed: \(res)")
    }
  }
  func move(targetDir: String, sourceFolder: String, title: String, targetFolder: String) {
    guard let sourceId = findFolderId(path: sourceFolder) else {
      Logger.error("Source folder not found: \(sourceFolder)")
      return
    }
    guard let targetId = findFolderId(path: targetFolder) else {
      Logger.error("Target folder not found: \(targetFolder)")
      return
    }

    // Try fuzzy matching for note title
    let (exactTitle, errorMsg) = findNoteWithFuzzyMatch(title: title, folderId: sourceId)
    guard let actualTitle = exactTitle else {
      if let msg = errorMsg { print(msg) }
      return
    }

    let res = bridge.moveNote(name: actualTitle, fromFolderId: sourceId, toFolderId: targetId)
    if res == "success" {
      Logger.info("✅ Moved note '\(actualTitle)' from '\(sourceFolder)' to '\(targetFolder)'")
      // Remove old file from source folder (local mirror cleanup)
      // Note: filename includes short ID suffix, so we need to find by prefix
      let safeName = actualTitle.replacingOccurrences(of: "/", with: ":")
      let sourceDirPath = (targetDir as NSString).appendingPathComponent(sourceFolder)
      if let enumerator = fm.enumerator(atPath: sourceDirPath) {
        for case let file as String in enumerator {
          if file.hasPrefix("\(safeName) [") && file.hasSuffix("].md") {
            let fullPath = sourceDirPath + "/" + file
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fullPath)
            try? fm.removeItem(atPath: fullPath)
            Logger.debug("  🗑️ Removed old file: \(file)")
            break
          }
        }
      }
      sync(targetDir: targetDir)
    } else {
      Logger.error("Failed: \(res)")
    }
  }

  /// List notes in a specific folder
  func list(folder: String, json: Bool = false) {
    guard let folderId = findFolderId(path: folder) else {
      Logger.error("Folder not found: \(folder)")
      return
    }

    let notes = bridge.listNotesMetadata(inFolderId: folderId)
    if notes.isEmpty {
      Logger.info("No notes found in folder: \(folder)")
      return
    }

    if json {
      let f = ISO8601DateFormatter()
      let dicts = notes.map { (name, modDate) -> [String: Any] in
        return [
          "name": name,
          "modificationDate": modDate != nil ? f.string(from: modDate!) : NSNull(),
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted]),
        let output = String(data: data, encoding: .utf8)
      {
        print(output)
      }
    } else {
      print("📁 \(folder) (\(notes.count) notes)")
      print("---")
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd HH:mm"
      for (name, modDate) in notes {
        let dateStr = modDate != nil ? f.string(from: modDate!) : "Unknown"
        print("  \(name) [\(dateStr)]")
      }
    }
  }

  /// Search notes by keyword (uses native AppleScript filter for speed)
  func search(keyword: String, folder: String? = nil, json: Bool = false) {
    Logger.info("🔍 Searching for: \(keyword)")

    // Get folder ID if folder filter specified
    let folderId = folder != nil ? findFolderId(path: folder!) : nil

    // Use native AppleScript search (fast, 30s timeout)
    let matches = bridge.searchNotes(keyword: keyword, folderId: folderId)

    if matches.isEmpty {
      Logger.info("No notes found matching: \(keyword)")
      return
    }

    if json {
      let f = ISO8601DateFormatter()
      let dicts = matches.map { (id, name, path, modDate) -> [String: Any] in
        return [
          "id": id,
          "name": name,
          "folder": path,
          "modificationDate": modDate != nil ? f.string(from: modDate!) : NSNull(),
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted]),
        let output = String(data: data, encoding: .utf8)
      {
        print(output)
      }
    } else {
      print("🔍 Found \(matches.count) note(s) matching '\(keyword)'")
      print("---")
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd HH:mm"
      for (id, name, path, modDate) in matches {
        let dateStr = modDate != nil ? f.string(from: modDate!) : "Unknown"
        let shortId = String(id.suffix(8))
        print("  📄 \(name)")
        print("     Folder: \(path)")
        print("     Modified: \(dateStr) [\(shortId)]")
      }
    }
  }
}

// MARK: - Reminders Tool
class RemindersTool {
  let store = EKEventStore()
  func checkPermission() async -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    Logger.debug("Reminder Auth Status: \(status.rawValue)")
    if status == .authorized { return true }
    if status == .notDetermined { return (try? await store.requestAccess(to: .reminder)) ?? false }
    return false
  }
  func listTasks(json: Bool = false) async {
    guard await checkPermission() else {
      Logger.error("Permission denied")
      return
    }
    let predicate = store.predicateForReminders(in: nil)
    let items = await withCheckedContinuation { c in
      store.fetchReminders(matching: predicate) { r in c.resume(returning: r) }
    }
    guard let reminders = items else { return }
    let incomplete = reminders.filter { !$0.isCompleted }
    if incomplete.isEmpty {
      Logger.info("No incomplete tasks found")
      return
    }
    if json {
      let f = ISO8601DateFormatter()
      let dicts = incomplete.map { r -> [String: Any] in
        var d: String? = nil
        if let date = r.dueDateComponents?.date { d = f.string(from: date) }
        return [
          "id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar.title,
          "isCompleted": r.isCompleted, "priority": r.priority, "dueDate": d ?? NSNull(),
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) {
        print(String(data: data, encoding: .utf8)!)
      }
    } else {
      for t in incomplete { Logger.info("[\(t.calendar.title)] \(t.title ?? "")") }
    }
  }
  func newTask(title: String, due: String? = nil, priority: Int? = nil, notes: String? = nil) async
  {
    guard await checkPermission() else { return }
    let item = EKReminder(eventStore: store)
    item.title = title
    item.calendar = store.defaultCalendarForNewReminders()

    // 设置截止日期
    if let due = due {
      // 支持两种格式: "2026-12-31 23:59" 或 "2026-12-31T23:59"
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd HH:mm"
      formatter.locale = Locale(identifier: "en_US_POSIX")

      if let date = formatter.date(from: due) {
        let components = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute], from: date)
        item.dueDateComponents = components
      } else {
        // 尝试 ISO8601 格式
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: due) {
          let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
          item.dueDateComponents = components
        }
      }
    }

    // 设置优先级 (0-9)
    if let priority = priority, priority >= 0 && priority <= 9 {
      item.priority = priority
    }

    // 设置备注
    if let notes = notes {
      item.notes = notes
    }

    try? store.save(item, commit: true)
    Logger.info("✅ Created: \(title)")
    if let due = item.dueDateComponents?.date {
      Logger.info("   Due: \(ISO8601DateFormatter().string(from: due))")
    }
    if item.priority > 0 {
      Logger.info("   Priority: \(item.priority)")
    }
  }
  func completeTask(query: String, isId: Bool) async {
    guard await checkPermission() else { return }
    let items = await withCheckedContinuation { c in
      store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in
        c.resume(returning: r)
      }
    }
    let t = items?.first(where: {
      isId ? $0.calendarItemIdentifier == query : ($0.title == query && !$0.isCompleted)
    })
    if let t = t {
      t.isCompleted = true
      try? store.save(t, commit: true)
      Logger.info("✅ Completed")
    } else {
      Logger.error("Not found")
    }
  }
  func deleteTask(query: String, isId: Bool, dryRun: Bool) async {
    guard await checkPermission() else { return }
    let items = await withCheckedContinuation { c in
      store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in
        c.resume(returning: r)
      }
    }
    let t = items?.first(where: { isId ? $0.calendarItemIdentifier == query : $0.title == query })
    if let t = t {
      if dryRun {
        Logger.info("⚠️ Dry-Run: \(t.title ?? "")")
      } else {
        try? store.remove(t, commit: true)
        Logger.info("✅ Deleted")
      }
    } else {
      Logger.error("Not found")
    }
  }
}

// MARK: - Calendar Tool
class CalendarTool {
  let store = EKEventStore()
  func checkPermission() async -> Bool {
    Logger.debug("Checking Calendar Permission...")
    if #available(macOS 14.0, *) {
      if EKEventStore.authorizationStatus(for: .event) == .authorized { return true }
      return (try? await store.requestFullAccessToEvents()) ?? false
    } else {
      if EKEventStore.authorizationStatus(for: .event) == .authorized { return true }
      return (try? await store.requestAccess(to: .event)) ?? false
    }
  }
  func listEvents(json: Bool = false) async {
    guard await checkPermission() else {
      Logger.error("Calendar access denied")
      return
    }
    let start = Calendar.current.startOfDay(for: Date())
    let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
    let events = store.events(
      matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    if events.isEmpty {
      Logger.info("No events found in the next 7 days")
      return
    }
    if json {
      let f = ISO8601DateFormatter()
      let dicts = events.map { e -> [String: Any] in
        return [
          "id": e.eventIdentifier ?? "", "title": e.title ?? "",
          "start": f.string(from: e.startDate), "calendar": e.calendar.title,
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) {
        print(String(data: data, encoding: .utf8)!)
      }
    } else {
      let f = DateFormatter()
      f.dateFormat = "MM-dd HH:mm"
      for e in events { Logger.info("[\(e.calendar.title)] \(e.startDate) \(e.title ?? "")") }
    }
  }
  func newEvent(title: String, time: String) async {
    guard await checkPermission() else {
      Logger.error("Calendar access denied")
      return
    }
    let event = EKEvent(eventStore: store)
    event.title = title
    event.calendar = store.defaultCalendarForNewEvents
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    if let d = f.date(from: time) {
      event.startDate = d
      event.endDate = d.addingTimeInterval(3600)
      try? store.save(event, span: .thisEvent)
      Logger.info("✅ Created")
    } else {
      Logger.error("Invalid Time")
    }
  }
  func deleteEvent(title: String) async {
    guard await checkPermission() else {
      Logger.error("Calendar access denied")
      return
    }
    let start = Date()
    let end = Calendar.current.date(byAdding: .day, value: 30, to: start)!
    if let e = store.events(
      matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)
    ).first(where: { $0.title == title }) {
      try? store.remove(e, span: .thisEvent)
      Logger.info("✅ Deleted")
    } else {
      Logger.error("Not found")
    }
  }
}

// MARK: - Contacts Tool
class ContactsTool {
  let store = CNContactStore()
  func checkPermission() async -> Bool {
    if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
    return (try? await store.requestAccess(for: .contacts)) ?? false
  }
  func search(query: String, json: Bool = false) async {
    guard await checkPermission() else { return }
    let keys =
      [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactOrganizationNameKey,
      ] as [CNKeyDescriptor]
    let req = CNContactFetchRequest(keysToFetch: keys)
    req.predicate = CNContact.predicateForContacts(matchingName: query)
    var results: [[String: Any]] = []
    try? store.enumerateContacts(with: req) { c, _ in
      results.append([
        "id": c.identifier, "name": "\(c.givenName) \(c.familyName)",
        "phones": c.phoneNumbers.map { $0.value.stringValue },
        "emails": c.emailAddresses.map { $0.value as String },
      ])
    }
    if json {
      if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) {
        print(String(data: data, encoding: .utf8)!)
      }
    } else {
      for c in results { Logger.info("👤 \(c["name"] ?? "")") }
    }
  }
}

// MARK: - Photo Tool
struct PhotoAsset {
  let id: String
  let creationDate: Date
  let pixelWidth: Int
  let pixelHeight: Int
  let isFavorite: Bool
}

class PhotoTool {
  func checkPermission() async -> Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    Logger.debug("Photo Auth Status: \(status.rawValue)")
    if status == .authorized || status == .limited { return true }
    if status == .denied || status == .restricted {
      Logger.error("Photo Access Denied. Please enable in System Settings.")
      return false
    }
    return await withCheckedContinuation { c in
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
        c.resume(returning: s == .authorized || s == .limited)
      }
    }
  }

  private func fetchAssets(count: Int, screenshots: Bool, favorites: Bool) async -> [PhotoAsset] {
    guard await checkPermission() else { return [] }
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.fetchLimit = count
    var predicates: [NSPredicate] = []
    if screenshots {
      predicates.append(
        NSPredicate(
          format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
    }
    if favorites { predicates.append(NSPredicate(format: "isFavorite == YES")) }
    if !predicates.isEmpty {
      options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
    let assets = PHAsset.fetchAssets(with: .image, options: options)
    var results: [PhotoAsset] = []
    assets.enumerateObjects { asset, _, _ in
      results.append(
        PhotoAsset(
          id: asset.localIdentifier, creationDate: asset.creationDate ?? Date(),
          pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, isFavorite: asset.isFavorite
        ))
    }
    return results
  }

  func listRecent(
    count: Int = 10, screenshots: Bool = false, favorites: Bool = false, json: Bool = false
  ) async {
    let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
    if json {
      let dicts = assets.map {
        [
          "id": $0.id, "date": ISO8601DateFormatter().string(from: $0.creationDate),
          "width": $0.pixelWidth, "height": $0.pixelHeight, "isFavorite": $0.isFavorite,
        ]
      }
      if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) {
        print(String(data: data, encoding: .utf8)!)
      }
    } else {
      for r in assets { Logger.info("🖼 ID: \(r.id)") }
    }
  }

  func batchOcr(count: Int, screenshots: Bool, favorites: Bool) async {
    let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
    if assets.isEmpty {
      Logger.info("No photos found.")
      return
    }
    Logger.info("🔄 Batch OCR for \(assets.count) images...")
    for asset in assets {
      Logger.info("\n📸 Photo: \(asset.id)")
      await ocr(assetId: asset.id)
    }
  }

  func ocr(assetId: String) async {
    guard await checkPermission() else { return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = assets.firstObject else {
      Logger.error("Photo not found")
      return
    }

    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
      data, _, _, _ in
      guard let data = data, let source = CGImageSourceCreateWithData(data as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        Logger.error("Failed to load image data")
        return
      }
      let request = VNRecognizeTextRequest { req, _ in
        guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
        print(obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
      }
      request.recognitionLanguages = ["zh-Hans", "en-US"]
      request.recognitionLevel = .accurate
      try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    }
  }
}

// MARK: - OCR from File Path
/// OCR directly from image file path (independent of Photos library)
func ocrFromPath(_ imagePath: String) async {
  let url = URL(fileURLWithPath: imagePath)

  // Check if file exists
  guard FileManager.default.fileExists(atPath: imagePath) else {
    Logger.error("❌ File not found: \(imagePath)")
    return
  }

  // Load image
  guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
  else {
    Logger.error("❌ Failed to load image: \(imagePath)")
    return
  }

  Logger.info("🔍 OCR processing: \(imagePath)")

  // Perform OCR
  await withCheckedContinuation { continuation in
    let request = VNRecognizeTextRequest { req, _ in
      guard let observations = req.results as? [VNRecognizedTextObservation] else {
        Logger.info("No text found in image")
        continuation.resume()
        return
      }

      let texts = observations.compactMap { $0.topCandidates(1).first?.string }
      if texts.isEmpty {
        Logger.info("No text found in image")
      } else {
        print(texts.joined(separator: "\n"))
      }
      continuation.resume()
    }

    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    do {
      try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    } catch {
      Logger.error("❌ OCR error: \(error)")
      continuation.resume()
    }
  }
}

// MARK: - Shortcuts Tool
class ShortcutsTool {
  func listShortcuts() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    p.arguments = ["list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
      let output = String(data: data, encoding: .utf8)
    {
      print(output)
    }
  }
  func runShortcut(name: String, input: String? = nil) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    var args = ["run", name]
    if let i = input { args.append(contentsOf: ["--input-text", i]) }
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
  }
}

// MARK: - Health Tool
// HealthKit removed: causes Signal 9 in CLI without App Bundle (issue #17)
// HealthKit requires an App Bundle with proper entitlements for TCC authorization.
// CLI binaries cannot receive user consent prompts from macOS.
class HealthTool {
  func requestAuthorization() {
    print("❌ HealthKit is not available in CLI mode")
    print("   HealthKit requires an App Bundle with proper entitlements.")
    print("   CLI binaries cannot receive TCC authorization prompts from macOS.")
    print("   Use iPhone/Apple Watch Health app or a native macOS app instead.")
  }
}
// MARK: - Shell Helper
class Shell {
  static func run(_ command: String, args: [String]) -> (
    output: String?, error: String?, exitCode: Int32
  ) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
      try task.run()
      task.waitUntilExit()
      let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
      let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      return (
        String(data: outData, encoding: .utf8), String(data: errData, encoding: .utf8),
        task.terminationStatus
      )
    } catch {
      return (nil, "Failed: \(error)", -1)
    }
  }
}

// MARK: - Models
struct FunASRSentence: Codable {
  let text: String
  let spk: Int?
  let start: Int?
  let end: Int?
}
struct FunASRItem: Codable {
  let key: String?
  let text: String?
  let sentence_info: [FunASRSentence]?
}

// MARK: - Timer Tool
class TimerTool {
  let launchAgentsDir =
    FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents"
  let logDir = IKitDir.timerActive  // 更新为使用 IKitDir

  /// 创建定时任务
  func create(
    time: String,
    date: String? = nil,
    weekday: Int? = nil,
    daily: Bool = false,
    open: [String] = [],
    with: String? = nil,
    run: String? = nil,
    thenRun: String? = nil,
    session: String? = nil,
    pwd: String? = nil,
    terminal: String = "Ghostty",
    title: String = "Timer",
    message: String? = nil
  ) {
    // 解析时间 (HH:MM)
    guard let (hour, minute) = parseTime(time) else {
      Logger.error("Invalid time format. Use HH:MM (00-23:00-59)")
      return
    }

    // 互斥检查：daily, date, weekday
    let optionCount = (daily ? 1 : 0) + (date != nil ? 1 : 0) + (weekday != nil ? 1 : 0)
    if optionCount > 1 {
      Logger.error("Only one of --daily, --date, or --weekday can be specified")
      return
    }

    // 解析日期（如果提供）
    var targetDate: Date?
    if let dateStr = date {
      targetDate = parseDate(dateStr)
      if targetDate == nil {
        Logger.error("Invalid date format. Use YYYY-MM-DD")
        return
      }
      // 验证日期不在过去
      if let td = targetDate, !validateDate(td) {
        Logger.error("Date must be today or in the future")
        return
      }
    }

    // 验证 weekday
    if let wd = weekday, wd < 0 || wd > 6 {
      Logger.error("Invalid weekday. Use 0-6 (0=Sun, 1=Mon, ..., 6=Sat)")
      return
    }

    // 验证文件存在性
    let missingFiles = validateFiles(open)
    if !missingFiles.isEmpty {
      Logger.error("Files not found:")
      for file in missingFiles {
        Logger.error("  - \(file)")
      }
      return
    }

    // 生成任务名称（改进版）
    let taskName: String
    if let sid = session {
      // Session resume 任务：使用 session ID 前缀
      let shortId = String(sid.prefix(12))
      taskName = "timer-session-\(shortId)-\(hour)\(String(format: "%02d", minute))"
    } else if daily {
      taskName = "timer-daily-\(hour)\(String(format: "%02d", minute))"
    } else if let wd = weekday {
      taskName = "timer-weekly-\(wd)-\(hour)\(String(format: "%02d", minute))"
    } else {
      // 一次性任务：默认为今天，或使用指定日期
      let date = targetDate ?? Date()
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd"
      taskName =
        "timer-once-\(formatter.string(from: date))-\(hour)\(String(format: "%02d", minute))"
    }

    let plistFilename = "com.user.\(taskName).plist"
    let plistPath = URL(fileURLWithPath: launchAgentsDir).appendingPathComponent(plistFilename).path

    // 设置日志
    setupLogging()

    // 转义特殊字符
    let safeTitle = escapeForAppleScript(title)
    let safeMessage = escapeForAppleScript(message ?? "⏰ Timer: \(title)")

    // 生成 AppleScript 内容
    let script = generateAppleScript(
      taskName: taskName,
      title: safeTitle,
      message: safeMessage,
      openFiles: open,
      openWith: with,
      runCommand: run,
      thenRunCommand: thenRun,
      terminal: terminal
    )

    // 生成 plist 内容
    let plistContent = generatePlist(
      taskName: taskName,
      hour: hour,
      minute: minute,
      day: targetDate.flatMap { Calendar.current.component(.day, from: $0) },
      month: targetDate.flatMap { Calendar.current.component(.month, from: $0) },
      year: targetDate.flatMap { Calendar.current.component(.year, from: $0) },
      weekday: weekday,
      isDaily: daily,
      script: script
    )

    // 确保 LaunchAgents 目录存在
    try? FileManager.default.createDirectory(
      atPath: launchAgentsDir, withIntermediateDirectories: true)

    // 写入 plist 文件
    do {
      try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
      Logger.info("✅ Created: \(plistPath)")
    } catch {
      Logger.error("Failed to write plist: \(error)")
      return
    }

    // 保存任务配置（供 execute 使用）
    var taskConfig: [String: Any] = [
      "taskName": taskName,
      "title": title,
      "message": message ?? (session != nil ? "🔄 Resume Session: \(title)" : "⏰ Timer: \(title)"),
      "openFiles": open,
      "openWith": with ?? "",
      "runCommand": run ?? "",
      "thenRunCommand": thenRun ?? "",
      "terminal": terminal,
      "createdAt": ISO8601DateFormatter().string(from: Date()),
    ]
    // 如果有 session ID，添加到配置
    if let sid = session {
      taskConfig["sessionId"] = sid
      // 添加 pwd 到配置（如果提供）
      if let pwd = pwd {
        taskConfig["pwd"] = pwd
      }
    }
    saveTaskConfig(taskName: taskName, config: taskConfig)

    // 记录创建日志
    log("Timer created: \(taskName)", for: taskName)
    if daily {
      log("Schedule: daily at \(hour):\(String(format: "%02d", minute))", for: taskName)
    } else if let wd = weekday {
      log(
        "Schedule: weekly on weekday \(wd) at \(hour):\(String(format: "%02d", minute))",
        for: taskName)
    } else if let td = targetDate {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      log(
        "Schedule: once on \(formatter.string(from: td)) at \(hour):\(String(format: "%02d", minute))",
        for: taskName)
    } else {
      log("Schedule: today at \(hour):\(String(format: "%02d", minute))", for: taskName)
    }

    // 加载任务
    loadTask(plistPath)
  }

  /// 列出所有定时任务
  func list() {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: launchAgentsDir) else {
      Logger.info("No timers found (LaunchAgents directory: \(launchAgentsDir))")
      return
    }

    let timerFiles = files.filter { $0.hasPrefix("com.user.timer-") && $0.hasSuffix(".plist") }

    if timerFiles.isEmpty {
      Logger.info("No timers found")
      return
    }

    Logger.info("Active timers:")
    for file in timerFiles.sorted() {
      let plistPath = URL(fileURLWithPath: launchAgentsDir).appendingPathComponent(file).path
      if let plist = NSDictionary(contentsOfFile: plistPath),
        let label = plist["Label"] as? String
      {
        // 检查任务是否已加载
        let isLoaded = isTaskLoaded(plistPath)
        let status = isLoaded ? "✅" : "❌"
        Logger.info("  \(status) \(label)")
      }
    }
  }

  /// 取消定时任务
  func cancel(_ identifier: String) {
    let plistPath: String
    if identifier.hasPrefix("com.user.") {
      plistPath =
        URL(fileURLWithPath: launchAgentsDir).appendingPathComponent(identifier + ".plist").path
    } else {
      // 尝试匹配
      plistPath =
        URL(fileURLWithPath: launchAgentsDir).appendingPathComponent(
          "com.user.timer-\(identifier).plist"
        ).path
    }

    guard FileManager.default.fileExists(atPath: plistPath) else {
      Logger.error("Timer not found: \(identifier)")
      return
    }

    // 卸载任务
    unloadTask(plistPath)

    // 删除文件
    do {
      try FileManager.default.removeItem(atPath: plistPath)
      Logger.info("✅ Cancelled timer: \(identifier)")
    } catch {
      Logger.error("Failed to remove plist: \(error)")
    }
  }

  // MARK: - Private Helpers

  // MARK: - Logging
  private func setupLogging() {
    try? FileManager.default.createDirectory(
      atPath: logDir, withIntermediateDirectories: true, attributes: nil)
  }

  private func log(_ message: String, for taskName: String) {
    let timestamp: String
    if #available(macOS 13.0, *) {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      timestamp = formatter.string(from: Date())
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
      timestamp = formatter.string(from: Date())
    }

    let logFile = "\(logDir)/\(taskName).log"

    if let handle = FileHandle(forWritingAtPath: logFile) {
      handle.seekToEndOfFile()
      let logEntry = "[\(timestamp)] \(message)\n"
      if let data = logEntry.data(using: .utf8) {
        handle.write(data)
      }
      handle.closeFile()
    } else {
      // 创建新文件
      try? "[\(timestamp)] \(message)\n".write(toFile: logFile, atomically: true, encoding: .utf8)
    }
  }

  /// 查看日志
  func logs(_ identifier: String? = nil) {
    setupLogging()

    if let ident = identifier {
      // 查看特定任务的日志
      let logFile = "\(logDir)/\(ident).log"
      guard FileManager.default.fileExists(atPath: logFile) else {
        Logger.error("No logs found for: \(ident)")
        return
      }
      if let content = try? String(contentsOfFile: logFile) {
        print(content)
      }
    } else {
      // 列出所有日志文件
      guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else {
        Logger.info("No logs found")
        return
      }
      let logFiles = files.filter { $0.hasSuffix(".log") }.sorted()
      if logFiles.isEmpty {
        Logger.info("No logs found")
      } else {
        Logger.info("Available log files:")
        for file in logFiles {
          let path = "\(logDir)/\(file)"
          if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64
          {
            let sizeKB = size / 1024
            Logger.info("  \(file) (\(sizeKB) KB)")
          }
        }
        Logger.info("\nUse 'ikit timer logs <identifier>' to view specific logs")
      }
    }
  }

  // MARK: - Validation
  private func validateFiles(_ files: [String]) -> [String] {
    var missing: [String] = []
    for file in files {
      let expandedPath = (file as NSString).expandingTildeInPath
      if !FileManager.default.fileExists(atPath: expandedPath) {
        missing.append(file)
      }
    }
    return missing
  }

  private func validateDate(_ date: Date) -> Bool {
    let now = Calendar.current.startOfDay(for: Date())
    let target = Calendar.current.startOfDay(for: date)
    return target >= now
  }

  private func escapeForAppleScript(_ string: String) -> String {
    return
      string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }

  // MARK: - Parsing
  private func parseTime(_ time: String) -> (Int, Int)? {
    let parts = time.split(separator: ":").map { String($0) }
    guard parts.count == 2 else { return nil }

    guard let hour = Int(parts[0]), hour >= 0, hour <= 23 else { return nil }
    guard let minute = Int(parts[1]), minute >= 0, minute <= 59 else { return nil }

    return (hour, minute)
  }

  private func parseDate(_ date: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: date)
  }

  private func generateAppleScript(
    taskName: String,
    title: String,
    message: String,
    openFiles: [String],
    openWith: String?,
    runCommand: String?,
    thenRunCommand: String?,
    terminal: String
  ) -> String {
    // 转义标题和消息中的特殊字符
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let safeMessage = message.replacingOccurrences(of: "\"", with: "\\\"")

    // 优先级1: 如果有 runCommand，直接执行（不需要对话框确认）
    if let command = runCommand {
      let escapedCmd = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"")
      return "do shell script \"\(escapedCmd)\"\n"
    }

    // 优先级2: 如果有 thenRunCommand，显示对话框后执行
    if let command = thenRunCommand {
      let timestamp = Int(Date().timeIntervalSince1970)
      let cmdFile = "/tmp/ikit-timer-\(timestamp).cmd"

      // 创建触发脚本
      let scriptContent = """
        #!/bin/bash
        CMD_FILE="\(cmdFile)"
        if [[ -f "$CMD_FILE" ]]; then
            CMD=$(cat "$CMD_FILE")
            rm -f "$CMD_FILE"
            # 在 subshell 中 cd 并执行命令
            (cd ~/Notebooks && eval "$CMD")
        fi
        """
      let scriptFile = "/tmp/ikit-timer-\(timestamp).sh"

      // 写入命令和脚本
      let writeCmd =
        "echo '\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''"))' > \(cmdFile) && echo '\(scriptContent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''"))' > \(scriptFile) && chmod +x \(scriptFile)"

      // 激活 Ghostty 的 AppleScript
      let activateScript = """
        tell application "System Events"
          set isRunning to exists (processes where name is "\(terminal)")
        end tell

        tell application "\(terminal)"
          if not isRunning then
            activate
          else
            tell application "Finder" to activate
            activate
          end if
        end tell

        delay 0.3

        tell application "System Events"
          tell process "\(terminal)"
            keystroke "t" using {command down}
          end tell
        end tell

        delay 0.4

        tell application "System Events"
          tell process "\(terminal)"
            keystroke "\(scriptFile)" & return
          end tell
        end tell
        """

      // 完整的 AppleScript：显示对话框，点击确定后执行
      let fullScript = """
        do shell script "\(writeCmd)"

        set userResponse to display dialog "\(safeMessage)" buttons {"取消", "确定"} default button "确定" with title "\(safeTitle)" with icon note

        if button returned of userResponse is "确定" then
            \(activateScript)
        end if
        """

      return fullScript
    }

    // 优先级3: 如果有文件要打开，显示对话框后打开
    if !openFiles.isEmpty {
      var openCommands: [String] = []
      for file in openFiles where !file.isEmpty {
        let expandedPath = (file as NSString).expandingTildeInPath
        if let app = openWith {
          openCommands.append("tell application \"\(app)\" to open POSIX file \"\(expandedPath)\"")
        } else {
          openCommands.append("tell application \"Finder\" to open POSIX file \"\(expandedPath)\"")
        }
      }
      if !openCommands.isEmpty {
        let openScript = openCommands.joined(separator: "\n")
        return """
          set userResponse to display dialog "\(safeMessage)" buttons {"取消", "确定"} default button "确定" with title "\(safeTitle)" with icon note
          if button returned of userResponse is "确定" then
              \(openScript)
          end if
          """
      }
    }

    // 优先级4: 只显示对话框，不执行任何操作
    return
      "display dialog \"\(safeMessage)\" buttons {\"确定\"} default button \"确定\" with title \"\(safeTitle)\" with icon note\n"
  }

  private func generatePlist(
    taskName: String,
    hour: Int,
    minute: Int,
    day: Int?,
    month: Int?,
    year: Int?,
    weekday: Int?,
    isDaily: Bool,
    script: String
  ) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let ikitPath = "\(home)/.local/bin/ikit"
    let logsDir = "\(home)/Library/Logs/com.user.ikit.timer"

    var interval = ""

    if isDaily {
      // 每天：只设置 Hour 和 Minute
      interval = """
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
            </dict>
        """
    } else if let d = day, let m = month, let y = year {
      // 指定日期
      interval = """
            <key>StartCalendarInterval</key>
            <dict>
                <key>Day</key><integer>\(d)</integer>
                <key>Month</key><integer>\(m)</integer>
                <key>Year</key><integer>\(y)</integer>
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
            </dict>
        """
    } else if let wd = weekday {
      // 每周某天
      interval = """
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
                <key>Weekday</key><integer>\(wd)</integer>
            </dict>
        """
    } else {
      // 默认（今天一次性）
      interval = """
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
            </dict>
        """
    }

    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>com.user.\(taskName)</string>

          <key>ProgramArguments</key>
          <array>
              <string>\(ikitPath)</string>
              <string>timer</string>
              <string>execute</string>
              <string>\(taskName)</string>
          </array>
      \(interval)
          <key>RunAtLoad</key>
          <false/>
          <key>StandardOutPath</key>
          <string>\(logsDir)/\(taskName).stdout.log</string>
          <key>StandardErrorPath</key>
          <string>\(logsDir)/\(taskName).stderr.log</string>

      </dict>
      </plist>
      """
  }

  private func loadTask(_ plistPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["load", plistPath]

    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        Logger.info("✅ Timer loaded and scheduled")
      } else {
        Logger.warn("Failed to load timer (may already be loaded)")
      }
    } catch {
      Logger.error("Failed to run launchctl: \(error)")
    }
  }

  private func unloadTask(_ plistPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["unload", plistPath]

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      // 忽略卸载失败（可能任务未加载）
    }
  }

  private func isTaskLoaded(_ plistPath: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["list"]

    let pipe = Pipe()
    process.standardOutput = pipe

    do {
      try process.run()
      process.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let output = String(data: data, encoding: .utf8) {
        // 提取 label
        let label = URL(fileURLWithPath: plistPath).deletingPathExtension().lastPathComponent
        return output.contains(label)
      }
    } catch {}

    return false
  }

  // MARK: - Task Config Management

  private func saveTaskConfig(taskName: String, config: [String: Any]) {
    let configURL = URL(fileURLWithPath: logDir).appendingPathComponent("\(taskName).json")
    guard let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
    else {
      Logger.error("Failed to serialize config")
      return
    }
    try? data.write(to: configURL)
    log("Config saved: \(configURL.path)", for: taskName)
  }

  private func loadTaskConfig(taskName: String) -> [String: Any]? {
    let configPath = URL(fileURLWithPath: logDir).appendingPathComponent("\(taskName).json").path
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return config
  }

  // MARK: - Execute

  func execute(_ taskName: String) {
    // 重定向 stderr 到文件
    setupLogging()

    log("=== EXECUTE STARTED ===", for: taskName)
    log("Task: \(taskName)", for: taskName)
    log("Time: \(ISO8601DateFormatter().string(from: Date()))", for: taskName)

    guard let config = loadTaskConfig(taskName: taskName) else {
      log("❌ ERROR: Config not found for task: \(taskName)", for: taskName)
      Logger.error("Task config not found: \(taskName)")
      exit(1)
    }

    let title = config["title"] as? String ?? "Timer"
    let message = config["message"] as? String ?? "⏰ Timer"
    let openFiles = config["openFiles"] as? [String] ?? []
    let openWith = config["openWith"] as? String ?? ""
    let runCommand = config["runCommand"] as? String ?? ""
    let thenRunCommand = config["thenRunCommand"] as? String ?? ""
    let sessionId = config["sessionId"] as? String
    let pwd = config["pwd"] as? String

    // 执行操作
    let success = executeAction(
      title: title,
      message: message,
      openFiles: openFiles,
      openWith: openWith,
      runCommand: runCommand,
      thenRunCommand: thenRunCommand,
      sessionId: sessionId,
      pwd: pwd
    )

    if success {
      log("✅ EXECUTE SUCCEEDED", for: taskName)
      exit(0)
    } else {
      log("❌ EXECUTE FAILED", for: taskName)
      exit(1)
    }
  }

  private func executeAction(
    title: String,
    message: String,
    openFiles: [String],
    openWith: String,
    runCommand: String,
    thenRunCommand: String,
    sessionId: String?,
    pwd: String?
  ) -> Bool {
    // 优先级0: Session Resume (Claude Code 会话恢复)
    if let sid = sessionId {
      // 显示确认对话框
      let dialogResult = Shell.run(
        "/usr/bin/osascript",
        args: [
          "-e",
          """
              display dialog "\(message)" buttons {"取消", "确定"} default button "确定" with title "\(title)" with icon note
          """,
        ])

      if dialogResult.exitCode == 0, let output = dialogResult.output, output.contains("确定") {
        // 用户确认后，写入 session info (sessionId + pwd) 到文件 (JSON 格式)
        let sessionFile = IKitDir.sessionResumeFile()
        do {
          // 构建 JSON 格式的 session 信息
          var sessionInfo: [String: String] = ["sessionId": sid]
          if let pwd = pwd {
            sessionInfo["pwd"] = pwd
          }
          let jsonData = try JSONSerialization.data(
            withJSONObject: sessionInfo, options: .prettyPrinted)
          guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            log("ERROR: Failed to encode session JSON", for: "session-\(sid.prefix(8))")
            return false
          }
          try jsonString.write(toFile: sessionFile, atomically: true, encoding: .utf8)
          log("Session info written to: \(sessionFile)", for: "session-\(sid.prefix(8))")
        } catch {
          log("ERROR: Failed to write session file: \(error)", for: "session-\(sid.prefix(8))")
          return false
        }

        // 使用 AppleScript 打开新 tab（和 claude-ask.sh 一样的模式）
        let activateScript = """
          tell application "System Events"
            set isRunning to exists (processes where name is "Ghostty")
          end tell

          tell application "Ghostty"
            if not isRunning then
              activate
            else
              -- Use the Finder trick from Raycast extension
              tell application "Finder" to activate
              activate
            end if
          end tell

          delay 0.3

          tell application "System Events"
            tell process "Ghostty"
              keystroke "t" using {command down}
            end tell
          end tell

          delay 0.4

          tell application "System Events"
            tell process "Ghostty"
              -- Just press Enter to trigger ghostty-start.sh
              delay 0.15
              keystroke return
            end tell
          end tell
          """

        // 写入 AppleScript 到临时文件并直接执行
        let timestamp = Int(Date().timeIntervalSince1970)
        let scriptFile = "/tmp/ikit-ghostty-\(timestamp).scpt"
        do {
          try activateScript.write(toFile: scriptFile, atomically: true, encoding: .utf8)

          // 直接执行 AppleScript 文件
          let result = Shell.run("/usr/bin/osascript", args: [scriptFile])

          // 清理临时文件
          try? FileManager.default.removeItem(atPath: scriptFile)

          if result.exitCode == 0 {
            log("Ghostty activated and resume triggered", for: "session-\(sid.prefix(8))")
            return true
          } else {
            log(
              "ERROR: AppleScript failed: \(result.error ?? "unknown")",
              for: "session-\(sid.prefix(8))")
            return false
          }
        } catch {
          log("ERROR: Failed to write script file: \(error)", for: "session-\(sid.prefix(8))")
          return false
        }
      }
      // 用户取消
      log("User cancelled session resume", for: "session-\(sid.prefix(8))")
      return false
    }

    // 优先级1: runCommand + thenRunCommand (显示对话框)
    if !runCommand.isEmpty {
      // 显示对话框
      let dialogResult = Shell.run(
        "/usr/bin/osascript",
        args: [
          "-e",
          """
              display dialog "\(message)" buttons {"取消", "确定"} default button "确定" with title "\(title)" with icon note
          """,
        ])
      if dialogResult.exitCode == 0, let output = dialogResult.output, output.contains("确定") {
        // 用户点击确定，执行命令
        let result = Shell.run("/bin/sh", args: ["-c", runCommand])
        if result.exitCode == 0, !thenRunCommand.isEmpty {
          let thenResult = Shell.run("/bin/sh", args: ["-c", thenRunCommand])
          return thenResult.exitCode == 0
        }
        return result.exitCode == 0
      }
      return false
    }

    // 优先级2: thenRunCommand only (显示对话框)
    if !thenRunCommand.isEmpty {
      let dialogResult = Shell.run(
        "/usr/bin/osascript",
        args: [
          "-e",
          """
              display dialog "\(message)" buttons {"取消", "确定"} default button "确定" with title "\(title)" with icon note
          """,
        ])
      if dialogResult.exitCode == 0, let output = dialogResult.output, output.contains("确定") {
        let result = Shell.run("/bin/sh", args: ["-c", thenRunCommand])
        return result.exitCode == 0
      }
      return false
    }

    // 优先级3: openFiles (显示对话框后打开)
    if !openFiles.isEmpty {
      // 构建文件列表描述
      let fileList = openFiles.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).lastPathComponent
      }.joined(separator: ", ")

      // 显示对话框
      let dialogResult = Shell.run(
        "/usr/bin/osascript",
        args: [
          "-e",
          """
              display dialog "\(message)\n\n文件: \(fileList)" buttons {"取消", "确定"} default button "确定" with title "\(title)" with icon note
          """,
        ])

      if dialogResult.exitCode != 0 || (dialogResult.output?.contains("确定") == false) {
        return false
      }

      // 打开文件
      for file in openFiles where !file.isEmpty {
        let expandedPath = (file as NSString).expandingTildeInPath
        if !openWith.isEmpty {
          _ = Shell.run("/usr/bin/open", args: ["-a", openWith, expandedPath])
        } else {
          _ = Shell.run("/usr/bin/open", args: [expandedPath])
        }
      }
      return true
    }

    // 优先级4: 只显示对话框
    let script =
      "display dialog \"\(message)\" buttons {\"确定\"} default button \"确定\" with title \"\(title)\" with icon note"
    let result = Shell.run("/usr/bin/osascript", args: ["-e", script])
    return result.exitCode == 0
  }
}

// MARK: - Secretary Tool
class SecretaryTool {
  let logger = Logger.self
  let configManager = ConfigManager.shared

  private func loadImageAsBase64(path: String) -> String? {
    guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return nil
    }
    let base64Str = imageData.base64EncodedString()
    return "data:image/jpeg;base64,\(base64Str)"
  }

  // MARK: - Image Selection (Step 1)
  /// Select relevant screenshots based on transcript and OCR metadata
  private func selectRelevantImages(
    transcript: String, ocrMetadata: [[String: Any]], allScreenshots: [String]
  ) async -> [String] {
    let maxImages = configManager.current.summary_max_images ?? 3

    // Build OCR context for selection
    let ocrContext = ocrMetadata.compactMap { meta -> String? in
      guard let timestamp = meta["timestamp"] as? Int,
        let text = meta["ocrText"] as? String,
        !text.isEmpty
      else { return nil }

      let delta = (meta["ocrDelta"] as? String)?.isEmpty == false ? " [新内容]" : ""
      return "[\(timestamp)s]\(delta): \(text.prefix(100))"
    }.joined(separator: "\n")

    let selectionPrompt = """
      你是一个智能截图筛选助手。根据会议转录内容和OCR识别结果，
      挑选出\(maxImages)张与会议主题最相关的截图。

      ## 考虑因素：
      - 屏幕内容是否与讨论话题相关
      - 是否包含关键信息（代码、图表、决策点）
      - 时间戳是否与关键讨论对应
      - 避免选择重复或相似的内容

      ## 转录内容（前3000字）：
      \(transcript.prefix(3000))

      ## OCR识别内容：
      \(ocrContext.prefix(5000))

      ## 可选截图列表（按时间戳）：
      \(allScreenshots.enumerated().map { (index, path) in "\(index + 1). shot_\(URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: "shot_", with: "").replacingOccurrences(of: ".jpg", with: ""))" }.joined(separator: "\n"))

      请返回最相关的\(maxImages)张截图编号，用逗号分隔。
      例如：1,3,5
      如果没有相关截图，返回：无
      """

    // Call LLM for image selection
    if let urlStr = configManager.current.litellm_url,
      let model = configManager.current.litellm_model,
      let baseUrl = URL(
        string: urlStr.replacingOccurrences(of: "/v1/completions", with: "/v1/chat/completions"))
    {
      var request = URLRequest(
        url: baseUrl, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      if let apiKey = configManager.current.litellm_api_key, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }

      let body: [String: Any] = [
        "model": model,
        "messages": [["role": "user", "content": selectionPrompt]],
        "stream": false,
        "max_tokens": 1000,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      do {
        let (data, _) = try await callLLMWithRetry(request: request, maxRetries: 2)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let msg = choices.first?["message"] as? [String: Any],
          let response = msg["content"] as? String
        {
          // Parse response to extract image numbers
          Logger.info("🎯 Image selection response: \(response.prefix(100))")

          let selectedNumbers =
            response
            .split(separator: ",")
            .compactMap { part -> Int? in
              let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
              return Int(trimmed)
            }
            .filter { $0 > 0 && $0 <= allScreenshots.count }

          if !selectedNumbers.isEmpty {
            let selected = selectedNumbers.map { allScreenshots[$0 - 1] }
            Logger.info("🎯 Selected \(selected.count) relevant images")
            return selected
          }
        }
      } catch {
        Logger.warn("⚠️ Image selection failed: \(error)")
      }
    }

    // Fallback: return first N images
    let fallbackCount = min(maxImages, allScreenshots.count)
    Logger.info("🎯 Using fallback: first \(fallbackCount) images")
    return Array(allScreenshots.prefix(fallbackCount))
  }

  // MARK: - API Retry Logic
  private func callLLMWithRetry(request: URLRequest, maxRetries: Int) async throws -> (
    Data, URLResponse
  ) {
    var lastError: Error?

    for attempt in 0...maxRetries {
      do {
        let result = try await URLSession.shared.data(for: request)
        return result
      } catch {
        lastError = error
        if attempt < maxRetries {
          let delay = Double(attempt + 1) * 2.0  // 2s, 4s, 8s...
          Logger.warn(
            "⚠️ API call failed (attempt \(attempt + 1)/\(maxRetries + 1)), retrying in \(delay)s..."
          )
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }

    throw lastError ?? URLError(.badServerResponse)
  }

  // MARK: - Vision Model Call (for selected images)
  private func callVisionModel(
    prompt: String, images: [String]
  ) async -> String? {
    guard let urlStr = configManager.current.litellm_url,
      let visionModel = configManager.current.litellm_vision_model,
      let baseUrl = URL(
        string: urlStr.replacingOccurrences(of: "/v1/completions", with: "/v1/chat/completions"))
    else {
      return nil
    }

    var request = URLRequest(
      url: baseUrl, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 300)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let apiKey = configManager.current.litellm_api_key, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    // Build content with images
    var content: [[String: Any]] = [["type": "text", "text": prompt]]
    for imagePath in images {
      if let base64 = loadImageAsBase64(path: imagePath) {
        content.append([
          "type": "image_url",
          "image_url": ["url": base64],
        ])
      }
    }

    let body: [String: Any] = [
      "model": visionModel,
      "messages": [["role": "user", "content": content]],
      "stream": false,
      "max_tokens": 100000,
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
      let (data, _) = try await callLLMWithRetry(request: request, maxRetries: 2)
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = json["choices"] as? [[String: Any]],
        let msg = choices.first?["message"] as? [String: Any],
        let text = msg["content"] as? String
      {
        Logger.info("✅ Vision model completed")
        return text
      }
    } catch {
      Logger.error("❌ Vision model error: \(error)")
    }

    return nil
  }

  // MARK: - Text Model Call (for transcript)
  private func callTextModel(prompt: String) async -> String? {
    // Try LiteLLM first
    if let urlStr = configManager.current.litellm_url,
      let url = URL(string: urlStr),
      let model = configManager.current.litellm_model
    {
      var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 300)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      if let apiKey = configManager.current.litellm_api_key, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }

      let body: [String: Any] = [
        "model": model,
        "prompt": prompt,
        "stream": false,
        "max_tokens": 100000,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      do {
        let (data, _) = try await callLLMWithRetry(request: request, maxRetries: 2)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let text = choices.first?["text"] as? String
        {
          Logger.info("✅ Text model completed (LiteLLM)")
          return text
        }
      } catch {
        Logger.debug("LiteLLM Error: \(error)")
      }
    }

    // Fallback to Ollama
    if let urlStr = configManager.current.ollama_url,
      let url = URL(string: urlStr),
      let model = configManager.current.ollama_model
    {
      var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 300)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      let body: [String: Any] = [
        "model": model,
        "prompt": prompt,
        "stream": false,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      do {
        let (data, _) = try await callLLMWithRetry(request: request, maxRetries: 2)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let res = json["response"] as? String
        {
          Logger.info("✅ Text model completed (Ollama)")
          return res
        }
      } catch {
        Logger.debug("Ollama Error: \(error)")
      }
    }

    return nil
  }

  // MARK: - Output Fusion
  private func fuseSummary(textResult: String, visualResult: String?, images: [String]) -> String {
    var summary = ""

    // Add image references if any
    if !images.isEmpty {
      summary += "## 关键截图\n\n"
      for imagePath in images {
        let filename = URL(fileURLWithPath: imagePath).lastPathComponent
        summary += "![\(filename)](\(filename))\n\n"
      }
      summary += "---\n\n"
    }

    // Merge text and visual results
    if let visual = visualResult {
      // If we have visual result, use it as the base and supplement with text
      summary += visual

      // Check if text result has additional info not in visual
      if textResult.count > visual.count * 2 {
        summary += "\n\n---\n\n## 文字转录摘要\n\n\(textResult)"
      }
    } else {
      // No visual result, use text only
      summary += textResult
    }

    return summary
  }

  internal func summarize(
    text: String, screenshots: [String] = [], ocrMetadata: [[String: Any]] = []
  ) async -> String {
    // Step 1: Select relevant images if OCR metadata is available
    let selectedImages: [String]
    if !ocrMetadata.isEmpty && !screenshots.isEmpty {
      Logger.info("🎯 Step 1: Selecting relevant images from \(screenshots.count) screenshots...")
      selectedImages = await selectRelevantImages(
        transcript: text, ocrMetadata: ocrMetadata, allScreenshots: screenshots)
    } else {
      // Fallback: use first N images
      let maxImages = configManager.current.summary_max_images ?? 3
      selectedImages = Array(screenshots.prefix(maxImages))
    }

    // Step 2: Prepare prompts for dual-model processing
    let textPrompt = """
      你是一个专业的会议秘书。请根据以下转录内容生成一份精准的结构化纪要。
      尽可能使用真实姓名，推断发言人身份。

      ## 要求：
      1. 提取会议主题、讨论要点、决策事项、行动项
      2. 使用 Markdown 格式，结构清晰
      3. 重要内容使用加粗标记

      ## 转录内容：
      \(text.prefix(15000))
      """

    let visionPrompt = """
      你是一个专业的会议秘书。请分析这些截图和转录内容，生成一份图文并茂的会议纪要。

      ## 转录内容：
      \(text.prefix(8000))

      ## 要求：
      1. 描述每张截图的关键信息
      2. 结合转录内容，提取讨论要点
      3. 标注重要的决策事项和行动项
      4. 使用 Markdown 格式
      """

    // Step 3: Parallel dual-model call
    Logger.info("🔄 Step 2: Parallel dual-model processing...")

    async let textResult: String? = callTextModel(prompt: textPrompt)
    async let visionResult: String? = {
      if !selectedImages.isEmpty {
        return await callVisionModel(prompt: visionPrompt, images: selectedImages)
      }
      return nil
    }()

    // Wait for both results
    let text = await textResult
    let visual = await visionResult

    // Step 4: Fuse outputs
    Logger.info("🔗 Step 3: Fusing outputs...")

    guard let textFinal = text else {
      return "⚠️ 会议纪要生成失败：文本模型调用失败。请检查 LLM 服务配置。"
    }

    let summary = fuseSummary(textResult: textFinal, visualResult: visual, images: selectedImages)

    return summary.isEmpty ? "⚠️ 会议纪要生成失败：模型返回空结果。" : summary
  }

  private func performOCR(on imagePath: String) async -> String {
    let url = URL(fileURLWithPath: imagePath)
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else { return "" }

    return await withCheckedContinuation { continuation in
      let request = VNRecognizeTextRequest { req, _ in
        let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap {
          $0.topCandidates(1).first?.string
        }
        continuation.resume(returning: strings?.joined(separator: " ") ?? "")
      }
      request.recognitionLanguages = ["zh-Hans", "en-US"]
      request.recognitionLevel = .accurate
      try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }
  }

  private func formatDialogue(from items: [FunASRItem]) -> String {
    var out = ""
    for item in items {
      if let sentences = item.sentence_info {
        for s in sentences {
          out += "[Speaker \(s.spk ?? 0)]: \(s.text)\n"
        }
      } else if let text = item.text {
        out += text + "\n"
      }
    }
    return out
  }

  func process(files: [String], outputDir: String) async {
    let fm = FileManager.default
    for file in files {
      guard fm.fileExists(atPath: file) else { continue }
      Logger.info("🤖 Processing: \(file)")

      var content = ""
      if file.hasSuffix(".json"),
        let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
        let items = try? JSONDecoder().decode([FunASRItem].self, from: data)
      {
        content = formatDialogue(from: items)
      } else {
        content = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
      }

      if content.isEmpty { continue }

      let fileDir = (file as NSString).deletingLastPathComponent
      let screenshots =
        (try? fm.contentsOfDirectory(atPath: fileDir))?
        .filter { $0.hasPrefix("shot_") && $0.hasSuffix(".jpg") }
        .sorted() ?? []

      // Load OCR metadata if available
      let metadataPath = "\(fileDir)/screenshots_metadata.json"
      var ocrMetadata: [[String: Any]] = []

      if let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
        let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [[String: Any]]
      {
        ocrMetadata = metadata
        Logger.info("📸 Loaded \(ocrMetadata.count) OCR metadata entries")
      }

      // Build full screenshot paths for vision model
      let screenshotPaths = screenshots.map { "\(fileDir)/\($0)" }

      let summary = await summarize(
        text: content, screenshots: screenshotPaths, ocrMetadata: ocrMetadata)

      let dateStr = ISO8601DateFormatter().string(from: Date())
      let outPath = (outputDir as NSString).appendingPathComponent(
        "\(dateStr)-\((file as NSString).lastPathComponent).md")

      // Create output directory if it doesn't exist
      let outDirPath = (outPath as NSString).deletingLastPathComponent
      if !fm.fileExists(atPath: outDirPath) {
        try? fm.createDirectory(atPath: outDirPath, withIntermediateDirectories: true)
      }

      // Write file and verify success
      do {
        try summary.write(toFile: outPath, atomically: true, encoding: String.Encoding.utf8)
        if fm.fileExists(atPath: outPath) {
          Logger.info("✅ Saved to: \(outPath)")
        } else {
          Logger.error("❌ File write reported success but file not found: \(outPath)")
        }
      } catch {
        Logger.error("❌ Failed to write file: \(outPath)")
        Logger.error("Error: \(error)")
      }
    }
  }

  func transcribe(audioPath: String) async {
    guard let python = configManager.current.python_path,
      let script = configManager.current.transcribe_script
    else {
      Logger.error("Python/Script path not configured")
      return
    }

    let out = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension("json")
      .path
    Logger.info("🎤 Transcribing (FunASR): \(audioPath)")
    Logger.info("⏳ Loading models (this may take a moment on first run)...")

    let result = Shell.run(python, args: [script, audioPath, "--output", out])

    // Forward Python script output for visibility
    if let output = result.output, !output.isEmpty {
      // Print each line to show progress
      for line in output.components(separatedBy: "\n") {
        if !line.isEmpty {
          print(line)
        }
      }
    }

    // Check if transcription succeeded
    if result.exitCode == 0 {
      // Verify output file was created
      if FileManager.default.fileExists(atPath: out) {
        Logger.info("✅ Transcription saved to: \(out)")
      } else {
        Logger.error("❌ Transcription completed but output file not found: \(out)")
      }
    } else {
      Logger.error("❌ Transcription failed (exit code: \(result.exitCode))")
      if let error = result.error {
        Logger.error("Error: \(error)")
      }
    }
  }

  /// Transcribe audio using Groq's whisper-large-v3 via local LiteLLM service
  func transcribeWithGroq(audioPath: String, language: String = "auto") async -> String? {
    // Load Groq API key from LiteLLM config
    let envPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/litellm/config/.env")

    var apiKey: String?
    if let envContent = try? String(contentsOfFile: envPath.path) {
      for line in envContent.components(separatedBy: .newlines) {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("GROQ_API_KEY=") {
          apiKey = String(line.dropFirst("GROQ_API_KEY=".count))
          break
        }
      }
    }

    guard let apiKey = apiKey else {
      Logger.error("❌ GROQ_API_KEY not found in ~/.config/litellm/config/.env")
      return nil
    }

    Logger.info("🚀 Transcribing with Groq whisper-large-v3")
    Logger.info("📁 Audio: \(audioPath)")

    // Prepare multipart form data request
    let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    var request = URLRequest(url: url, timeoutInterval: 600)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Build multipart form data boundary
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()

    // Add file field
    do {
      let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append(
        "Content-Disposition: form-data; name=\"file\"; filename=\"\(URL(fileURLWithPath: audioPath).lastPathComponent)\"\r\n"
          .data(using: .utf8)!)
      body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
      body.append(audioData)
      body.append("\r\n".data(using: .utf8)!)
    } catch {
      Logger.error("❌ Failed to read audio file: \(error)")
      return nil
    }

    // Add model field
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
    body.append("whisper-large-v3\r\n".data(using: .utf8)!)

    // Add language field if specified
    if language != "auto" {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(language)\r\n".data(using: .utf8)!)
    }

    // Add response_format field
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
    body.append("verbose_json\r\n".data(using: .utf8)!)

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        if httpResponse.statusCode == 200 {
          if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
          {
            Logger.info("✅ Transcription complete!")
            return text
          }
        } else {
          Logger.error("❌ Groq API error: \(httpResponse.statusCode)")
          if let errorString = String(data: data, encoding: .utf8) {
            Logger.error(errorString)
          }
        }
      }
    } catch {
      Logger.error("❌ Transcription failed: \(error)")
    }

    return nil
  }
}

// MARK: - Main
struct App {
  static let VERSION = "2.9.0"

  static func main() async {
    let args = CommandLine.arguments
    let configManager = ConfigManager.shared

    let json = args.contains("--json")
    let dryRun = args.contains("--dry-run")
    let isId = args.contains("--id")
    let isHelp = args.contains("--help") || args.contains("-h")

    // Photo flags
    let isScreenshots = args.contains("--screenshots")
    let isFavorites = args.contains("--favorites")

    // Init Logger
    if args.contains("-v") || args.contains("--verbose") { Logger.verbose = true }

    if args.contains("--version") {
      Logger.info("iKit version \(VERSION)")
      return
    }

    if isHelp {
      printHelp(for: args.count > 1 ? args[1] : nil)
      return
    }
    guard args.count > 1 else {
      printHelp(for: nil)
      return
    }

    let cmd = args[1]
    let sub = args.count > 2 ? args[2] : ""

    func getRoot() -> String? {
      if args.count > 3 && !args[3].starts(with: "-") { return args[3] }
      return configManager.current.notes_root?.replacingOccurrences(
        of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func getIntParam(_ name: String) -> Int? {
      // First try: --param value (separate)
      if let idx = args.firstIndex(of: name), idx + 1 < args.count { return Int(args[idx + 1]) }
      // Second try: --param=value (combined)
      for arg in args {
        if arg.hasPrefix("\(name)=") {
          let value = arg.dropFirst(name.count + 1)
          return Int(value)
        }
      }
      return nil
    }

    func getStringParam(_ name: String) -> String? {
      // First try: --param value (separate)
      if let idx = args.firstIndex(of: name), idx + 1 < args.count { return args[idx + 1] }
      // Second try: --param=value (combined)
      for arg in args {
        if arg.hasPrefix("\(name)=") {
          let value = arg.dropFirst(name.count + 1)
          return String(value)
        }
      }
      return nil
    }

    func getMultipleStringParams(_ name: String) -> [String] {
      var result: [String] = []
      var i = 0
      while i < args.count {
        if args[i] == name && i + 1 < args.count && !args[i + 1].starts(with: "--") {
          result.append(args[i + 1])
          i += 2
        } else if args[i].hasPrefix("\(name)=") {
          let value = String(args[i].dropFirst(name.count + 1))
          result.append(value)
          i += 1
        } else {
          i += 1
        }
      }
      return result
    }

    func getBoolParam(_ name: String) -> Bool {
      return args.contains(name)
    }
    let count = getIntParam("--last") ?? 10

    // 顶层命令：init
    if cmd == "init" || (cmd.isEmpty && args.count <= 1) {
      IKitDir.setup()
      return
    }

    switch cmd {
    case "doctor":
      // 系统健康检查
      print("🔍 iKit 系统检查")
      print("")

      // 检查 ffmpeg (required for FunASR transcription)
      let ffmpegResult = Shell.run("/usr/bin/which", args: ["ffmpeg"])
      if ffmpegResult.exitCode == 0 {
        print("✅ ffmpeg: \(ffmpegResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已安装")")
      } else {
        print("❌ ffmpeg: 未安装")
        print("     需要: brew install ffmpeg")
        print("     (FunASR 转录依赖 ffmpeg 进行音频格式转换)")
      }

      // 检查 Screen Recording 权限
      let screenCheckResult = Shell.run("/usr/bin/swift", args: ["-e", """
        import ScreenCaptureKit
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("OK")
        """])
      if screenCheckResult.exitCode == 0 && screenCheckResult.output?.contains("OK") == true {
        print("✅ Screen Recording: 已授权")
      } else {
        print("⚠️  Screen Recording: 可能未授权")
        print("     请前往: System Settings → Privacy & Security → Screen Recording")
        print("     授权当前终端应用，否则 meet 录音将无法捕获系统音频")
      }

      print("")

      // 检查 Python
      let pythonPath = configManager.current.python_path ?? "python3"
      let pythonVersion = Shell.run(pythonPath, args: ["--version"])
      if pythonVersion.exitCode == 0 {
        print("✅ Python: \(pythonVersion.output?.split(separator: "\n").first ?? "已安装")")
      } else {
        print("⚠️  Python: 未找到或无法运行")
      }

      // 检查依赖
      let deps = [
        ("FunASR", "funasr"),
        ("ModelScope", "modelscope"),
        ("torch", "torch"),
        ("MLX-Whisper", "mlx_whisper"),
        ("WhisperX", "whisperx"),
        ("pyannote", "pyannote.audio"),
      ]

      for (name, module) in deps {
        let result = Shell.run(pythonPath, args: ["-c", "import \(module); print('OK')"])
        let status = result.exitCode == 0 && result.output?.contains("OK") == true
        print("  \(status ? "✅" : "❌") \(name): \(status ? "已安装" : "未安装")")
      }

      print("")
      print("💾 模型缓存:")
      let (modelscope, hf) = IKitDir.checkModelCache()
      if modelscope.exists {
        print("  ✅ ModelScope: \(modelscope.size)")
        print("     (FunASR - 中文语音识别)")
      } else {
        print("  ⏳ ModelScope: 未缓存")
        print("     首次 transcribe 时自动下载 (~4.9GB)")
      }
      if hf.exists {
        print("  ✅ HuggingFace: \(hf.size)")
        print("     (Whisper, MLX, pyannote - 英文语音识别)")
      } else {
        print("  ⏳ HuggingFace: 未缓存")
        print("     首次 transcribe 时自动下载 (~7.4GB)")
      }

    case "config":
      if sub == "init" {
        configManager.save()
      } else if sub == "show" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(configManager.current),
          let str = String(data: data, encoding: .utf8)
        {
          print(str)
        }
      } else {
        print("Usage: ikit config [init|show]")
      }

    case "task":
      let t = RemindersTool()
      if sub == "list" {
        await t.listTasks(json: json)
      } else if sub == "new" && args.count > 3 {
        let title = args[3]
        let due = getStringParam("--due")
        let priority = getIntParam("--priority")
        let notes = getStringParam("--notes")
        await t.newTask(title: title, due: due, priority: priority, notes: notes)
      } else if sub == "complete" && args.count > 3 {
        await t.completeTask(query: args[3], isId: isId)
      } else if sub == "delete" && args.count > 3 {
        await t.deleteTask(query: args[3], isId: isId, dryRun: dryRun)
      } else {
        printHelp(for: "task")
      }

    case "cal":
      let t = CalendarTool()
      if sub == "list" {
        await t.listEvents(json: json)
      } else if sub == "new" && args.count > 4 {
        await t.newEvent(title: args[3], time: args[4])
      } else if sub == "delete" && args.count > 3 {
        await t.deleteEvent(title: args[3])
      } else {
        printHelp(for: "cal")
      }

    case "contact":
      if sub == "search" && args.count > 3 {
        await ContactsTool().search(query: args[3], json: json)
      } else {
        printHelp(for: "contact")
      }

    case "photo":
      let t = PhotoTool()
      if sub == "list" {
        await t.listRecent(
          count: count, screenshots: isScreenshots, favorites: isFavorites, json: json)
      } else if sub == "ocr" {
        if args.count > 3 && !args[3].starts(with: "-") {
          await t.ocr(assetId: args[3])
        } else {
          await t.batchOcr(count: count, screenshots: isScreenshots, favorites: isFavorites)
        }
      } else {
        printHelp(for: "photo")
      }

    case "ocr":
      if args.count > 2 {
        await ocrFromPath(args[2])
      } else {
        print("Usage: ikit ocr <image-path>")
      }

    case "sc":
      let t = ShortcutsTool()
      if sub == "list" {
        t.listShortcuts()
      } else if sub == "run" && args.count > 3 {
        t.runShortcut(name: args[3], input: args.count > 4 ? args[4] : nil)
      } else {
        printHelp(for: "sc")
      }

    case "note":
      let t = NotesTool()
      guard let root = getRoot() else {
        Logger.error("Missing root")
        return
      }
      if sub == "sync" {
        t.sync(
          targetDir: root, folderFilter: getStringParam("--folder"),
          since: getStringParam("--since"))
      } else if sub == "ls" && args.count > 4 {
        let json = args.contains("--json")
        t.list(folder: args[4], json: json)
      } else if sub == "search" && args.count > 4 {
        let json = args.contains("--json")
        let folder = getStringParam("--folder")
        t.search(keyword: args[4], folder: folder, json: json)
      } else if sub == "new" && args.count > 6 {
        t.create(targetDir: root, folder: args[4], title: args[5], content: args[6])
      } else if sub == "append" && args.count > 6 {
        t.append(targetDir: root, folder: args[4], title: args[5], content: args[6])
      } else if sub == "update" && args.count > 6 {
        t.update(targetDir: root, folder: args[4], title: args[5], content: args[6])
      } else if sub == "delete" && args.count > 5 {
        t.delete(targetDir: root, folder: args[4], title: args[5])
      } else if sub == "move" && args.count > 6 {
        t.move(targetDir: root, sourceFolder: args[4], title: args[5], targetFolder: args[6])
      } else {
        printHelp(for: "note")
      }

    case "meet":
      let t = SecretaryTool()
      if sub == "start" && args.count > 2 {
        if #available(macOS 13.0, *) {
          // Determine recording mode from flags
          let mode: RecordingMode
          if args.contains("--mic-only") {
            mode = .micOnly
          } else if args.contains("--system-only") {
            mode = .sysOnly
          } else {
            mode = .both
          }

          // Get meeting name
          let meetingName = args[2]

          // Get output directory
          let outputDir: String
          if let oIndex = args.firstIndex(of: "-o"), oIndex + 1 < args.count {
            outputDir = args[oIndex + 1]
          } else {
            // Default to ~/recordings
            outputDir = FileManager.default.homeDirectoryForCurrentUser.path + "/recordings"
          }

          await MeetSession(name: meetingName, mode: mode).run(outputDir: outputDir)
        } else {
          print("Meeting recording requires macOS 13+")
        }
      } else if sub == "transcribe" && args.count > 3 {
        await t.transcribe(audioPath: args[3])
      } else if sub == "record" && args.count > 3 {
        if #available(macOS 13.0, *) {
          let d = Daemon()  // Reusing Daemon logic for simple record for now
          let out = args[3]
          // Ideally we should have a simple Recorder class distinct from Daemon
          // But for now, user can use Daemon
          print("Please use 'ikit meet daemon <outDir>' for continuous recording")
        } else {
          print("Meeting recording requires macOS 13+")
        }
      } else if sub == "daemon" && args.count > 3 {
        if #available(macOS 13.0, *) {
          // Determine recording mode from flags (or use config default)
          let mode: RecordingMode
          let configMode = ConfigManager.shared.getMeetDefaultMode()
          if args.contains("--mic-only") {
            mode = .micOnly
          } else if args.contains("--system-only") {
            mode = .sysOnly
          } else if configMode == "mic-only" {
            mode = .micOnly
          } else if configMode == "system-only" {
            mode = .sysOnly
          } else {
            mode = .both
          }

          // Get segment interval (default from config, or 15 minutes)
          let defaultInterval = ConfigManager.shared.getMeetDefaultInterval()
          var segmentMinutes = 15  // Fallback default
          var usedDeprecatedFormat = false  // Track if user used old format

          // Parse config default interval
          if let configResult = parseInterval(defaultInterval) {
            segmentMinutes = configResult.minutes
          }

          // Helper function to parse interval string to minutes
          func parseInterval(_ value: String) -> (minutes: Int, deprecated: Bool)? {
            let v = value.lowercased().trimmingCharacters(in: .whitespaces)

            // New format: explicit unit suffix
            if v.hasSuffix("s") {
              // Seconds: 60s = 1 minute
              if let secs = Int(v.dropLast()) {
                return (secs / 60, false)
              }
            } else if v.hasSuffix("m") {
              // Minutes: 5m = 5 minutes
              if let mins = Int(v.dropLast()) {
                return (mins, false)
              }
            } else if v.hasSuffix("h") {
              // Hours: 1h = 60 minutes
              if let hours = Int(v.dropLast()) {
                return (hours * 60, false)
              }
            } else {
              // Old format: no suffix = minutes (deprecated)
              if let mins = Int(v) {
                return (mins, true)
              }
            }
            return nil
          }

          // Format 1: --interval N (space separated)
          if let idx = args.firstIndex(of: "--interval") {
            if idx + 1 < args.count {
              let intervalStr = args[idx + 1]
              if let result = parseInterval(intervalStr) {
                segmentMinutes = result.minutes
                usedDeprecatedFormat = result.deprecated
              }
            }
          } else {
            // Format 2: --interval=N (equals sign)
            for arg in args {
              if arg.hasPrefix("--interval=") {
                let value = String(arg.dropFirst(11))  // Remove "--interval="
                if let result = parseInterval(value) {
                  segmentMinutes = result.minutes
                  usedDeprecatedFormat = result.deprecated
                }
                break
              }
            }
          }

          // Reject deprecated bare number format (Issue #5)
          if usedDeprecatedFormat {
            Logger.error("❌ Invalid interval format: --interval=N")
            Logger.error("   Interval must include an explicit unit suffix:")
            Logger.error("   • 60s  = 60 seconds (1 minute)")
            Logger.error("   • 5m   = 5 minutes")
            Logger.error("   • 1h   = 1 hour (60 minutes)")
            Logger.error("")
            Logger.error("   Example: ikit meet daemon ~/recordings --interval=5m --background")
            exit(1)
          }

          // Validate interval
          if segmentMinutes < 1 {
            Logger.error("❌ Interval must be at least 1 minute")
            exit(1)
          }

          // Find output directory (first non-flag argument after "daemon")
          // Skip: program path, commands, flags (--mic-only, --system-only, --interval), their values, and -v, -h, etc.
          var outputDir = "~/recordings"

          // Build a set of indices to skip (flags and their values)
          var skipIndices = Set<Int>()
          var flagsToSkip = ["--mic-only", "--system-only", "--interval"]

          // Skip flags and their values
          for flag in flagsToSkip {
            if let idx = args.firstIndex(of: flag) {
              skipIndices.insert(idx)
              if idx + 1 < args.count && !args[idx + 1].starts(with: "-") {
                skipIndices.insert(idx + 1)
              }
            }
          }

          // Find first non-skipped argument after "daemon" command
          if let daemonIdx = args.firstIndex(of: "daemon") {
            for i in (daemonIdx + 1)..<args.count {
              if !skipIndices.contains(i) && !args[i].starts(with: "-") {
                outputDir = args[i]
                break
              }
            }
          }

          // Check for --background flag
          let backgroundMode = args.contains("--background")

          // Warn if not using --background (Issue #4)
          if !backgroundMode {
            Logger.warn("⚠️  Running without --background flag")
            Logger.warn("   Recording may stop if terminal closes or SIGHUP is received")
            Logger.warn(
              "   Use 'ikit meet daemon <outDir> --background' for reliable background recording")
            print("")
          }

          await Daemon(mode: mode, segmentMinutes: segmentMinutes, background: backgroundMode).run(
            outputDir: outputDir)
        }
      } else if sub == "status" {
        // Show daemon status
        showDaemonStatus()
      } else if sub == "stop" {
        // Stop daemon
        stopDaemon()
      } else if sub == "process" && args.count > 3 {
        // files...
        let outDir =
          args.last!.starts(with: "/") ? args.last! : (configManager.current.notes_root ?? ".")
        // files are from index 3 to end-1
        let files = Array(args[3..<args.count - 1])
        await t.process(files: files, outputDir: outDir)
      } else {
        print("Usage: ikit meet [start|process|transcribe|daemon|status|stop]")
      }

    case "timer":
      let t = TimerTool()
      if sub == "list" {
        t.list()
      } else if sub == "cancel" && args.count > 3 {
        t.cancel(args[3])
      } else if sub == "logs" {
        if args.count > 3 { t.logs(args[3]) } else { t.logs() }
      } else if sub == "execute" && args.count > 3 {
        t.execute(args[3])
      } else if sub == "new" || sub.isEmpty {
        // 需要至少 --time 参数
        guard let time = getStringParam("--time") else {
          Logger.error("Missing --time parameter (HH:MM format)")
          print(
            "Usage: ikit timer new --time HH:MM [--daily] [--date YYYY-MM-DD] [--weekday N] [--session SESSION_ID] [--open FILE]... [--with APP] [--run COMMAND] [--then-run COMMAND] [--terminal APP] [--title TITLE] [--message MESSAGE]"
          )
          return
        }
        let openFiles = getMultipleStringParams("--open")
        t.create(
          time: time,
          date: getStringParam("--date"),
          weekday: getIntParam("--weekday"),
          daily: getBoolParam("--daily"),
          open: openFiles,
          with: getStringParam("--with"),
          run: getStringParam("--run"),
          thenRun: getStringParam("--then-run"),
          session: getStringParam("--session"),
          pwd: getStringParam("--pwd"),
          terminal: getStringParam("--terminal") ?? "Ghostty",
          title: getStringParam("--title") ?? "Timer",
          message: getStringParam("--message")
        )
      } else if sub == "resume" {
        // 便捷命令：安排 session resume
        guard let time = getStringParam("--time") else {
          Logger.error("Missing --time parameter (HH:MM format)")
          print(
            "Usage: ikit timer resume --time HH:MM [--date YYYY-MM-DD] [--session SESSION_ID] [--pwd PWD] [--title TITLE]"
          )
          return
        }
        let sessionId = getStringParam("--session")
        let pwd = getStringParam("--pwd")
        let title = getStringParam("--title") ?? "Resume Session"

        t.create(
          time: time,
          date: getStringParam("--date"),
          weekday: nil,
          daily: false,
          open: [],
          with: nil,
          run: nil,
          thenRun: nil,
          session: sessionId,
          pwd: pwd,
          terminal: "Ghostty",
          title: title,
          message: nil
        )
      } else {
        printHelp(for: "timer")
      }

    case "transcribe":
      // Top-level audio transcription command (Agent-friendly design)
      let startDate = Date()

      // Progressive --help: no audio file provided
      if args.count < 3 {
        print(
          agentError(
            "transcribe: usage: transcribe <audio-file> [--language zh|en|auto] [--engine groq|funasr]",
            suggestion: "ikit transcribe meeting.m4a --engine groq"))
        print("[exit:1 | 0ms]")
        return
      }

      let audioPath = args[2]

      // Validate file exists with remediation
      guard FileManager.default.fileExists(atPath: audioPath) else {
        let suggestion =
          FileManager.default.fileExists(atPath: audioPath + ".m4a")
          ? "Did you mean: \(audioPath).m4a?"
          : "Check file path with: ls -l \(audioPath.replacingOccurrences(of: "/[^/]+$", with: "", options: .regularExpression))"
        print(agentError("Audio file not found: \(audioPath)", suggestion: suggestion))
        print("[exit:1 | 0ms]")
        return
      }

      let engine = getStringParam("--engine") ?? "groq"
      let language = getStringParam("--language") ?? "auto"

      // Validate engine
      guard ["groq", "funasr"].contains(engine) else {
        print(agentError("Unknown engine: \(engine)", suggestion: "Use --engine groq|funasr"))
        print("[exit:1 | 0ms]")
        return
      }

      if engine == "groq" {
        // Use Groq whisper-large-v3 via direct API call
        let t = SecretaryTool()
        if let text = await t.transcribeWithGroq(audioPath: audioPath, language: language) {
          // Save to file
          let outputPath = URL(fileURLWithPath: audioPath).deletingPathExtension()
            .appendingPathExtension("txt").path
          do {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            let duration = Date().timeIntervalSince(startDate)
            print(text)
            agentOutput("Saved to: \(outputPath)", exitCode: 0, duration: duration)
          } catch {
            let duration = Date().timeIntervalSince(startDate)
            print(
              agentError(
                "Failed to save: \(error.localizedDescription)",
                suggestion:
                  "Check directory permissions: ls -la \(outputPath.replacingOccurrences(of: "/[^/]+$", with: "", options: .regularExpression))"
              ))
            print("[exit:1 | \(formatDuration(duration))]")
          }
        } else {
          let duration = Date().timeIntervalSince(startDate)
          print(
            agentError(
              "Transcription failed",
              suggestion: "Check GROQ_API_KEY in config or try: --engine funasr"))
          print("[exit:1 | \(formatDuration(duration))]")
        }
      } else {
        // Use Python script (FunASR, WhisperX, etc.)
        guard let python = configManager.current.python_path,
          let script = configManager.current.transcribe_script
        else {
          print(
            agentError(
              "Python/Script path not configured",
              suggestion: "Run: ikit config && set python_path and transcribe_script"))
          print("[exit:1 | 0ms]")
          return
        }

        let out = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension(
          "json"
        )
        .path

        var scriptArgs = [script, audioPath, "--output", out, "--engine", engine]
        if language != "auto" {
          scriptArgs.append("--language")
          scriptArgs.append(language)
        }

        let result = Shell.run(python, args: scriptArgs)
        let duration = Date().timeIntervalSince(startDate)

        // Output Python script results (may include progress bars)
        if let output = result.output, !output.isEmpty {
          for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // Filter out progress bar noise for Agent consumption
            if !line.contains("%") && !line.contains("█") && !line.contains("▉") {
              print(line)
            }
          }
        }

        if result.exitCode == 0 {
          if FileManager.default.fileExists(atPath: out) {
            agentOutput("Saved to: \(out)", exitCode: 0, duration: duration)
          } else {
            agentOutput("Transcription complete", exitCode: 0, duration: duration)
          }
        } else {
          print(
            agentError(
              "Transcription failed (exit \(result.exitCode))",
              suggestion: "Check Python script logs or try: --engine groq"))
          print("[exit:\(result.exitCode) | \(formatDuration(duration))]")
        }
      }

    case "tts":
      // TTS: Text-to-Speech for Markdown files
      // Uses SwiftEdgeTTS (pure Swift, no Python dependencies)
      let startDate = Date()

      // Progressive --help: no markdown file provided
      if args.count < 3 {
        print(
          agentError(
            "tts: usage: tts <markdown-file> [-o output.mp3] [--voice NAME] [--preview] [--streaming]",
            suggestion: "ikit tts README.md -o intro.mp3 --voice zh-CN-XiaoxiaoNeural"))
        print("[exit:1 | 0ms]")
        return
      }

      let mdFile = args[2]

      // Validate file exists with remediation
      guard FileManager.default.fileExists(atPath: mdFile) else {
        let suggestion =
          mdFile.hasSuffix(".md")
          ? "Check file path: ls -l \(mdFile)" : "Markdown files must have .md extension"
        print(agentError("File not found: \(mdFile)", suggestion: suggestion))
        print("[exit:1 | 0ms]")
        return
      }

      // Read and clean markdown content
      guard let content = try? String(contentsOfFile: mdFile, encoding: .utf8) else {
        print(
          agentError(
            "Failed to read file: \(mdFile)",
            suggestion: "Check file encoding (must be UTF-8) and permissions"))
        print("[exit:1 | 0ms]")
        return
      }

      // Simple markdown cleaning (remove YAML frontmatter, code blocks)
      let lines = content.split(separator: "\n")
      var cleanedLines: [String] = []
      var inYaml = false
      var yamlCount = 0
      var inCodeBlock = false

      for line in lines {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
          yamlCount += 1
          if yamlCount == 1 {
            inYaml = true
            continue
          }
          if yamlCount == 2 {
            inYaml = false
            continue
          }
        }
        if inYaml { continue }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          inCodeBlock.toggle()
          continue
        }
        if inCodeBlock { continue }
        // Remove markdown symbols
        var cleaned =
          line
          .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
          .replacingOccurrences(of: "\\*\\*", with: "", options: .regularExpression)
          .replacingOccurrences(of: "__", with: "", options: .regularExpression)
          .replacingOccurrences(of: "`", with: "")
          .replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty {
          cleanedLines.append(cleaned)
        }
      }

      let cleanedText = cleanedLines.joined(separator: "\n")

      // Get voice parameter
      let voice = getStringParam("--voice") ?? "zh-CN-XiaoxiaoNeural"

      // Determine output path
      let timestamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: ".", with: "-")
        .dropLast(3)
      let defaultOutput = "/tmp/md-tts-\(timestamp).mp3"
      let outputPath = getStringParam("-o") ?? defaultOutput
      let outputURL = URL(fileURLWithPath: outputPath)

      // Preview mode
      if args.contains("--preview") || args.contains("-p") {
        let origLines = lines.count
        let cleanLinesCount = cleanedLines.count
        let ratio = origLines > 0 ? Double(cleanLinesCount) / Double(origLines) * 100 : 0
        print("Cleaning: \(mdFile)")
        print("Statistics:")
        print("  Lines:   \(origLines) → \(cleanLinesCount) (\(String(format: "%.1f", ratio))%)")
        print()
        print("Preview (first 10 lines):")
        print("  CLEANED TEXT:")
        print("  " + String(repeating: "-", count: 60))
        for line in cleanedLines.prefix(10) {
          print("  \(line.prefix(60))")
        }
        let duration = Date().timeIntervalSince(startDate)
        print("[exit:0 | \(formatDuration(duration))]")
        return
      }

      // Generate TTS
      let ttsService = EdgeTTSService()

      // 分段处理长文本（每段约 500 字符）
      let maxChunkLength = 500
      var chunks: [String] = []
      var index = cleanedText.startIndex

      while index < cleanedText.endIndex {
        let end =
          cleanedText.index(index, offsetBy: maxChunkLength, limitedBy: cleanedText.endIndex)
          ?? cleanedText.endIndex
        chunks.append(String(cleanedText[index..<end]))
        index = end
      }

      Logger.info("   Split into \(chunks.count) chunk(s)")

      let outputDir = outputURL.deletingLastPathComponent()
      let baseName = outputURL.deletingPathExtension().lastPathComponent

      // Streaming mode: chunk 1 边收边写，完成后立即播放，然后 chunk 2
      if args.contains("--streaming") {
        try? await synthesizeAndPlayStreaming(
          chunks: chunks,
          voice: voice,
          outputDir: outputDir,
          baseName: baseName
        )
        return
      }

      // 传统模式：等待所有合成完成
      var chunkFiles: [URL] = []

      for (index, chunk) in chunks.enumerated() {
        do {
          let chunkURL = outputDir.appendingPathComponent("\(baseName)-\(index + 1).mp3")
          try await ttsService.synthesize(
            text: chunk,
            voice: voice,
            outputURL: chunkURL
          )
          chunkFiles.append(chunkURL)

          // 短暂延迟，避免请求过快
          try await Task.sleep(nanoseconds: 500_000_000)  // 0.5秒
        } catch {
          print("[stderr] Chunk \(index + 1) failed: \(error)")
        }
      }

      if chunkFiles.isEmpty {
        let duration = Date().timeIntervalSince(startDate)
        print(
          agentError(
            "No audio data generated", suggestion: "Check voice name with: ikit tts --help"))
        print("[exit:1 | \(formatDuration(duration))]")
        return
      }

      // 列出生成的文件并提供播放命令
      for (index, file) in chunkFiles.enumerated() {
        print("[\(index + 1)] \(file.path)")
      }

      let playCmd = "mpv " + chunkFiles.map { $0.path }.joined(separator: " ")
      agentOutput(
        "TTS: \(chunkFiles.count) files. Play: \(playCmd)", exitCode: 0,
        duration: Date().timeIntervalSince(startDate))

    case "health":
      let h = HealthTool()
      h.requestAuthorization()

    default: printHelp(for: nil)
    }
  }

  // MARK: - TTS Streaming Helpers

  /// 键盘按键常量
  private enum KeyCode: UInt8 {
    case space = 32
    case q = 113
  }

  /// 流式播放：边合成边播放，0秒开始，支持键盘控制
  static func synthesizeAndPlayStreaming(
    chunks: [String],
    voice: String,
    outputDir: URL,
    baseName: String
  ) async throws {
    guard !chunks.isEmpty else { return }

    // 确保 output 目录存在
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    Logger.info("🔊 Streaming mode: synthesis + playback parallel...")
    print()

    let ttsService = EdgeTTSService()

    // 并行合成所有 chunks
    var synthesizedFiles: [(Int, URL)] = []

    await withTaskGroup(of: (Int, URL?).self) { group in
      for (offset, chunk) in chunks.enumerated() {
        let chunkIndex = offset + 1
        group.addTask {
          let chunkURL = outputDir.appendingPathComponent("\(baseName)-\(chunkIndex).mp3")
          do {
            try await ttsService.synthesize(text: chunk, voice: voice, outputURL: chunkURL)
            Logger.info("   ✅ Chunk \(chunkIndex)/\(chunks.count) ready")
            return (chunkIndex, chunkURL)
          } catch {
            Logger.error("   ❌ Chunk \(chunkIndex) failed: \(error)")
            return (chunkIndex, nil)
          }
        }
      }

      // 收集结果并按索引排序
      var results: [(Int, URL?)] = []
      for await result in group {
        results.append(result)
      }
      results.sort { $0.0 < $1.0 }

      for (index, url) in results {
        if let url = url {
          synthesizedFiles.append((index, url))
        }
      }
    }

    // 播放所有文件
    let urls = synthesizedFiles.map { $0.1 }
    try await playWithKeyboardControl(files: urls)
    print("Streaming complete: \(urls.count) chunks played")
  }

  /// 使用 AVPlayer 播放
  /// 控制: space=暂停, q=退出
  static func playWithKeyboardControl(files: [URL]) async throws {
    guard !files.isEmpty else { return }

    print("   🎮 Controls: space=暂停, q=退出")

    let player = AVPlayer()
    var currentIndex = 0
    var isPaused = false
    var shouldStop = false

    // 播放当前文件
    func playCurrent() {
      let file = files[currentIndex]
      let item = AVPlayerItem(url: file)
      player.replaceCurrentItem(with: item)
      player.play()
      isPaused = false
      print("   ▶️ [\(currentIndex + 1)/\(files.count)] \(file.lastPathComponent)")
    }

    // 使用 continuation 等待用户退出
    await withCheckedContinuation { continuation in
      // 监听播放完成
      var observer: NSObjectProtocol?
      observer = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: nil,
        queue: .main
      ) { _ in
        if shouldStop { return }
        currentIndex += 1
        if currentIndex < files.count {
          playCurrent()
        } else {
          print("   ✅ 播放完成 (按 q 退出)")
        }
      }

      // 确保观察者被清理
      defer {
        if let observer = observer {
          NotificationCenter.default.removeObserver(observer)
        }
      }

      playCurrent()

      // 后台线程监听键盘输入
      Thread {
        // 设置 stdin 为非阻塞（使用 Darwin fcntl）
        let flags = fcntl(STDIN_FILENO, F_GETFL, 0)
        fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)

        let stdin = FileHandle.standardInput
        while !shouldStop {
          let data = stdin.availableData
          if !data.isEmpty, let char = data.first {
            DispatchQueue.main.async {
              switch char {
              case KeyCode.space.rawValue:
                if isPaused {
                  player.play()
                  isPaused = false
                  print("   ▶️ 继续")
                } else {
                  player.pause()
                  isPaused = true
                  print("   ⏸ 暂停")
                }
              case KeyCode.q.rawValue:
                print("   ⏹ 停止")
                shouldStop = true
                continuation.resume()
              default:
                break
              }
            }
          }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }.start()
    }
  }

  // MARK: - Agent CLI Helper Functions

  /// Format duration for Agent cost awareness
  private static func formatDuration(_ t: TimeInterval) -> String {
    if t < 1 { return "\(Int(t*1000))ms" }
    if t < 60 { return String(format: "%.1fs", t) }
    return "\(Int(t))s"
  }

  /// Agent-friendly output with metadata
  static func agentOutput(_ result: String, exitCode: Int = 0, duration: TimeInterval = 0) {
    print(result)
    print("[exit:\(exitCode) | \(formatDuration(duration))]")
  }

  /// Agent-friendly error with remediation suggestion
  static func agentError(_ message: String, suggestion: String? = nil) -> String {
    var result = "[error] \(message)"
    if let s = suggestion {
      result += "\n💡 Try: \(s)"
    }
    return result
  }

  /// Unified JSON output wrapper
  static func jsonOutput(_ data: [String: Any], exitCode: Int = 0, duration: TimeInterval = 0)
    -> String
  {
    var output: [String: Any] = [
      "status": exitCode == 0 ? "success" : "error",
      "data": data,
      "metadata": [
        "exit": exitCode,
        "duration_ms": Int(duration * 1000),
      ],
    ]
    if let json = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
      let jsonStr = String(data: json, encoding: .utf8)
    {
      return jsonStr
    }
    return "{}"
  }

  static func printHelp(for command: String?) {
    let helpText: String
    switch command {
    case "task":
      helpText =
        "Task: list [--json], new <title> [--due=\"YYYY-MM-DD HH:mm\"] [--priority=N] [--notes=\"text\"], complete <query> [--id], delete <query> [--id] [--dry-run]"
    case "cal": helpText = "Calendar: list [--json], new <title> <YYYY-MM-DD HH:mm>, delete <title>"
    case "note":
      helpText =
        "Note: sync [path] [--folder=NAME] [--since=TIME], ls [path] <folder> [--json], search [path] <keyword> [--folder=NAME] [--json], new/append/update/delete/move [path] <folder> <title> [<content>|<target-folder>]"
    case "ocr": helpText = "OCR: <image-path> - Extract text from image file"
    case "photo":
      helpText =
        "Photo: list [--json] [--screenshots] [--favorites] [--last N], ocr [<assetId>] [--screenshots --last N]"
    case "contact": helpText = "Contact: search <name> [--json]"
    case "sc": helpText = "Shortcuts: list, run <name> [input]"
    case "meet":
      helpText =
        "Meet: daemon [--mic-only|--system-only] [--interval=N] <outDir>, transcribe <audio>, process <json/txt...> <outDir>"
    case "timer":
      helpText = """
        Timer: Schedule notifications and automation
          new      --time HH:MM [--daily] [--date YYYY-MM-DD] [--weekday N]
                    [--session SESSION_ID] [--pwd PWD] [--open FILE]... [--with APP] [--run CMD]
                    [--then-run CMD] [--terminal APP] [--title TITLE] [--message MSG]
          resume   --time HH:MM [--date DATE] [--session SESSION_ID] [--pwd PWD] [--title TITLE]
          list                     List all timers
          cancel   <identifier>     Cancel a timer
          logs     [<identifier>]   Show execution logs

        Examples:
          ikit timer new --time 09:00 --daily --title "Daily Standup"
          ikit timer resume --time 16:30 --session abc123 --pwd ~/Work/project --title "Continue coding"
          ikit timer new --time 10:00 --weekday 1 --open agenda.md --open notes.txt
          ikit timer list
          ikit timer cancel timer-daily-0900
        """
    case "transcribe":
      helpText = """
        Transcribe: Audio-to-text using ASR engines
          <audio-file> [--language zh|en|auto] [--engine groq|funasr]

        Options:
          --language <code>   Language code (zh, en, auto). Default: auto
          --engine <name>     ASR engine (groq, funasr). Default: groq

        Engines:
          groq    Fast cloud-based whisper-large-v3 (requires API key)
          funasr  Local FunASR model for Chinese (best accuracy, slower)

        Examples:
          ikit transcribe recording.m4a
          ikit transcribe meeting.mp3 --language zh --engine groq
          ikit transcribe call.wav --engine funasr
        """
    case "tts":
      helpText = """
        TTS: Text-to-Speech for Markdown files
          <file.md> [--preview] [--play|--streaming] [--voice <name>] [-o <output.mp3>]

        Options:
          --preview, -p      Show cleaning preview (no TTS generation)
          --play             Auto-play all chunks after generation
          --streaming        Streaming playback (first chunk ready = play starts)
          --voice <name>     Specify voice (default: zh-CN-XiaoxiaoNeural)
          -o <path>          Output file path

        Playback controls (streaming mode):
          Space: pause/resume    q: quit

        Examples:
          ikit tts article.md --preview
          ikit tts article.md --play
          ikit tts article.md --streaming    # Start ASAP, background synthesis
          ikit tts article.md --voice zh-CN-YunxiNeural --streaming
        """
    case "config": helpText = "Config: init, show"
    case "doctor":
      helpText = """
        Doctor: System health check
          Checks Python, dependencies, and model cache status
        """
    case "health":
      helpText = """
        Health: ⚠️ Not available in CLI mode
          HealthKit requires an App Bundle with proper entitlements.
          CLI binaries cannot receive TCC authorization prompts from macOS.
          Use iPhone/Apple Watch Health app or a native macOS app instead.
        """
    default:
      helpText = """
        iKit v\(VERSION) - Apple Ecosystem CLI for Agents

        Apple Data:
          notes      — Notes (sync, list, search, create, update, delete, move, read)
          tasks      — Reminders (list, create, complete, delete)
          calendar   — Calendar (list, create, delete)
          photos     — Photos (list, ocr, search)
          contacts   — Contacts (search)
          health     — ⚠️ Not available (requires App Bundle)

        Productivity:
          meet       — Meeting recording (start, transcribe, process)
          timer      — Timers (new, list, cancel, logs)

        AI/Media:
          transcribe — ASR transcription (groq, funasr)
          tts        — Text-to-Speech for Markdown
          ocr        — Image OCR

        System:
          config     — Configuration management
          doctor     — System health check
          init       — Initialize iKit

        Use 'ikit <module> --help' for details.
        """
    }
    print(helpText)
  }
}

// Top-level code to start the app (since this is main.swift)
// Setup signal handlers before entering async context
setupSignalHandlers()

await App.main()
