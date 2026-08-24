//
//  ChatAttachmentTranscriber.swift
//  Shared
//

import AVFoundation
import Foundation
import Speech

enum ChatAttachmentTranscriber {
    static func isAudioAttachment(_ attachment: ChatMessageAttachment) -> Bool {
        if let mimeType = attachment.mimeType, mimeType.hasPrefix("audio/") {
            return true
        }

        let audioExtensions: Set<String> = [
            "m4a", "mp3", "wav", "caf", "aiff", "aac", "flac", "mp4", "mpeg", "mpga",
        ]
        return audioExtensions.contains(attachment.fileURL.pathExtension.lowercased())
    }

    static func transcribe(
        attachment: ChatMessageAttachment,
        locale: Locale = .current
    ) async -> Result<String, ChatAttachmentReader.ReadFailure> {
        guard ChatAttachmentReader.isPathWithinStorage(attachment.fileURL) else {
            return .failure(.init(message: "Access denied: file is outside the attachment storage directory."))
        }

        guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
            return .failure(.init(message: "File not found: \(attachment.label)"))
        }

        if let cached = readCachedTranscript(for: attachment) {
            return .success(cached)
        }

        guard #available(iOS 26, *) else {
            return .failure(.init(message: "Audio transcription requires iOS 26 or later."))
        }

        do {
            let transcript = try await transcribeFile(at: attachment.fileURL, locale: locale)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(.init(message: "No speech detected in \(attachment.label)."))
            }
            writeCachedTranscript(trimmed, for: attachment)
            return .success(trimmed)
        } catch let error as TranscriptionFailure {
            return .failure(.init(message: error.message))
        } catch {
            return .failure(.init(message: "Could not transcribe \(attachment.label): \(error.localizedDescription)"))
        }
    }

    // MARK: - Cache

    private static func cacheURL(for attachment: ChatMessageAttachment) -> URL {
        attachment.fileURL.appendingPathExtension("transcript.txt")
    }

    private static func readCachedTranscript(for attachment: ChatMessageAttachment) -> String? {
        let cache = cacheURL(for: attachment)
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }

        guard
            let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: attachment.fileURL.path),
            let cacheAttributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
            let sourceModified = sourceAttributes[.modificationDate] as? Date,
            let cacheModified = cacheAttributes[.modificationDate] as? Date,
            cacheModified >= sourceModified
        else {
            return nil
        }

        return try? String(contentsOf: cache, encoding: .utf8)
    }

    private static func writeCachedTranscript(_ transcript: String, for attachment: ChatMessageAttachment) {
        let cache = cacheURL(for: attachment)
        try? transcript.write(to: cache, atomically: true, encoding: .utf8)
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
