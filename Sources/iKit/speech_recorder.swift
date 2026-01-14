import Foundation
import Speech
import AVFoundation

/// SpeechAnalyzer-based recorder for iKit
/// Uses Apple's new on-device ASR (faster than Whisper!)
@available(macOS 26.0, *)
class AppleSpeechRecorder {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var task: Task<Void, Never>?

    struct TranscriptionResult {
        let text: AttributedString
        let isFinal: Bool
        let timestamp: CMTimeRange
    }

    /// Transcribe an audio file using SpeechAnalyzer
    func transcribe(url: URL, locale: Locale = .current) async throws -> AttributedString {
        // Check if transcription is supported
        guard await SpeechTranscriber.supportedLocales.contains(locale) else {
            throw SpeechError.localeNotSupported
        }

        // Check if model is installed
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(locale) {
            // Download model
            try await downloadModel(for: locale)
        }

        // Create transcriber
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Create analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Create audio file
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.fileFormat

        // Get best audio format for transcriber
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechError.modelDownloadFailed
        }

        // Create input stream
        let (inputStream, inputBuilder) = AsyncStream<Speech.AnalyzerInput>.makeStream()

        // Start analyzer
        try await analyzer.start(inputSequence: inputStream)

        // Convert and stream audio
        let converter = AVAudioConverter(from: format, to: bestFormat)!

        var fullTranscript: AttributedString = ""

        // Process results
        for try await result in transcriber.results {
            if result.isFinal {
                fullTranscript += result.text
            }
        }

        // Read audio file and stream to analyzer
        // ... (audio conversion logic)

        // Finalize
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return fullTranscript
    }

    private func downloadModel(for locale: Locale) async throws {
        // Speech framework automatically downloads models on first use
        // No manual download needed for macOS 14+
    }

    enum SpeechError: Error {
        case localeNotSupported
        case modelDownloadFailed
    }
}
