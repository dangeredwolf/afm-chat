//
//  ChatAttachmentTranscriber.swift
//  Shared
//

import AVFoundation
import Foundation
import Speech

enum ChatAttachmentTranscriber {
    static func isAudioAttachment(_ attachment: ChatMessageAttachment) -> Bool {
        attachment.isAudio
    }

    static func isTranscribable(_ attachment: ChatMessageAttachment) -> Bool {
        attachment.isAudio || attachment.isVideo
    }

    static func isTranscribable(_ attachment: LLMAttachment) -> Bool {
        attachment.isAudio || attachment.isVideo
    }

    /// Formatted note from cache, if a transcript was already written.
    static func cachedNote(for attachment: ChatMessageAttachment) -> String? {
        guard let cached = readCachedTranscript(for: attachment.fileURL, label: attachment.label) else {
            return nil
        }
        return formatNote(label: attachment.label, body: cached)
    }

    static func cachedNote(for attachment: LLMAttachment) -> String? {
        guard let cached = readCachedTranscript(for: attachment.fileURL, label: attachment.label) else {
            return nil
        }
        return formatNote(label: attachment.label, body: cached)
    }

    /// Always returns a note. Used after `ensureTranscript` so cache misses become an explicit fallback line.
    static func note(for attachment: LLMAttachment) -> String {
        if let cached = readCachedTranscript(for: attachment.fileURL, label: attachment.label) {
            return formatNote(label: attachment.label, body: cached)
        }
        return formatNote(label: attachment.label, body: "Transcript for \(attachment.label) is unavailable.")
    }

    static func transcribe(
        attachment: ChatMessageAttachment,
        locale: Locale = .current
    ) async -> Result<String, ChatAttachmentReader.ReadFailure> {
        switch await transcribeMedia(fileURL: attachment.fileURL, label: attachment.label, locale: locale) {
        case .success(let body):
            return .success(body)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func ensureTranscript(
        fileURL: URL,
        label: String,
        locale: Locale = .current
    ) async {
        _ = await transcribeMedia(fileURL: fileURL, label: label, locale: locale)
    }

    // MARK: - Cache

    private static func cacheURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("transcript.txt")
    }

    private static func readCachedTranscript(for fileURL: URL, label: String) -> String? {
        let cache = cacheURL(for: fileURL)
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }

        guard
            let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let cacheAttributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
            let sourceModified = sourceAttributes[.modificationDate] as? Date,
            let cacheModified = cacheAttributes[.modificationDate] as? Date,
            cacheModified >= sourceModified
        else {
            return nil
        }

        return try? String(contentsOf: cache, encoding: .utf8)
    }

    private static func writeCachedTranscript(_ transcript: String, for fileURL: URL) {
        let cache = cacheURL(for: fileURL)
        try? transcript.write(to: cache, atomically: true, encoding: .utf8)
    }

    private static func formatNote(label: String, body: String) -> String {
        "[Transcript of \(label)]\n\(body)"
    }

    private static func transcribeMedia(
        fileURL: URL,
        label: String,
        locale: Locale
    ) async -> Result<String, ChatAttachmentReader.ReadFailure> {
        guard ChatAttachmentReader.isPathWithinStorage(fileURL) else {
            return .failure(.init(message: "Access denied: file is outside the attachment storage directory."))
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failure(.init(message: "File not found: \(label)"))
        }

        if let cached = readCachedTranscript(for: fileURL, label: label) {
            return .success(cached)
        }

        guard #available(iOS 26, *) else {
            let message = "Audio transcription requires iOS 26 or later."
            writeCachedTranscript(message, for: fileURL)
            return .failure(.init(message: message))
        }

        do {
            let sourceURL = try await audioURLForTranscription(from: fileURL, label: label)
            defer {
                if sourceURL != fileURL {
                    try? FileManager.default.removeItem(at: sourceURL)
                }
            }

            let transcript = try await transcribeFile(at: sourceURL, locale: locale)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmed.isEmpty ? "No speech detected in \(label)." : trimmed
            writeCachedTranscript(body, for: fileURL)
            return .success(body)
        } catch let error as TranscriptionFailure {
            writeCachedTranscript(error.message, for: fileURL)
            return .failure(.init(message: error.message))
        } catch {
            let message = "Could not transcribe \(label): \(error.localizedDescription)"
            writeCachedTranscript(message, for: fileURL)
            return .failure(.init(message: message))
        }
    }

    private static func audioURLForTranscription(from fileURL: URL, label: String) async throws -> URL {
        if (try? AVAudioFile(forReading: fileURL)) != nil {
            return fileURL
        }

        let asset = AVURLAsset(url: fileURL)
        let audioTracks: [AVAssetTrack]
        if #available(iOS 15, *) {
            audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        } else {
            audioTracks = asset.tracks(withMediaType: .audio)
        }
        guard !audioTracks.isEmpty else {
            throw TranscriptionFailure(message: "No speech detected in \(label).")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionFailure(message: "Could not transcribe \(label): audio export is unavailable.")
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        await session.export()
        if session.status == .completed, FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let reason = session.error?.localizedDescription ?? "audio export failed"
        throw TranscriptionFailure(message: "Could not transcribe \(label): \(reason)")
    }

    // MARK: - SpeechAnalyzer

    @available(iOS 26, *)
    private static func transcribeFile(at fileURL: URL, locale: Locale) async throws -> String {
        guard await isLocaleSupported(locale) else {
            let supported = await SpeechTranscriber.supportedLocales
            let labels = supported.prefix(8).map { $0.identifier(.bcp47) }.joined(separator: ", ")
            throw TranscriptionFailure(
                message: "Transcription is not available for \(locale.identifier(.bcp47)). Supported locales include: \(labels)."
            )
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureModel(for: transcriber)

        async let transcriptionFuture: String = transcriber.results.reduce(into: "") { partial, result in
            partial += String(result.text.characters)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await transcriptionFuture
    }

    @available(iOS 26, *)
    private static func isLocaleSupported(_ locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    @available(iOS 26, *)
    private static func ensureModel(for module: SpeechTranscriber) async throws {
        let locale = Locale.current
        let installed = await Set(SpeechTranscriber.installedLocales)
        if installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            return
        }
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }

    private struct TranscriptionFailure: Error {
        let message: String
    }
}

enum AttachmentMediaSupport {
    static func capabilities(for model: LLMModelChoice) -> LLMMediaCapabilities {
        switch model {
        case .onDevice, .privateCloudCompute:
            return .apple
        case .mlx(let id):
            #if AFM_MLX
            return HuggingFaceModelCatalog.mediaCapabilities(
                id: id,
                pipelineTag: DownloadedModelStore.pipelineTag(for: id)
            )
            #else
            return .none
            #endif
        }
    }

    static func preparePrompt(
        _ prompt: LLMPrompt,
        capabilities: LLMMediaCapabilities,
        includeFileNames: Bool
    ) -> LLMPrompt {
        let partitioned = partition(prompt.attachments, capabilities: capabilities)
        var text = prompt.text
        var notes = partitioned.transcriptNotes
        if includeFileNames, !partitioned.files.isEmpty {
            let labels = partitioned.files.map(\.label).joined(separator: ", ")
            notes.append(
                "The user attached these files: \(labels)."
            )
        }
        if !notes.isEmpty {
            text = appendNotes(notes, to: text)
        }
        let keptFiles = includeFileNames ? [] : partitioned.files
        return LLMPrompt(
            text: text,
            attachments: partitioned.native + keptFiles
        )
    }

    static func preparedHistoryEntry(
        _ entry: LLMHistoryEntry,
        capabilities: LLMMediaCapabilities,
        includeFileNames: Bool
    ) -> LLMHistoryEntry {
        guard entry.isUser else { return entry }
        let partitioned = partition(entry.attachments, capabilities: capabilities)
        var content = entry.content
        var notes = partitioned.transcriptNotes
        if includeFileNames, !partitioned.files.isEmpty {
            let labels = partitioned.files.map(\.label).joined(separator: ", ")
            notes.append("The user attached these files: \(labels).")
        }
        if !notes.isEmpty {
            content = appendNotes(notes, to: content)
        }
        let keptFiles = includeFileNames ? [] : partitioned.files
        return LLMHistoryEntry(
            isUser: entry.isUser,
            content: content,
            attachments: partitioned.native + keptFiles,
            toolCalls: entry.toolCalls,
            reasoningContent: entry.reasoningContent
        )
    }

    static func ensureTranscripts(
        attachments: [LLMAttachment],
        capabilities: LLMMediaCapabilities
    ) async {
        let partitioned = partition(attachments, capabilities: capabilities)
        for attachment in partitioned.transcribe {
            await ChatAttachmentTranscriber.ensureTranscript(
                fileURL: attachment.fileURL,
                label: attachment.label
            )
        }
    }

    private struct Partition {
        var native: [LLMAttachment]
        var files: [LLMAttachment]
        var transcribe: [LLMAttachment]
        var transcriptNotes: [String]
    }

    private static func partition(
        _ attachments: [LLMAttachment],
        capabilities: LLMMediaCapabilities
    ) -> Partition {
        var images = attachments.filter(\.isImage)
        var videos = attachments.filter(\.isVideo)
        var audios = attachments.filter(\.isAudio)
        let files = attachments.filter { $0.mediaKind == .file }

        if capabilities.video, capabilities.singleMediaType, !videos.isEmpty {
            images = []
        }
        if capabilities.video, capabilities.singleVideoOnly, videos.count > 1 {
            videos = Array(videos.prefix(1))
        }

        let nativeImages = capabilities.vision ? images : []
        let nativeVideos = capabilities.video ? videos : []
        let nativeAudios = capabilities.audio ? audios : []

        var transcribe: [LLMAttachment] = []
        if !capabilities.audio {
            transcribe.append(contentsOf: audios)
        }
        if !capabilities.video {
            transcribe.append(contentsOf: attachments.filter(\.isVideo))
        } else if capabilities.singleVideoOnly {
            let extras = attachments.filter(\.isVideo).dropFirst()
            transcribe.append(contentsOf: extras)
        }

        let notes = transcribe.map { ChatAttachmentTranscriber.note(for: $0) }
        return Partition(
            native: nativeImages + nativeVideos + nativeAudios,
            files: files,
            transcribe: transcribe,
            transcriptNotes: notes
        )
    }

    private static func appendNotes(_ notes: [String], to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = notes.joined(separator: "\n\n")
        if trimmed.isEmpty {
            return block
        }
        return trimmed + "\n\n" + block
    }
}
