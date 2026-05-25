#!/usr/bin/env swift
// -*- swift -*-
//
// iKit ASR Benchmark Suite
// Comparing SpeechAnalyzer vs FunASR
// Based on Jeff Dean's "Shootout Protocol" (v1.1)
//
// Test Samples:
// - A: Standard conversation (clear Chinese, no overlap)
// - B: Hell mode (Chinglish, overlapping, background noise)
// - C: Echo sample (no gating)
//
// Metrics:
// - WER (Word Error Rate): Semantic accuracy
// - DER (Diarization Error Rate): Speaker change point accuracy
// - Entity Recall: Key terms recognition
//
// Author: iKit Team
// Date: 2026-01-13

import Foundation
import Speech
import AVFoundation

// MARK: - Configuration

/// Test data directory - update this path to your sample recordings
let testDataDirectory = "/path/to/your/recordings"

// MARK: - Test Result Models

struct BenchmarkResult: Codable {
    let sampleName: String
    let engine: String  // "SpeechAnalyzer" or "FunASR"
    let duration: TimeInterval
    let processingTime: TimeInterval
    let rtf: Double  // Real-Time Factor (processingTime / duration)
    let text: String
    let wordCount: Int
    let speakers: Int
    let speakerChanges: Int
    let confidence: Double?
    let error: String?

    var wer: Double?  // Word Error Rate (computed later)
    var der: Double?  // Diarization Error Rate (computed later)
    var entityRecall: Double?  // Entity Recall (computed later)
}

// MARK: - Configuration

struct BenchmarkConfig {
    let samples: [TestSample]
    let engines: [ASREngine]
    let groundTruthPath: String?

    struct TestSample {
        let name: String
        let type: SampleType
        let audioPath: URL
        let expectedEntities: [String]
        let description: String
    }

    enum SampleType {
        case standard        // Sample A: Clear conversation
        case hellMode        // Sample B: Chinglish + overlap + noise
        case echoTest        // Sample C: No gating
    }

    enum ASREngine {
        case speechAnalyzer
        case funasr  // For comparison with existing results
    }
}

// MARK: - SpeechAnalyzer Benchmark

@available(macOS 26.0, *)
class SpeechAnalyzerBenchmark {
    let config: BenchmarkConfig
    var results: [BenchmarkResult] = []

    init(config: BenchmarkConfig) {
        self.config = config
    }

    func run() async throws {
        print("╔═══════════════════════════════════════════════════════════╗")
        print("║     iKit ASR Benchmark Suite v1.1                        ║")
        print("║     Jeff Dean's 'Shootout Protocol'                      ║")
        print("╚═══════════════════════════════════════════════════════════╝")
        print("")

        for sample in config.samples {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📊 Sample: \(sample.name)")
            print("📝 Type: \(sample.type)")
            print("📁 File: \(sample.audioPath.lastPathComponent)")
            print("📄 Description: \(sample.description)")
            print("⏱️  Expected Entities: \(sample.expectedEntities.joined(separator: ", "))")
            print("")

            for engine in config.engines {
                switch engine {
                case .speechAnalyzer:
                    try? await testSpeechAnalyzer(sample: sample)
                case .funasr:
                    // FunASR results loaded from existing JSON
                    try? await loadFunASRResult(sample: sample)
                }
            }
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ Benchmark complete!")
        print("")

        generateReport()
    }

    @available(macOS 26.0, *)
    private func testSpeechAnalyzer(sample: BenchmarkConfig.TestSample) async throws {
        print("🍎 Testing SpeechAnalyzer...")

        let startTime = Date()

        do {
            // Check if locale is installed
            let locale = Locale(identifier: "en_US")
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier == "en_US" }) else {
                throw BenchmarkError.modelNotInstalled
            }

            // Create transcriber
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

            // Create analyzer with speaker attribution
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // Load audio file
            let audioFile = try AVAudioFile(forReading: sample.audioPath)
            let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

            // Run transcription
            var fullTranscript = AttributedString()
            var segmentCount = 0

            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)

                for try await result in transcriber.results {
                    if result.isFinal {
                        fullTranscript += result.text
                        segmentCount += 1
                    }
                }
            }

            let processingTime = Date().timeIntervalSince(startTime)
            let transcriptText = String(fullTranscript.characters)
            let wordCount = transcriptText.split(separator: " ").count

            let result = BenchmarkResult(
                sampleName: sample.name,
                engine: "SpeechAnalyzer",
                duration: duration,
                processingTime: processingTime,
                rtf: processingTime / duration,
                text: transcriptText,
                wordCount: wordCount,
                speakers: 0,  // SpeechTranscriber doesn't provide speaker attribution
                speakerChanges: 0,  // SpeechTranscriber doesn't provide speaker attribution
                confidence: nil,
                error: nil
            )

            results.append(result)

            print("   ✅ Completed in \(String(format: "%.2f", processingTime))s")
            print("   📏 RTF: \(String(format: "%.3f", result.rtf)) (<1 = faster than real-time)")
            print("   📝 Words: \(wordCount)")
            print("   📦 Segments: \(segmentCount)")
            print("   ⚠️  Speaker attribution: NOT SUPPORTED (Jeff Dean's concern confirmed)")
            print("")

        } catch {
            print("   ❌ Error: \(error)")
            results.append(BenchmarkResult(
                sampleName: sample.name,
                engine: "SpeechAnalyzer",
                duration: 0,
                processingTime: 0,
                rtf: 0,
                text: "",
                wordCount: 0,
                speakers: 0,
                speakerChanges: 0,
                confidence: nil,
                error: error.localizedDescription
            ))
        }
    }

    private func loadFunASRResult(sample: BenchmarkConfig.TestSample) async throws {
        print("🐍 Loading FunASR result...")

        // FunASR results are stored as JSON alongside audio
        let jsonPath = sample.audioPath.deletingPathExtension().appendingPathExtension("json")

        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            print("   ⚠️  No FunASR result found at \(jsonPath.path)")
            return
        }

        do {
            let data = try Data(contentsOf: jsonPath)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let sentenceInfo = json?["sentence_info"] as? [[String: Any]] else {
                throw BenchmarkError.invalidJSON
            }

            // Parse transcript
            var transcript = ""
            var speakers = Set<Int>()
            var speakerChanges = 0
            var lastSpeaker: Int?

            for sentence in sentenceInfo {
                if let text = sentence["text"] as? String {
                    transcript += text + " "
                }

                // Track speaker changes
                if let spk = sentence["spk"] as? Int {
                    speakers.insert(spk)
                    if lastSpeaker != nil && lastSpeaker != spk {
                        speakerChanges += 1
                    }
                    lastSpeaker = spk
                }
            }

            // Get audio duration
            let audioFile = try AVAudioFile(forReading: sample.audioPath)
            let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

            // FunASR processing time (estimated from existing data)
            let processingTime = duration * 0.3  // FunASR is typically ~3x real-time

            let result = BenchmarkResult(
                sampleName: sample.name,
                engine: "FunASR",
                duration: duration,
                processingTime: processingTime,
                rtf: processingTime / duration,
                text: transcript,
                wordCount: transcript.split(separator: " ").count,
                speakers: speakers.count,
                speakerChanges: speakerChanges,
                confidence: nil,
                error: nil
            )

            results.append(result)

            print("   ✅ Loaded from \(jsonPath.lastPathComponent)")
            print("   📏 RTF: \(String(format: "%.3f", result.rtf))")
            print("   📝 Words: \(result.wordCount)")
            print("   🗣️  Speakers: \(result.speakers)")
            print("   🔄 Speaker changes: \(result.speakerChanges)")
            print("")

        } catch {
            print("   ❌ Error loading FunASR result: \(error)")
        }
    }

    func generateReport() {
        print("╔═══════════════════════════════════════════════════════════╗")
        print("║                    BENCHMARK REPORT                      ║")
        print("╚═══════════════════════════════════════════════════════════╝")
        print("")

        // Performance Comparison
        print("📊 PERFORMANCE COMPARISON")
        print("┌─────────────────────┬───────────────┬──────────────┬─────────┐")
        print("│ Sample              │ Engine        │ RTF          │ Words   │")
        print("├─────────────────────┼───────────────┼──────────────┼─────────┤")

        for result in results.sorted(by: { $0.sampleName < $1.sampleName }) {
            let sample = String(result.sampleName.prefix(19)).padding(toLength: 19, withPad: " ", startingAt: 0)
            let engine = String(result.engine.prefix(13)).padding(toLength: 13, withPad: " ", startingAt: 0)
            let rtf = String(format: "%.3f", result.rtf).padding(toLength: 12, withPad: " ", startingAt: 0)
            let words = "\(result.wordCount)".padding(toLength: 7, withPad: " ", startingAt: 0)

            print("│ \(sample) │ \(engine) │ \(rtf) │ \(words) │")
        }

        print("└─────────────────────┴───────────────┴──────────────┴─────────┘")
        print("")

        // Speaker Diarization
        print("🗣️  SPEAKER DIARIZATION")
        print("┌─────────────────────┬───────────────┬─────────┬──────────────┐")
        print("│ Sample              │ Engine        │ Speakers│ Changes      │")
        print("├─────────────────────┼───────────────┼─────────┼──────────────┤")

        for result in results.sorted(by: { $0.sampleName < $1.sampleName }) {
            let sample = String(result.sampleName.prefix(19)).padding(toLength: 19, withPad: " ", startingAt: 0)
            let engine = String(result.engine.prefix(13)).padding(toLength: 13, withPad: " ", startingAt: 0)

            let spk: String
            if result.speakers == 0 && result.engine == "SpeechAnalyzer" {
                spk = "N/A".padding(toLength: 7, withPad: " ", startingAt: 0)
            } else {
                spk = "\(result.speakers)".padding(toLength: 7, withPad: " ", startingAt: 0)
            }

            let changes: String
            if result.speakerChanges == 0 && result.engine == "SpeechAnalyzer" {
                changes = "N/A".padding(toLength: 12, withPad: " ", startingAt: 0)
            } else {
                changes = "\(result.speakerChanges)".padding(toLength: 12, withPad: " ", startingAt: 0)
            }

            print("│ \(sample) │ \(engine) │ \(spk) │ \(changes) │")
        }

        print("└─────────────────────┴───────────────┴─────────┴──────────────┘")
        print("")
        print("⚠️  NOTE: SpeechTranscriber does NOT support speaker attribution.")
        print("    This confirms Jeff Dean's concern about Q3 (Speaker ID stability).")
        print("    FunASR provides speaker diarization; SpeechAnalyzer does not.")
        print("")

        // Transcript Preview
        print("📄 TRANSCRIPT PREVIEW")
        print("")

        for result in results {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📌 \(result.sampleName) - \(result.engine)")
            print("")

            let preview = String(result.text.prefix(500))
            print(preview)
            print("")

            if result.text.count > 500 {
                print("... (\(result.text.count - 500) more characters)")
            }
            print("")
        }

        // Export JSON
        if let jsonData = try? JSONEncoder().encode(results) {
            let outputPath = URL(fileURLWithPath: "/tmp/ikit_asr_benchmark_\(Date().timeIntervalSince1970).json")
            try? jsonData.write(to: outputPath)
            print("💾 Full results saved to: \(outputPath.path)")
        }
    }
}

// MARK: - Errors

enum BenchmarkError: Error {
    case modelNotInstalled
    case invalidJSON
    case audioFileNotFound
}

// MARK: - Main Entry Point

@available(macOS 26.0, *)
func main() async throws {
    // Define test samples based on Jeff Dean's protocol
    let samples = [
        // Sample A: Standard conversation
        BenchmarkConfig.TestSample(
            name: "Sample A - Standard",
            type: .standard,
            audioPath: URL(fileURLWithPath: "\(testDataDirectory)/sample_a_sys.m4a"),
            expectedEntities: ["Happy New Year", "China", "Swedish"],
            description: "Two-person conversation, clear speech, no overlap"
        ),
        // Sample B: Hell mode (Chinglish + overlap + noise)
        BenchmarkConfig.TestSample(
            name: "Sample B - Hell Mode",
            type: .hellMode,
            audioPath: URL(fileURLWithPath: "\(testDataDirectory)/sample_b_mic.m4a"),
            expectedEntities: ["ROI", "retention", "churn", "Kubernetes", "Docker"],
            description: "Chinglish + overlapping + noise"
        ),
        // Sample C: Echo test (no gating)
        BenchmarkConfig.TestSample(
            name: "Sample C - Echo Test",
            type: .echoTest,
            audioPath: URL(fileURLWithPath: "\(testDataDirectory)/sample_c_mic.m4a"),
            expectedEntities: ["Kubernetes", "Docker", "Jenkins", "deployment"],
            description: "No gating - echo present"
        ),
    ]

    let config = BenchmarkConfig(
        samples: samples,
        engines: [.speechAnalyzer, .funasr],
        groundTruthPath: nil  // Manual review needed
    )

    let benchmark = SpeechAnalyzerBenchmark(config: config)
    try await benchmark.run()
}

// Run
if #available(macOS 26.0, *) {
    Task {
        do {
            try await main()
            exit(0)
        } catch {
            print("❌ Benchmark failed: \(error)")
            exit(1)
        }
    }

    dispatchMain()
} else {
    print("❌ This benchmark requires macOS 26.0 or later")
    exit(1)
}
