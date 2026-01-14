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

        // 创建/清空日志文件
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logFile = FileHandle(forWritingAtPath: logPath)
        logFile?.writeToCurrentPosition(Data("=== iKit Session: \(Date()) ===\n".utf8))
    }

    static func log(_ message: String, level: String = "INFO") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"
        print(logMessage, terminator: "")
        logFile?.writeToCurrentPosition(Data(logMessage.utf8))
    }

    static func info(_ message: String) { log(message, level: "INFO") }
    static func warn(_ message: String) { log(message, level: "WARN") }
    static func error(_ message: String) { log(message, level: "ERROR") }
    static func debug(_ message: String) { if verbose { log(message, level: "DEBUG") } }

    static func close() {
        logFile?.closeFile()
    }
}

// MARK: - Notes AppleScript Bridge
struct NotesApp {
    static func sync(outputDir: String, incremental: Bool = false) async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let notesRoot = outputDir.isEmpty ? "\(home)/Notebooks/AppleNotes" : outputDir

        Logger.info("📝 Notes: Starting sync to \(notesRoot)")

        // 创建目录结构
        try fm.createDirectory(atPath: notesRoot, withIntermediateDirectories: true)

        let script = """
        tell application "Notes"
            set noteList to every note
            set noteData to {}

            repeat with n in noteList
                set noteId to id of n
                set noteName to name of n
                set noteBody to body of n
                set noteMod to modification date of n
                set folderName to name of container of n

                set noteInfo to noteId & "|||" & folderName & "|||" & noteName & "|||" & noteBody & "|||" & (noteMod as string)
                set end of noteData to noteInfo
            end repeat

            set AppleScript's text item delimiters to ";;;"
            set allNotes to noteData as string
            set AppleScript's text item delimiters to ""

            return allNotes
        end tell
        """

        let result = try await runAppleScript(script)
        let notes = result.split(separator: ";;;").map { String($0) }

        Logger.info("📝 Notes: Fetched \(notes.count) notes from Apple Notes")

        var syncedCount = 0
        var skippedCount = 0

        for noteData in notes {
            let parts = noteData.components(separatedBy: "|||")
            guard parts.count == 5 else { continue }

            let id = parts[0]
            let folder = parts[1]
            let name = parts[2]
            let body = parts[3]
            let dateStr = parts[4]

            // 创建文件夹路径
            let folderPath = "\(notesRoot)/\(folder)"
            try fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

            // 文件名（移除不合法字符）
            let safeName = name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileName = "\(safeName).\(id).md"
            let filePath = "\(folderPath)/\(fileName)"

            // 增量同步：检查文件是否已存在且未修改
            if incremental {
                if fm.fileExists(atPath: filePath) {
                    let attrs = try fm.attributesOfItem(atPath: filePath)
                    if let modDate = attrs[.modificationDate] as? Date {
                        // 如果文件已存在且时间戳匹配，跳过
                        skippedCount += 1
                        continue
                    }
                }
            }

            // 写入文件
            let content = """
            # \(name)

            > ID: \(id)
            > Folder: \(folder)
            > Modified: \(dateStr)

            ---

            \(body)

            ---
            Generated by iKit v2.6.0
            """

            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            syncedCount += 1
        }

        Logger.info("✅ Notes: Synced \(syncedCount) notes (skipped \(skippedCount))")
    }

    static func create(folder: String, name: String, body: String) async throws {
        let script = """
        tell application "Notes"
            tell container "\(folder)"
                create note name "\(name.replacingOccurrences(of: "\"", with: "\\\""))" body "\(body.replacingOccurrences(of: "\"", with: "\\\""))"
            end tell
        end tell
        """
        _ = try await runAppleScript(script)
        Logger.info("✅ Notes: Created note '\(name)' in folder '\(folder)'")
    }

    static func append(folder: String, name: String, text: String) async throws {
        let script = """
        tell application "Notes"
            set n to first note of container "\(folder)" whose name = "\(name.replacingOccurrences(of: "\"", with: "\\\""))"
            set body of n to (body of n) & "\(text.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        _ = try await runAppleScript(script)
        Logger.info("✅ Notes: Appended to '\(name)' in folder '\(folder)'")
    }

    private static func runAppleScript(_ script: String) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - EventKit Bridge (Tasks & Calendar)
struct EventKitBridge {
    static let store = EKEventStore()

    static func requestAccess() async throws {
        try await store.requestFullAccessToEvents()
        try await store.requestFullAccessToReminders()
    }

    // MARK: Tasks
    static func listTasks() async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [])
        let reminders = try await store.reminders(matching: predicate)
        return reminders ?? []
    }

    static func newTask(title: String, due: Date? = nil, notes: String? = nil) async throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let due = due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        if let notes = notes {
            reminder.notes = notes
        }
        reminder.calendar = store.defaultCalendarForNewReminders()

        try store.save(reminder, commit: true)
        Logger.info("✅ Task: Created '\(title)'")
    }

    static func completeTask(title: String) async throws -> Bool {
        let predicate = store.predicateForReminders(in: [])
        let reminders = try await store.reminders(matching: predicate)
        guard let reminder = reminders?.first(where: { $0.title == title && !$0.isCompleted }) else {
            Logger.warn("Task '\(title)' not found or already completed")
            return false
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        Logger.info("✅ Task: Completed '\(title)'")
        return true
    }

    // MARK: Calendar Events
    static func listEvents(days: Int = 7) async throws -> [EKEvent] {
        let calendar = Calendar.current
        let startDate = Date()
        let endDate = calendar.date(byAdding: .day, value: days, to: startDate)!

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)

        return events.sorted { $0.startDate < $1.startDate }
    }

    static func newEvent(title: String, start: Date, end: Date, notes: String? = nil) async throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        try store.save(event, span: .thisEvent)
        Logger.info("✅ Calendar: Created event '\(title)'")
    }
}

// MARK: - Photos Batch OCR
struct PhotosOCR {
    static func batchOCR(screenshots: Bool = true, favorites: Bool = false, limit: Int = 100) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            Logger.error("Photos: Permission denied")
            return
        }

        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var fetchResult: PHFetchResult<PHAsset>
        if screenshots {
            fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        } else if favorites {
            fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        } else {
            fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        }

        Logger.info("🖼 Photos: Found \(fetchResult.count) photos")

        let requestHandler = VNImageRequestHandler()
        var ocrCount = 0

        for i in 0..<fetchResult.count {
            let asset = fetchResult.object(at: i)

            // Filter by type
            if screenshots && asset.mediaSubtypes != .photoScreenshot { continue }
            if favorites && !asset.isFavorite { continue }

            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat

            await withCheckedContinuation { continuation in
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard let data = data else {
                        continuation.resume()
                        return
                    }

                    let request = VNRecognizeTextRequest { request, error in
                        guard let observations = request.results as? [VNRecognizedTextObservation] else {
                            continuation.resume()
                            return
                        }

                        if !observations.isEmpty {
                            Logger.info("📸 \(asset.localIdentifier): \(observations.count) text regions")
                            ocrCount += 1
                        }

                        continuation.resume()
                    }

                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false

                    try? requestHandler.perform([VNImageRequestHandler(data: data, options: [:])])
                }
            }

            if ocrCount >= limit { break }
        }

        Logger.info("✅ Photos: OCR completed on \(ocrCount) photos")
    }

    static func search(text: String) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            Logger.error("Photos: Permission denied")
            return []
        }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: nil)
        var results: [PHAsset] = []

        Logger.info("🔍 Photos: Searching \(fetchResult.count) photos for '\(text)'")

        for i in 0..<fetchResult.count {
            let asset = fetchResult.object(at: i)

            let options = PHImageRequestOptions()
            options.isSynchronous = true

            await withCheckedContinuation { continuation in
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard let data = data else {
                        continuation.resume()
                        return
                    }

                    let request = VNRecognizeTextRequest { request, error in
                        guard let observations = request.results as? [VNRecognizedTextObservation] else {
                            continuation.resume()
                            return
                        }

                        for obs in observations {
                            if let top = obs.topCandidates(1).first {
                                if top.string.contains(text) {
                                    results.append(asset)
                                    break
                                }
                            }
                        }

                        continuation.resume()
                    }

                    request.recognitionLevel = .fast
                    try? requestHandler.perform([VNImageRequestHandler(data: data, options: [:])])
                }
            }

            if results.count >= 100 { break }
        }

        Logger.info("✅ Photos: Found \(results.count) photos containing '\(text)'")
        return results
    }
}

// MARK: - Screen Recording (Dual-Track)
class SystemRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    private var config: SCStreamConfiguration?
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var audioSampleCount = 0

    let outputURL: URL
    let isSystemAudioOnly: Bool

    init(outputURL: URL, isSystemAudioOnly: Bool = false) {
        self.outputURL = outputURL
        self.isSystemAudioOnly = isSystemAudioOnly
        super.init()
    }

    func start() async throws {
        Logger.info("🎤 SystemRecorder: Starting (system audio only: \(isSystemAudioOnly))")

        // Setup AssetWriter
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        assetWriterInput?.expectsMediaDataInRealTime = true
        if let input = assetWriterInput, let writer = assetWriter {
            writer.add(input)
        }

        // Setup ScreenCaptureKit
        config = SCStreamConfiguration()
        config?.width = 1
        config?.height = 1
        config?.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config?.excludesMinimumFrameRate = true
        config?.queuesSampleBufferInBackground = true
        config?.includesApplicationAnnotations = false

        if isSystemAudioOnly {
            // Capture only system audio (no screen)
            config?.capturesAudio = true
            config?.capturesVideo = false
            Logger.info("🎤 SystemRecorder: System audio only mode (no screen capture)")
        } else {
            config?.capturesAudio = true
            config?.capturesVideo = false
        }

        let sharingPicker = SCSharePicker()
        filter = SCContentFilter(display: .main, excludingWindows: [])

        guard let config = config, let filter = filter else {
            Logger.error("❌ SystemRecorder: Failed to create config or filter")
            return
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try await stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)

        try stream?.startCapture()
        assetWriter?.startWriting()
        // ⭐ 修复：立即启动 session，不等待首个样本
        assetWriter?.startSession(atSourceTime: .zero)
        Logger.info("🎬 SystemRecorder: AssetWriter started")
        Logger.info("🎬 SystemRecorder: Session started at kCMTimeZero")
    }

    func stop() async {
        Logger.info("🛑 SystemRecorder: Stopping...")
        stream?.stopCapture()

        if let input = assetWriterInput, input.isReadyForMoreMediaData {
            input.markAsFinished()
        }

        await assetWriter?.finishWriting()
        Logger.info("✅ SystemRecorder: Stopped (total \(audioSampleCount) audio samples)")
    }

    // MARK: - SCStreamOutput
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        if type == .audio {
            Task { @MainActor in
                self.audioSampleCount += 1
                if self.startTime == nil {
                    self.startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    // startSession 已经在 startWriting() 后立即调用，不再重复
                }
                if let input = self.assetWriterInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
            }
        }
    }

    // MARK: - SCStreamDelegate
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.error("❌ SystemRecorder: Stream stopped with error: \(error.localizedDescription)")
    }
}

class MicRecorder: NSObject {
    private var audioEngine: AVAudioEngine?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var converter: AVAssetWriterInputPixelBufferAdaptor?
    private var audioFile: AVAudioFile?
    private var recordingStartTime: Date?

    let outputURL: URL
    private(set) var isRecording = false

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        Logger.info("🎤 MicRecorder: Starting")

        // 删除旧文件
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        // 创建临时文件（录制格式：PCM 24-bit）
        let tempURL = outputURL.deletingPathExtension().appendingPathExtension("temp")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }

        // 设置音频会话
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default, options: [])
        try audioSession.setActive(true)

        // 配置 AVAudioEngine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            Logger.error("❌ MicRecorder: Failed to create AVAudioEngine")
            return
        }

        // 配置输入节点
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 创建临时文件（使用 AVAudioFile）
        fm.createFile(atPath: tempURL.path, contents: nil)
        audioFile = try AVAudioFile(forWriting: tempURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])

        // 安装录音 tap
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // 写入临时文件
            guard let audioFile = self.audioFile else { return }
            do {
                try audioFile.write(from: buffer)
            } catch {
                Logger.error("❌ MicRecorder: Failed to write audio buffer: \(error)")
            }
        }

        // 启动录音引擎
        try audioEngine.start()
        recordingStartTime = Date()
        isRecording = true

        Logger.info("🎤 MicRecorder: Recording to \(tempURL.path)")
    }

    func stop() async {
        Logger.info("🛑 MicRecorder: Stopping...")

        guard let audioEngine = audioEngine else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // 关闭临时文件
        audioFile?.close()

        // 转换临时文件为 M4A
        let tempURL = outputURL.deletingPathExtension().appendingPathExtension("temp")
        await convertToM4A(tempURL: tempURL, outputURL: outputURL)

        // 删除临时文件
        try? FileManager.default.removeItem(at: tempURL)

        isRecording = false
        Logger.info("✅ MicRecorder: Stopped (duration: \(recordingStartTime?.distance(to: Date()) ?? 0)s)")
    }

    private func convertToM4A(tempURL: URL, outputURL: URL) async {
        let asset = AVAsset(url: tempURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            Logger.error("❌ MicRecorder: Failed to create export session")
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            let duration = CMTimeGetSeconds(asset.duration)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            let bitRate = fileSize > 0 ? Int64(fileSize * 8 / Int64(duration)) : 0
            Logger.info("✅ MicRecorder: M4A created: \(outputURL.path) (duration: \(String(format: "%.1f", duration))s, size: \(fileSize / 1024)KB, bitrate: \(bitRate) kbps)")
        case .failed:
            Logger.error("❌ MicRecorder: Export failed: \(exportSession.error?.localizedDescription ?? "Unknown error")")
        default:
            Logger.warn("⚠️ MicRecorder: Export status: \(exportSession.status.rawValue)")
        }
    }
}

// MARK: - Daemon Recording
class RecordingDaemon {
    private var systemRecorder: SystemRecorder?
    private var micRecorder: MicRecorder?
    private var outputDir: String
    private var isRunning = false
    private var activeSegment: (mic: String, sys: String, final: String)?
    private var task: Task<Void, Never>?

    init(outputDir: String) {
        self.outputDir = outputDir
    }

    func start(systemOnly: Bool = false, micOnly: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true

        Logger.info("🚀 Daemon: Starting in \(systemOnly ? "system-only" : micOnly ? "mic-only" : "dual-track") mode")

        task = Task {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            while !Task.isCancelled && !isShuttingDown {
                // 创建新的 segment
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let sysPath = "\(outputDir)/\(timestamp)_sys.m4a"
                let micPath = "\(outputDir)/\(timestamp)_mic.m4a"
                let finalPath = "\(outputDir)/\(timestamp)_final.m4a"

                activeSegment = (mic: micPath, sys: sysPath, final: finalPath)

                // 启动录音
                await startRecording(systemOnly: systemOnly, micOnly: micOnly, sysPath: sysPath, micPath: micPath)

                // 录制 15 分钟（每 15 分钟切片）
                Logger.info("⏰ Recording segment: \(timestamp)")

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

                // 处理 segment
                await stopRecording()
                if let seg = activeSegment {
                    processSegment(micPath: seg.mic, sysPath: seg.sys, finalPath: seg.final, fm: fm)
                }

                activeSegment = nil

                // 5 seconds gap between segments
                Logger.info("⏸️  Gap: 5 seconds before next segment...")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            isRunning = false
            Logger.info("✅ Daemon: Stopped")
        }

        await task?.value
    }

    func stop() async {
        Logger.info("🛑 Daemon: Stop requested...")
        isShuttingDown = true
        await task?.value
    }

    private func startRecording(systemOnly: Bool, micOnly: Bool, sysPath: String, micPath: String) async {
        if !micOnly {
            systemRecorder = SystemRecorder(outputURL: URL(fileURLWithPath: sysPath), isSystemAudioOnly: systemOnly)
            try? await systemRecorder?.start()
        }

        if !systemOnly {
            micRecorder = MicRecorder(outputURL: URL(fileURLWithPath: micPath))
            try? await micRecorder?.start()
        }
    }

    private func stopRecording() async {
        await systemRecorder?.stop()
        await micRecorder?.stop()
        systemRecorder = nil
        micRecorder = nil
    }

    private func processSegment(micPath: String, sysPath: String, finalPath: String, fm: FileManager) {
        let sysExists = fm.fileExists(atPath: sysPath)
        let micExists = fm.fileExists(atPath: micPath)

        let sysSize = (try? fm.attributesOfItem(atPath: sysPath)[.size] as? Int64) ?? 0
        let micSize = (try? fm.attributesOfItem(atPath: micPath)[.size] as? Int64) ?? 0

        Logger.info("📊 Segment files:")
        Logger.info("  - sys: \(sysPath) (\(sysSize) bytes, exists: \(sysExists))")
        Logger.info("  - mic: \(micPath) (\(micSize) bytes, exists: \(micExists))")
    }
}

// MARK: - CLI
struct App {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printUsage()
            exit(1)
        }

        let command = args[1]

        switch command {
        case "notes":
            await handleNotes(args: Array(args.dropFirst(2)))

        case "tasks":
            await handleTasks(args: Array(args.dropFirst(2)))

        case "events":
            await handleEvents(args: Array(args.dropFirst(2)))

        case "photos":
            await handlePhotos(args: Array(args.dropFirst(2)))

        case "meet":
            await handleMeet(args: Array(args.dropFirst(2)))

        default:
            Logger.error("❌ Unknown command: \(command)")
            printUsage()
            exit(1)
        }

        Logger.close()
    }

    static func printUsage() {
        print("""
        iKit v2.6.0 - Apple Ecosystem Agent-Native CLI

        Usage:
          ikit <command> [options]

        Commands:
          notes                    Notes (备忘录)
            sync [dir]             同步所有 notes 到本地
            create <folder> <name> <body>  创建新 note
            append <folder> <name> <text>  追加内容到 note

          tasks                    Tasks (提醒事项)
            list                   列出所有 tasks
            new <title> [due]      创建新 task
            complete <title>       完成 task

          events                   Calendar (日历)
            list [days]            列出未来 events
            new <title> <start> <end>  创建新 event

          photos                   Photos (照片)
            ocr [--screenshots] [--favorites] [--limit N]  批量 OCR
            search <text>          搜索包含文字的照片

          meet                     Meet (会议助手)
            daemon <dir>           启动后台录音 (每 15 分钟切片)
              --system-only       只录系统音频
              --mic-only          只录麦克风

        Examples:
          ikit notes sync ~/Notebooks/AppleNotes
          ikit task new "提交代码" --due="tomorrow 21:00"
          ikit photos ocr --screenshots --limit 50
          ikit meet daemon ~/recordings

        Copyright © 2026 Kyle Li. All rights reserved.
        """)
    }

    // MARK: Notes Command
    static func handleNotes(args: [String]) async {
        guard args.count > 0 else {
            Logger.error("❌ Missing notes subcommand")
            return
        }

        let subcommand = args[0]

        switch subcommand {
        case "sync":
            let outputDir = args.count > 1 ? args[1] : ""
            let incremental = args.contains("--incremental")
            try? await NotesApp.sync(outputDir: outputDir, incremental: incremental)

        case "create":
            guard args.count >= 4 else {
                Logger.error("❌ Usage: ikit notes create <folder> <name> <body>")
                return
            }
            let folder = args[1]
            let name = args[2]
            let body = args[3]
            try? await NotesApp.create(folder: folder, name: name, body: body)

        case "append":
            guard args.count >= 4 else {
                Logger.error("❌ Usage: ikit notes append <folder> <name> <text>")
                return
            }
            let folder = args[1]
            let name = args[2]
            let text = args[3]
            try? await NotesApp.append(folder: folder, name: name, text: text)

        default:
            Logger.error("❌ Unknown notes subcommand: \(subcommand)")
        }
    }

    // MARK: Tasks Command
    static func handleTasks(args: [String]) async {
        try? await EventKitBridge.requestAccess()

        guard args.count > 0 else {
            Logger.error("❌ Missing tasks subcommand")
            return
        }

        let subcommand = args[0]

        switch subcommand {
        case "list":
            let tasks = try? await EventKitBridge.listTasks()
            tasks?.forEach { task in
                let status = task.isCompleted ? "✅" : "⏳"
                let due = task.dueDateComponents?.date?.description ?? "No due date"
                print("\(status) \(task.title) (due: \(due))")
            }

        case "new":
            guard args.count >= 2 else {
                Logger.error("❌ Usage: ikit tasks new <title> [--due=YYYY-MM-DD HH:MM]")
                return
            }
            let title = args[1]

            // 解析 --due 参数
            var dueDate: Date? = nil
            if let dueIdx = args.firstIndex(where: { $0.starts(with: "--due=") }) {
                let dueStr = args[dueIdx].replacingOccurrences(of: "--due=", with: "")
                let formatter = ISO8601DateFormatter()
                dueDate = formatter.date(from: dueStr)

                // 如果 ISO8601 解析失败，尝试自然语言解析
                if dueDate == nil {
                    let recognizer = NLLanguageRecognizer()
                    recognizer.processString(dueStr)
                    if let dominantLang = recognizer.dominantLanguage {
                        print("Detected language: \(dominantLang.rawValue)")
                    }
                }
            }

            // 如果没找到 due，尝试从参数中解析
            if dueDate == nil && args.count >= 4 {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                dueDate = dateFormatter.date(from: "\(args[2]) \(args[3])")
            }

            try? await EventKitBridge.newTask(title: title, due: dueDate)
            print(json: ["title": title, "due": dueDate?.description ?? "No due date"])

        case "complete":
            guard args.count >= 2 else {
                Logger.error("❌ Usage: ikit tasks complete <title>")
                return
            }
            let title = args[1]
            _ = try? await EventKitBridge.completeTask(title: title)

        default:
            Logger.error("❌ Unknown tasks subcommand: \(subcommand)")
        }
    }

    // MARK: Events Command
    static func handleEvents(args: [String]) async {
        try? await EventKitBridge.requestAccess()

        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            let days = args.count > 1 ? Int(args[1]) ?? 7 : 7
            let events = try? await EventKitBridge.listEvents(days: days)

            print(json: ["events": events?.map { [
                "title": $0.title,
                "start": $0.startDate.description,
                "end": $0.endDate.description,
                "location": $0.location ?? "",
                "notes": $0.notes ?? ""
            ]} ?? []])

        case "new":
            guard args.count >= 4 else {
                Logger.error("❌ Usage: ikit events new <title> <start> <end>")
                return
            }
            // TODO: Implement event creation
            Logger.warn("⚠️ Event creation not yet implemented")

        default:
            Logger.error("❌ Unknown events subcommand: \(subcommand)")
        }
    }

    // MARK: Photos Command
    static func handlePhotos(args: [String]) async {
        let subcommand = args.first ?? ""

        switch subcommand {
        case "ocr":
            let screenshots = args.contains("--screenshots")
            let favorites = args.contains("--favorites")
            var limit = 100

            if let limitIdx = args.firstIndex(where: { $0.starts(with: "--limit=") }) {
                let limitStr = args[limitIdx].replacingOccurrences(of: "--limit=", with: "")
                limit = Int(limitStr) ?? 100
            }

            try? await PhotosOCR.batchOCR(screenshots: screenshots, favorites: favorites, limit: limit)

        case "search":
            guard args.count >= 2 else {
                Logger.error("❌ Usage: ikit photos search <text>")
                return
            }
            let text = args[1]
            let results = try? await PhotosOCR.search(text: text)
            print(json: ["results": results?.map { [$0.localIdentifier] } ?? []])

        default:
            Logger.error("❌ Unknown photos subcommand: \(subcommand)")
        }
    }

    // MARK: Meet Command
    static func handleMeet(args: [String]) async {
        let subcommand = args.first ?? ""

        switch subcommand {
        case "daemon":
            guard args.count >= 2 else {
                Logger.error("❌ Usage: ikit meet daemon <output_dir>")
                return
            }

            let outputDir = args[1]
            let systemOnly = args.contains("--system-only")
            let micOnly = args.contains("--mic-only")

            let daemon = RecordingDaemon(outputDir: outputDir)

            // 设置日志
            Logger.setupLogging(outputDir: outputDir)

            Logger.info("🎙 Meet: Starting daemon mode...")
            Logger.info("📁 Output: \(outputDir)")
            Logger.info("⏱️  Segment duration: 15 minutes")
            Logger.info("🛑 Press Ctrl+\\ to stop recording and save files")

            await daemon.start(systemOnly: systemOnly, micOnly: micOnly)

        default:
            Logger.error("❌ Unknown meet subcommand: \(subcommand)")
        }
    }

    // MARK: JSON Output Helper
    static func print(json: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        if let str = String(data: data ?? Data(), encoding: .utf8) {
            print(str)
        }
    }
}

// MARK: - Top-level Entry Point
// Setup signal handlers before entering async context
setupSignalHandlers()

// Run the app
await App.main()
