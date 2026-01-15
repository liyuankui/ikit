import Foundation
import EventKit
import Contacts
import Cocoa
import Photos
import Vision
import Speech
import ScreenCaptureKit
import AVFoundation
import AudioToolbox

// MARK: - Global Signal Handling
/// Global flag for graceful shutdown (non-isolated)
nonisolated(unsafe) var isShuttingDown = false

/// Setup signal handlers for graceful shutdown
func setupSignalHandlers() {
    // SIGQUIT (Ctrl+\) is more reliable than SIGINT (Ctrl+C) for graceful shutdown
    signal(SIGQUIT) { _ in
        isShuttingDown = true
        print("\n🛑 Shutdown signal received (Ctrl+\\), finishing current work...")
        fflush(stdout)
    }
    // Also handle SIGTERM for `killall -TERM ikit`
    signal(SIGTERM) { _ in
        isShuttingDown = true
        print("\n🛑 Termination signal received, finishing current work...")
        fflush(stdout)
    }
    // Ignore SIGINT (Ctrl+C) to prevent immediate termination
    signal(SIGINT, SIG_IGN)
}

// MARK: - Logger
struct Logger {
    static var verbose = false
    private static var logFile: FileHandle?

    /// 初始化日志文件（在指定目录）
    static func setupLogging(outputDir: String? = nil) {
        // 确定日志文件位置
        let logPath: String
        if let dir = outputDir {
            logPath = URL(fileURLWithPath: dir).appendingPathComponent("ikit.log").path
        } else {
            // 默认位置 ~/recordings/ikit.log
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            logPath = URL(fileURLWithPath: home + "/recordings").appendingPathComponent("ikit.log").path
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

// MARK: - Config
struct Config: Codable {
    var notes_root: String?
    var python_path: String?
    var transcribe_script: String?
    var ollama_url: String?
    var ollama_model: String?
    var screenshot_interval: Double?
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
            screenshot_interval: 10.0
        )
        load()
    }
    
    func load() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".config/ikit/config.json")
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
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

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceAddress) == noErr else {
            Logger.debug("AEC: Could not get default output device")
            return false
        }

        var name: CFString = "" as CFString
        propertySize = UInt32(MemoryLayout<CFString>.size)
        propertyAddress.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name) == noErr {
            let deviceName = name as String
            let isBuiltInSpeaker = deviceName.localizedCaseInsensitiveContains("built-in") ||
                                   deviceName.localizedCaseInsensitiveContains("内建") ||
                                   deviceName.localizedCaseInsensitiveContains("扬声器") ||
                                   deviceName.localizedCaseInsensitiveContains("MacBook Pro") ||
                                   (deviceName.localizedCaseInsensitiveContains("MacBook") &&
                                    deviceName.localizedCaseInsensitiveContains("Speakers"))

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
        // Use input format's sample rate, but lower bitrate for storage
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.error("Failed to create recording format")
            return
        }

        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
        } catch {
            Logger.error("Failed to create audio file: \(error)")
            return
        }

        // Install tap to record audio
        // Use larger buffer for stability
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
            Logger.info("   Sample rate: \(inputFormat.sampleRate) Hz")
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

        let mixer = AVAudioMixerNode()
        mixerNode = mixer
        engine.attach(mixer)
        engine.connect(inputNode, to: mixer, format: inputFormat)

        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.error("Failed to create recording format")
            return
        }

        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
        } catch {
            Logger.error("Failed to create audio file: \(error)")
            return
        }

        mixer.installTap(onBus: 0, bufferSize: 8192, format: fileFormat) { [weak self] buffer, time in
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
            Logger.info("   Sample rate: \(inputFormat.sampleRate) Hz")
            Logger.info("   Bit rate: 64kbps (speech optimized)")
            Logger.info("   AEC: Disabled (external audio output)")
        } catch {
            Logger.error("Failed to start audio engine: \(error)")
        }
    }

    func stop() {
        if let engine = audioEngine {
            // Remove tap first to stop receiving audio buffers
            if let mixer = mixerNode {
                mixer.removeTap(onBus: 0)
                Logger.info("🎙️ MicRecorder: Audio tap removed")
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

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let err = error { Logger.debug("Mic recording finished with info: \(err)") }
    }
}

// MARK: - Screenshot Metadata
struct ScreenshotMetadata: Codable {
    let timestamp: Int
    let path: String
    var ocrText: String
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
    private var outputDir: String = ""
    private var audioSampleCount = 0
    private var screenFrameCount = 0
    private var screenshots: [ScreenshotMetadata] = []
    private var ocrTasks: [Task<Void, Never>] = []

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
        "飞书"
    ]

    func start(outputURL: URL) async throws {
        // Reset state for new recording session
        self.audioSampleCount = 0
        self.screenFrameCount = 0
        self.startTime = nil
        self.recordingStartTime = nil
        self.outputDir = outputURL.deletingLastPathComponent().path
        Logger.info("🎬 SystemRecorder: Starting...")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

        // Jeff: 强制使用全屏捕获，不使用窗口过滤
        // 这确保捕获所有系统音频，不管来源是哪个应用
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        Logger.info("🎬 SystemRecorder: Using FULL SCREEN capture (all apps audio included)")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false  // Jeff: 改为 false 进行测试
        config.width = 1920; config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        // Note: Screen capture is enabled by adding .screen stream output

        if FileManager.default.fileExists(atPath: outputURL.path) { try? FileManager.default.removeItem(at: outputURL) }

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 128000
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
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
        let metadataUrl = URL(fileURLWithPath: outputDir).appendingPathComponent("screenshots_metadata.json")
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
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
            let now = Date()
            if now.timeIntervalSince(lastScreenshotTime) >= 10 {
                lastScreenshotTime = now
                saveScreenshot(buffer: sampleBuffer)
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

        // Create metadata entry
        let metadata = ScreenshotMetadata(timestamp: relativeTimestamp, path: url.path, ocrText: "", names: [])
        screenshots.append(metadata)

        // Launch OCR task asynchronously
        let task = Task {
            let ocrText = await performOCR(on: url.path)
            let names = extractNames(from: ocrText)
            await MainActor.run {
                if let index = self.screenshots.firstIndex(where: { $0.timestamp == relativeTimestamp }) {
                    self.screenshots[index].ocrText = ocrText
                    self.screenshots[index].names = names
                }
                Logger.debug("🔍 OCR completed for shot_\(fileTimestamp): \(ocrText.prefix(50))...")
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
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return "" }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings?.joined(separator: " ") ?? "")
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }
}

@available(macOS 13.0, *) // MARK: - Meet Session (Single Recording)
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
                stopTask = Task { await self.stop(micPath: micPath, sysPath: sysPath, outputDir: outputDir) }
            }
        }
        termSource.setEventHandler {
            if !isStopping {
                Logger.info("\n🛑 Stopping recording...")
                isStopping = true
                stopTask = Task { await self.stop(micPath: micPath, sysPath: sysPath, outputDir: outputDir) }
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
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
        process.arguments = [
            transcribeScript,
            "-o", transcriptPath.path,
            "--engine", "mlx",
            "--language", "auto",
            micPath.path,
            sysPath.path
        ]

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

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceAddress) == noErr else {
            return
        }

        var name: CFString = "" as CFString
        propertySize = UInt32(MemoryLayout<CFString>.size)
        propertyAddress.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name) == noErr {
            let deviceName = name as String
            let isBuiltInSpeaker = deviceName.localizedCaseInsensitiveContains("built-in") ||
                                   deviceName.localizedCaseInsensitiveContains("内建") ||
                                   deviceName.localizedCaseInsensitiveContains("扬声器") ||
                                   deviceName.localizedCaseInsensitiveContains("MacBook Pro") ||
                                   (deviceName.localizedCaseInsensitiveContains("MacBook") &&
                                    deviceName.localizedCaseInsensitiveContains("Speakers"))

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

                        let hoursOld = Calendar.current.dateComponents([.hour], from: modDate, to: Date()).hour ?? 0
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

@available(macOS 13.0, *) // MARK: - Daemon
enum RecordingMode {
    case both    // Mic + System audio (default)
    case micOnly // Mic only
    case sysOnly // System audio only
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

    init(mode: RecordingMode = .both) {
        self.mode = mode
    }

    func run(outputDir: String) async {
        // Setup logging to file
        Logger.setupLogging(outputDir: outputDir)
        defer { Logger.closeLogging() }

        Logger.info("👻 Daemon started. Output: \(outputDir)")

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
        Logger.info("⚠️  Files will be auto-saved every 15 minutes")
        Logger.info("⚠️  Wait for 'All recordings saved and finalized' before force quitting")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Run the main loop
        await runLoop(outputDir: outputDir, fm: fm)

        // Normal exit cleanup
        Logger.info("✅ All recordings saved and finalized")
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

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceAddress) == noErr else {
            Logger.debug("Failed to get default output device")
            return
        }

        // Get device name
        var name: CFString = "" as CFString
        propertySize = UInt32(MemoryLayout<CFString>.size)
        propertyAddress.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name) == noErr {
            let deviceName = name as String
            Logger.debug("🔊 Audio output device: \(deviceName)")
            // Check if it's built-in speaker
            let isBuiltInSpeaker = deviceName.localizedCaseInsensitiveContains("built-in") ||
                                   deviceName.localizedCaseInsensitiveContains("内建") ||
                                   deviceName.localizedCaseInsensitiveContains("扬声器") ||
                                   deviceName.localizedCaseInsensitiveContains("MacBook Pro") ||
                                   (deviceName.localizedCaseInsensitiveContains("MacBook") &&
                                    deviceName.localizedCaseInsensitiveContains("Speakers"))

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

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceAddress) == noErr else {
            return false
        }

        var name: CFString = "" as CFString
        propertySize = UInt32(MemoryLayout<CFString>.size)
        propertyAddress.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(deviceAddress, &propertyAddress, 0, nil, &propertySize, &name) == noErr {
            let deviceName = name as String
            return deviceName.localizedCaseInsensitiveContains("built-in") ||
                   deviceName.localizedCaseInsensitiveContains("内建") ||
                   deviceName.localizedCaseInsensitiveContains("扬声器")
        }
        return false
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

            // 15 mins block with periodic shutdown checks (1 second intervals)
            let totalDuration: UInt64 = 900 * 1_000_000_000  // 15 minutes in nanoseconds
            let checkInterval: UInt64 = 1_000_000_000        // 1 second in nanoseconds
            var elapsed: UInt64 = 0

            while elapsed < totalDuration && !isShuttingDown {
                do {
                    let remaining = min(totalDuration - elapsed, checkInterval)
                    try await Task.sleep(nanoseconds: remaining)
                    elapsed += remaining
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
            let ts = micPath.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_mic", with: "")
            let finalPath = URL(fileURLWithPath: micPath.deletingLastPathComponent().path)
                .appendingPathComponent("\(ts)_merged.m4a")

            processSegment(micPath: micPath, sysPath: sysPath, finalPath: finalPath, fm: fm)
        }

        Logger.info("✅ All recordings saved")
    }

    private func processSegment(micPath: URL, sysPath: URL, finalPath: URL, fm: FileManager) {
        queue.async {
            // Merge logic based on mode
            let ffmpeg = "/usr/local/bin/ffmpeg"

            // Determine which files exist based on mode
            let hasMic = (self.mode == .both || self.mode == .micOnly) && fm.fileExists(atPath: micPath.path)
            let hasSys = (self.mode == .both || self.mode == .sysOnly) && fm.fileExists(atPath: sysPath.path)

            if hasMic && hasSys {
                // Both files exist - keep them separate for Python aggressive_gating
                // Don't merge at all! Let Python handle gating with dual-track input.
                // Just log that both files are ready for processing.
                Logger.info("✅ Dual-track recording ready for Python gating")
                // Keep both mic.m4a and sys.m4a files unchanged
                // Python script will read them directly and apply aggressive_gating
            } else if hasMic {
                // Only mic file - rename to merged
                try? fm.moveItem(at: micPath, to: finalPath)
            } else if hasSys {
                // Only sys file - rename to merged
                try? fm.moveItem(at: sysPath, to: finalPath)
            }

            Logger.info("✅ Saved: \(finalPath.lastPathComponent)")
        }
    }
}

// MARK: - Notes Bridge
class NotesBridge: NSObject {
    static let shared = NotesBridge()
    private override init() { super.init() }

    private func executeAppleScript(_ script: String) -> String? {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary? 
        let output = appleScript?.executeAndReturnError(&error)
        if let err = error {
            Logger.debug("AppleScript Error: \(err)")
            return nil
        }
        return output?.stringValue
    }

    private func escape(_ string: String) -> String {
        let bs = String(Character(UnicodeScalar(92)!))
        let qt = String(Character(UnicodeScalar(34)!))
        return string.replacingOccurrences(of: bs, with: bs+bs).replacingOccurrences(of: qt, with: bs+qt)
    }

    func listAllNotesSafe() -> [(id: String, name: String, path: String, modDate: Date?)] {
        guard let countStr = executeAppleScript("tell application \"Notes\" to count of notes"),
              let total = Int(countStr) else { return [] } 
        
        Logger.info("🔍 Scanning \(total) notes (Safe Mode)...")
        var results: [(String, String, String, Date?)] = []
        let f = DateFormatter(); f.dateFormat = "yyyy-M-d H:m:s"
        
        for i in 1...total {
            if i % 10 == 0 { print(".", terminator: ""); fflush(stdout) }
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
        print("\n")
        return results
    }

    func listRecentlyModified(since date: Date) -> [(id: String, name: String, path: String, modDate: Date?)] {
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
        guard let out = executeAppleScript(script) else { return [] }
        if out.starts(with: "Error:") { Logger.debug(out); return [] } 
        
        let f = DateFormatter(); f.dateFormat = "yyyy-M-d H:m:s"
        return out.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap { item in
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
        return output.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
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
        let f = DateFormatter(); f.dateFormat = "yyyy-M-d H:m:s"
        return output.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
            let p = $0.components(separatedBy: "|||")
            return p.count >= 2 ? (p[0], f.date(from: p[1])) : nil
        }
    }

    func readNote(id: String) -> String? {
        executeAppleScript("tell application \"Notes\" to get plaintext of note id \"\(id)\"" )
    }
    func readNote(name: String, fromFolderId folderId: String) -> String? {
        let escName = escape(name)
        return executeAppleScript("tell application \"Notes\" to get plaintext of first note in folder id \"\(folderId)\" whose name is \"\(escName)\"" )
    }
    
    func createNote(name: String, folderId: String, content: String) -> String {
        let escName = escape(name); let escContent = escape(content)
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
        let bs = String(Character(UnicodeScalar(92)!))
        let escContent = escape(content).replacingOccurrences(of: bs + "n", with: "<br>")
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
        let bs = String(Character(UnicodeScalar(92)!))
        let escContent = escape(content).replacingOccurrences(of: bs + "n", with: "<br>")
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
}

// MARK: - Notes Tool
class NotesTool {
    let bridge = NotesBridge.shared
    let fm = FileManager.default
    
    func sync(targetDir: String) {
        Logger.info("🧠 Smart Sync to: \(targetDir)")
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let timeFile = (targetDir as NSString).appendingPathComponent(".last_sync_time")
        var lastSync = Date(timeIntervalSince1970: 0)
        let hasHistory = fm.fileExists(atPath: timeFile)
        
        if hasHistory, let ts = try? String(contentsOfFile: timeFile, encoding: .utf8),
           let t = TimeInterval(ts.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastSync = Date(timeIntervalSince1970: t)
        }
        
        let notes: [(id: String, name: String, path: String, modDate: Date?)]
        
        if !hasHistory {
            Logger.info("🐢 First run detected. Using Safe Scan (this may take a while)...")
            notes = bridge.listAllNotesSafe()
        } else {
            let checkDate = lastSync.addingTimeInterval(-60)
            Logger.info("🚀 Incremental check since: \(checkDate)")
            notes = bridge.listRecentlyModified(since: checkDate)
        }
        
        if !notes.isEmpty {
            Logger.info("⚡️ Syncing \(notes.count) notes...")
            for (nid, name, folderPath, _) in notes {
                let folderName = folderPath.isEmpty ? "Unknown" : folderPath
                let fullFolderPath = (targetDir as NSString).appendingPathComponent(folderName)
                try? fm.createDirectory(atPath: fullFolderPath, withIntermediateDirectories: true)
                
                // Use Short ID in filename to prevent collisions
                let shortId = String(nid.suffix(8)).replacingOccurrences(of: "/", with: "-")
                let safeName = name.replacingOccurrences(of: "/", with: ":")
                let filename = "\(safeName) [\(shortId)].md"
                let filePath = (fullFolderPath as NSString).appendingPathComponent(filename)
                
                Logger.info("  ⬇️ [\(folderName)] \(name)")
                
                if fm.fileExists(atPath: filePath) { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filePath) }
                if let content = bridge.readNote(id: nid) {
                    try? content.write(toFile: filePath, atomically: true, encoding: String.Encoding.utf8)
                    try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: filePath)
                }
            }
        } else { Logger.info("✅ Up to date.") }
        try? String(Date().timeIntervalSince1970).write(toFile: timeFile, atomically: true, encoding: String.Encoding.utf8)
    }
    
    func findFolderId(path: String) -> String? {
        let folders = bridge.listFoldersWithIds()
        return folders.first(where: { $0.path == path })?.id ?? folders.first(where: { $0.path.hasSuffix(path) })?.id
    }
    
    func create(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found: \(folder)"); return }
        let res = bridge.createNote(name: title, folderId: fid, content: content)
        if res == "success" { Logger.info("✅ Created."); sync(targetDir: targetDir) } else { Logger.error("Failed: \(res)") }
    }
    func append(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found: \(folder)"); return }
        let res = bridge.appendToNote(name: title, folderId: fid, content: content)
        if res == "success" { Logger.info("✅ Appended."); sync(targetDir: targetDir) } else { Logger.error("Failed: \(res)") }
    }
    func update(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found: \(folder)"); return }
        let res = bridge.updateNote(name: title, folderId: fid, content: content)
        if res == "success" { Logger.info("✅ Updated."); sync(targetDir: targetDir) } else { Logger.error("Failed: \(res)") }
    }
    func delete(targetDir: String, folder: String, title: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found: \(folder)"); return }
        let res = bridge.deleteNote(name: title, folderId: fid)
        if res == "success" {
            Logger.info("✅ Deleted.")
            let safeName = title.replacingOccurrences(of: "/", with: ":")
            let localPath = (targetDir as NSString).appendingPathComponent(folder).appending("/\(safeName).md")
            if fm.fileExists(atPath: localPath) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localPath)
                try? fm.removeItem(atPath: localPath)
            }
        } else { Logger.error("Failed: \(res)") }
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
        guard await checkPermission() else { return }
        let predicate = store.predicateForReminders(in: nil)
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: predicate) { r in c.resume(returning: r) } }
        guard let reminders = items else { return }
        let incomplete = reminders.filter { !$0.isCompleted }
        if json {
            let f = ISO8601DateFormatter()
            let dicts = incomplete.map { r -> [String: Any] in
                var d: String? = nil
                if let date = r.dueDateComponents?.date { d = f.string(from: date) }
                return ["id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar.title, "isCompleted": r.isCompleted, "priority": r.priority, "dueDate": d ?? NSNull()]
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for t in incomplete { Logger.info("[\(t.calendar.title)] \(t.title ?? "")") }
        }
    }
    func newTask(title: String, due: String? = nil, priority: Int? = nil, notes: String? = nil) async {
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
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                item.dueDateComponents = components
            } else {
                // 尝试 ISO8601 格式
                let isoFormatter = ISO8601DateFormatter()
                if let date = isoFormatter.date(from: due) {
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
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
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in c.resume(returning: r) } }
        let t = items?.first(where: { isId ? $0.calendarItemIdentifier == query : ($0.title == query && !$0.isCompleted) })
        if let t = t { t.isCompleted = true; try? store.save(t, commit: true); Logger.info("✅ Completed") } else { Logger.error("Not found") }
    }
    func deleteTask(query: String, isId: Bool, dryRun: Bool) async {
        guard await checkPermission() else { return }
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in c.resume(returning: r) } }
        let t = items?.first(where: { isId ? $0.calendarItemIdentifier == query : $0.title == query })
        if let t = t { if dryRun { Logger.info("⚠️ Dry-Run: \(t.title ?? "")") } else { try? store.remove(t, commit: true); Logger.info("✅ Deleted") } } else { Logger.error("Not found") }
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
        guard await checkPermission() else { Logger.error("Calendar access denied"); return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        if json {
            let f = ISO8601DateFormatter()
            let dicts = events.map { e -> [String: Any] in
                return ["id": e.eventIdentifier ?? "", "title": e.title ?? "", "start": f.string(from: e.startDate), "calendar": e.calendar.title]
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            for e in events { Logger.info("[\(e.calendar.title)] \(e.startDate) \(e.title ?? "")") }
        }
    }
    func newEvent(title: String, time: String) async {
        guard await checkPermission() else { return }
        let event = EKEvent(eventStore: store)
        event.title = title; event.calendar = store.defaultCalendarForNewEvents
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: time) {
            event.startDate = d; event.endDate = d.addingTimeInterval(3600)
            try? store.save(event, span: .thisEvent); Logger.info("✅ Created")
        } else { Logger.error("Invalid Time") }
    }
    func deleteEvent(title: String) async {
        guard await checkPermission() else { return }
        let start = Date(); let end = Calendar.current.date(byAdding: .day, value: 30, to: start)!
        if let e = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).first(where: { $0.title == title }) {
            try? store.remove(e, span: .thisEvent); Logger.info("✅ Deleted")
        } else { Logger.error("Not found") }
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
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys); req.predicate = CNContact.predicateForContacts(matchingName: query)
        var results: [[String: Any]] = []
        try? store.enumerateContacts(with: req) { c, _ in
            results.append(["id": c.identifier, "name": "\(c.givenName) \(c.familyName)", "phones": c.phoneNumbers.map { $0.value.stringValue }, "emails": c.emailAddresses.map { $0.value as String }])
        }
        if json {
            if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
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
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in c.resume(returning: s == .authorized || s == .limited) }
        }
    }
    
    private func fetchAssets(count: Int, screenshots: Bool, favorites: Bool) async -> [PhotoAsset] {
        guard await checkPermission() else { return [] } 
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        var predicates: [NSPredicate] = []
        if screenshots { predicates.append(NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)) }
        if favorites { predicates.append(NSPredicate(format: "isFavorite == YES")) }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var results: [PhotoAsset] = []
        assets.enumerateObjects { asset, _, _ in
            results.append(PhotoAsset(id: asset.localIdentifier, creationDate: asset.creationDate ?? Date(), pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, isFavorite: asset.isFavorite))
        }
        return results
    }
    
    func listRecent(count: Int = 10, screenshots: Bool = false, favorites: Bool = false, json: Bool = false) async {
        let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
        if json {
            let dicts = assets.map { ["id": $0.id, "date": ISO8601DateFormatter().string(from: $0.creationDate), "width": $0.pixelWidth, "height": $0.pixelHeight, "isFavorite": $0.isFavorite] }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for r in assets { Logger.info("🖼 ID: \(r.id)") }
        }
    }
    
    func batchOcr(count: Int, screenshots: Bool, favorites: Bool) async {
        let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
        if assets.isEmpty { Logger.info("No photos found."); return }
        Logger.info("🔄 Batch OCR for \(assets.count) images...")
        for asset in assets {
            Logger.info("\n📸 Photo: \(asset.id)")
            await ocr(assetId: asset.id)
        }
    }
    
    func ocr(assetId: String) async {
        guard await checkPermission() else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { Logger.error("Photo not found"); return }
        
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data = data, let source = CGImageSourceCreateWithData(data as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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

// MARK: - Shortcuts Tool
class ShortcutsTool {
    func listShortcuts() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(), let output = String(data: data, encoding: .utf8) { print(output) }
    }
    func runShortcut(name: String, input: String? = nil) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var args = ["run", name]; if let i = input { args.append(contentsOf: ["--input-text", i]) }
        p.arguments = args; try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Shell Helper
class Shell {
    static func run(_ command: String, args: [String]) -> (output: String?, error: String?, exitCode: Int32) {
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
            return (String(data: outData, encoding: .utf8), String(data: errData, encoding: .utf8), task.terminationStatus)
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

// MARK: - Secretary Tool
class SecretaryTool {
    let logger = Logger.self
    let configManager = ConfigManager.shared
    
    private func summarize(text: String, visualContext: String = "") async -> String {
        guard let urlStr = configManager.current.ollama_url,
              let url = URL(string: urlStr),
              let model = configManager.current.ollama_model else {
            return "⚠️ Config missing for Ollama"
        }
        
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = "你是一个专业的会议秘书。结合转录和截图生成一份精准的结构化纪要，尽可能使用真实姓名：\n\(text.prefix(12000))\n视觉上下文：\n\(visualContext)"
        
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let res = json["response"] as? String {
                return res
            }
        } catch {
            Logger.debug("Ollama Error: \(error)")
        }
        return "⚠️ Summarization failed."
    }
    
    private func performOCR(on imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return "" }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }
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
               let items = try? JSONDecoder().decode([FunASRItem].self, from: data) {
                content = formatDialogue(from: items)
            } else {
                content = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            }
            
            if content.isEmpty { continue }
            
            let fileDir = (file as NSString).deletingLastPathComponent
            let screenshots = (try? fm.contentsOfDirectory(atPath: fileDir))?
                .filter { $0.hasPrefix("shot_") && $0.hasSuffix(".jpg") }
                .sorted() ?? []
            
            var visualContext = ""
            // OCR first 10 screenshots to provide context
            for shot in screenshots.prefix(10) {
                let text = await performOCR(on: "\(fileDir)/\(shot)")
                visualContext += "Screenshot \(shot): \(text)\n"
            }
            
            let summary = await summarize(text: content, visualContext: visualContext)
            
            let dateStr = ISO8601DateFormatter().string(from: Date())
            let outPath = (outputDir as NSString).appendingPathComponent("\(dateStr)-\((file as NSString).lastPathComponent).md")
            
            try? summary.write(toFile: outPath, atomically: true, encoding: String.Encoding.utf8)
            Logger.info("✅ Saved to: \(outPath)")
        }
    }

    func transcribe(audioPath: String) async {
        guard let python = configManager.current.python_path,
              let script = configManager.current.transcribe_script else {
            Logger.error("Python/Script path not configured")
            return
        }
        
        let out = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension("json").path
        Logger.info("🎤 Transcribing (FunASR): \(audioPath)")
        
        _ = Shell.run(python, args: [script, audioPath, "--output", out])
    }
}

// MARK: - Main
struct App {
    static let VERSION = "2.6.0"

    static func main() async {
        let args = CommandLine.arguments; let configManager = ConfigManager.shared
        
        let json = args.contains("--json")
        let dryRun = args.contains("--dry-run")
        let isId = args.contains("--id")
        let isHelp = args.contains("--help") || args.contains("-h")
        
        // Photo flags
        let isScreenshots = args.contains("--screenshots")
        let isFavorites = args.contains("--favorites")
        
        // Init Logger
        if args.contains("-v") || args.contains("--verbose") { Logger.verbose = true }
        
        if args.contains("--version") { Logger.info("iKit version \(VERSION)"); return }
        
        if isHelp { printHelp(for: args.count > 1 ? args[1] : nil); return }
        guard args.count > 1 else { printHelp(for: nil); return }
        
        let cmd = args[1]; let sub = args.count > 2 ? args[2] : ""
        
        func getRoot() -> String? {
            if args.count > 3 && !args[3].starts(with: "-") { return args[3] }
            return configManager.current.notes_root?.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
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
        let count = getIntParam("--last") ?? 10
        
        switch cmd {
        case "config":
            if sub == "init" { configManager.save() }
            else if sub == "show" {
                let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(configManager.current), let str = String(data: data, encoding: .utf8) { print(str) }
            }
            else { print("Usage: ikit config [init|show]") }
            
        case "task":
            let t = RemindersTool()
            if sub == "list" { await t.listTasks(json: json) }
            else if sub == "new" && args.count > 3 {
                let title = args[3]
                let due = getStringParam("--due")
                let priority = getIntParam("--priority")
                let notes = getStringParam("--notes")
                await t.newTask(title: title, due: due, priority: priority, notes: notes)
            }
            else if sub == "complete" && args.count > 3 { await t.completeTask(query: args[3], isId: isId) }
            else if sub == "delete" && args.count > 3 { await t.deleteTask(query: args[3], isId: isId, dryRun: dryRun) }
            else { printHelp(for: "task") }
            
        case "cal":
            let t = CalendarTool()
            if sub == "list" { await t.listEvents(json: json) }
            else if sub == "new" && args.count > 4 { await t.newEvent(title: args[3], time: args[4]) }
            else if sub == "delete" && args.count > 3 { await t.deleteEvent(title: args[3]) }
            else { printHelp(for: "cal") }
            
        case "contact":
            if sub == "search" && args.count > 3 { await ContactsTool().search(query: args[3], json: json) }
            else { printHelp(for: "contact") }
            
        case "photo":
            let t = PhotoTool()
            if sub == "list" { await t.listRecent(count: count, screenshots: isScreenshots, favorites: isFavorites, json: json) }
            else if sub == "ocr" {
                if args.count > 3 && !args[3].starts(with: "-") { await t.ocr(assetId: args[3]) }
                else { await t.batchOcr(count: count, screenshots: isScreenshots, favorites: isFavorites) }
            } else { printHelp(for: "photo") }
            
        case "sc":
            let t = ShortcutsTool()
            if sub == "list" { t.listShortcuts() }
            else if sub == "run" && args.count > 3 { t.runShortcut(name: args[3], input: args.count > 4 ? args[4] : nil) }
            else { printHelp(for: "sc") }
            
        case "note":
            let t = NotesTool()
            guard let root = getRoot() else { Logger.error("Missing root"); return }
            if sub == "sync" { t.sync(targetDir: root) }
            else if sub == "new" && args.count > 6 { t.create(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "append" && args.count > 6 { t.append(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "update" && args.count > 6 { t.update(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "delete" && args.count > 5 { t.delete(targetDir: root, folder: args[4], title: args[5]) }
            else { printHelp(for: "note") }
            
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
                    let d = Daemon() // Reusing Daemon logic for simple record for now
                    let out = args[3]
                    // Ideally we should have a simple Recorder class distinct from Daemon
                    // But for now, user can use Daemon
                    print("Please use 'ikit meet daemon <outDir>' for continuous recording")
                } else {
                    print("Meeting recording requires macOS 13+")
                }
            } else if sub == "daemon" && args.count > 3 {
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

                    // Find output directory (first non-flag argument after "daemon")
                    let outputDir: String
                    if let dirIndex = args.firstIndex(where: { !$0.starts(with: "--") && args.firstIndex(of: $0) ?? 0 > 2 }) {
                        outputDir = args[dirIndex]
                    } else {
                        outputDir = args[3]  // Default to position 3
                    }

                    await Daemon(mode: mode).run(outputDir: outputDir)
                }
            } else if sub == "process" && args.count > 3 {
                // files...
                let outDir = args.last!.starts(with: "/") ? args.last! : (configManager.current.notes_root ?? ".")
                // files are from index 3 to end-1
                let files = Array(args[3..<args.count-1])
                await t.process(files: files, outputDir: outDir)
            } else { print("Usage: ikit meet [start|process|transcribe|daemon]") }
            
        default: printHelp(for: nil)
        }
    }

    static func printHelp(for command: String?) {
        let helpText: String
        switch command {
        case "task": helpText = "Task: list [--json], new <title> [--due=\"YYYY-MM-DD HH:mm\"] [--priority=N] [--notes=\"text\"], complete <query> [--id], delete <query> [--id] [--dry-run]"
        case "cal":  helpText = "Calendar: list [--json], new <title> <YYYY-MM-DD HH:mm>, delete <title>"
        case "note": helpText = "Note: sync [path], new [path] <folder> <title> <content>, append/update/delete ..."
        case "photo": helpText = "Photo: list [--json] [--screenshots] [--favorites] [--last N], ocr [<assetId>] [--screenshots --last N]"
        case "contact": helpText = "Contact: search <name> [--json]"
        case "sc": helpText = "Shortcuts: list, run <name> [input]"
        case "meet": helpText = "Meet: daemon [--mic-only|--system-only] <outDir>, transcribe <audio>, process <json/txt...> <outDir>"
        case "config": helpText = "Config: init, show"
        default: helpText = "iKit v\(VERSION) | Usage: ikit [task|cal|note|photo|contact|sc|meet|config] [command] [args] [--json] [--id] [--dry-run] [--help] [-v]"
        }
        print(helpText)
    }
}

// Top-level code to start the app (since this is main.swift)
// Setup signal handlers before entering async context
setupSignalHandlers()

await App.main()