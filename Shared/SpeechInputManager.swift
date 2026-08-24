//
//  SpeechInputManager.swift
//  Shared
//

import AVFoundation
import Foundation
import Speech

enum SpeechInputSupport {
    static var isAvailable: Bool {
        if #available(iOS 26, *) {
            return true
        }
        return false
    }
}

@available(iOS 26, *)
@MainActor
@Observable
final class SpeechInputManager {
    var isRecording = false
    var isPreparing = false
    var errorMessage: String?

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine = AVAudioEngine()
    private var outputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?

    private var prefixBeforeRecording = ""
    private var startedFromEmptyField = false
    private var finalizedTranscript = ""
    private var volatileTranscript = ""
    private var onTextUpdate: ((String) -> Void)?
    private var onAutoSend: (() -> Void)?

    func toggleRecording(
        currentText: String,
        onTextUpdate: @escaping (String) -> Void,
        onAutoSend: @escaping () -> Void
    ) {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording(currentText: currentText, onTextUpdate: onTextUpdate, onAutoSend: onAutoSend) }
        }
    }

    func startRecording(
        currentText: String,
        onTextUpdate: @escaping (String) -> Void,
        onAutoSend: @escaping () -> Void
    ) async {
        guard !isRecording, !isPreparing else { return }

        errorMessage = nil
        isPreparing = true
        self.onTextUpdate = onTextUpdate
        self.onAutoSend = onAutoSend

        prefixBeforeRecording = currentText
        startedFromEmptyField = currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        finalizedTranscript = ""
        volatileTranscript = ""

        do {
            guard await requestMicrophonePermission() else {
                errorMessage = "Microphone access is required for voice input."
                isPreparing = false
                return
            }

            try setUpAudioSession()
            try await setUpTranscriber()
            try await startAudioCapture()

            isRecording = true
            isPreparing = false
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            tearDown()
        }
    }

    func stopRecording() async {
        guard isRecording || isPreparing else { return }

        isRecording = false
        isPreparing = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        outputContinuation?.finish()
        outputContinuation = nil

        inputBuilder?.finish()
        inputBuilder = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Best-effort finalize; partial transcript may still be usable.
        }

        resultsTask?.cancel()
        resultsTask = nil
        captureTask?.cancel()
        captureTask = nil

        let finalText = composedInputText()
        onTextUpdate?(finalText)

        if startedFromEmptyField,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onAutoSend?()
        }

        tearDown()
    }

    // MARK: - Private

    private func tearDown() {
        transcriber = nil
        analyzer = nil
        analyzerFormat = nil
        inputBuilder = nil
        onTextUpdate = nil
        onAutoSend = nil
        finalizedTranscript = ""
        volatileTranscript = ""
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func setUpAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func setUpTranscriber() async throws {
        let locale = Locale.current
        let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)

        guard await isLocaleSupported(locale) else {
            throw SpeechInputError.localeNotSupported
        }

        try await ensureModel(for: module)

        transcriber = module
        analyzer = SpeechAnalyzer(modules: [module])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation
        try await analyzer?.start(inputSequence: inputSequence)

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in module.results {
                    await self.handleTranscriptionResult(result)
                }
            } catch {
                await MainActor.run {
                    if self.errorMessage == nil {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleTranscriptionResult(_ result: DictationTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalizedTranscript += text
            volatileTranscript = ""
        } else {
            volatileTranscript = text
        }
        onTextUpdate?(composedInputText())
    }

    private func composedInputText() -> String {
        let spoken = finalizedTranscript + volatileTranscript
        guard !spoken.isEmpty else { return prefixBeforeRecording }

        if prefixBeforeRecording.isEmpty {
            return spoken
        }

        let separator: String
        if prefixBeforeRecording.hasSuffix("\n") || prefixBeforeRecording.hasSuffix(" ") {
            separator = ""
        } else {
            separator = " "
        }
        return prefixBeforeRecording + separator + spoken
    }

    private func isLocaleSupported(_ locale: Locale) async -> Bool {
        let supported = await DictationTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    private func ensureModel(for module: DictationTranscriber) async throws {
        let locale = Locale.current
        let installed = await Set(DictationTranscriber.installedLocales)
        if installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            return
        }
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }

    private func startAudioCapture() async throws {
        let stream = try await makeAudioStream()
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                do {
                    try await self.streamBuffer(buffer)
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func makeAudioStream() async throws -> AsyncStream<AVAudioPCMBuffer> {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        return AsyncStream(AVAudioPCMBuffer.self, bufferingPolicy: .unbounded) { continuation in
            self.outputContinuation = continuation
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.outputContinuation?.yield(buffer)
            }
            self.audioEngine.prepare()
            do {
                try self.audioEngine.start()
            } catch {
                continuation.finish()
            }
        }
    }

    private func streamBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard let inputBuilder, let analyzerFormat else {
            throw SpeechInputError.invalidAudioFormat
        }

        let converted = try convertBuffer(buffer, to: analyzerFormat)
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw SpeechInputError.invalidAudioFormat
        }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        ) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw SpeechInputError.invalidAudioFormat
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw error ?? SpeechInputError.invalidAudioFormat
        }
        return converted
    }
}

@available(iOS 26, *)
private enum SpeechInputError: LocalizedError {
    case localeNotSupported
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return "Speech recognition is not available for the current language."
        case .invalidAudioFormat:
            return "Could not process microphone audio."
        }
    }
}
