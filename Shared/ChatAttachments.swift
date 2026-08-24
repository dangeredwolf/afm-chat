//
//  ChatAttachments.swift
//  Shared
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ChatAttachments {
    static var isSupported: Bool {
        true
    }

    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func directory(for chatId: UUID) -> URL {
        let directory = storageDirectory.appendingPathComponent(chatId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func relativePath(for fileURL: URL) -> String {
        let base = storageDirectory.path
        let path = fileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return fileURL.lastPathComponent
    }

    static func resolveURL(relativePath: String) -> URL {
        storageDirectory.appendingPathComponent(relativePath)
    }

    @discardableResult
    static func importFile(
        from sourceURL: URL,
        chatId: UUID,
        suggestedName: String
    ) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let ext = (suggestedName as NSString).pathExtension
        let baseName = (suggestedName as NSString).deletingPathExtension
        let safeBase = baseName.isEmpty ? "attachment" : baseName
        let filename = ext.isEmpty ? "\(UUID().uuidString)-\(safeBase)" : "\(UUID().uuidString)-\(safeBase).\(ext)"
        let destination = directory(for: chatId).appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            // Mac Catalyst sandboxed apps sometimes reject copyItem even with security-scoped access.
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destination, options: .atomic)
        }

        return destination
    }

    @discardableResult
    static func saveData(
        _ data: Data,
        chatId: UUID,
        suggestedName: String,
        fileExtension: String
    ) throws -> URL {
        let ext = fileExtension.isEmpty ? "dat" : fileExtension
        let filename = "\(UUID().uuidString)-\(suggestedName).\(ext)"
        let destination = directory(for: chatId).appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func kind(mimeType: String?, fileURL: URL) -> ChatMessageAttachmentKind {
        if isImageAttachment(mimeType: mimeType, fileURL: fileURL) {
            return .image
        }
        if isVideoAttachment(mimeType: mimeType, fileURL: fileURL) {
            return .video
        }
        if isAudioAttachment(mimeType: mimeType, fileURL: fileURL) {
            return .audio
        }
        return .file
    }

    static func isImageAttachment(mimeType: String?, fileURL: URL) -> Bool {
        if let mimeType, mimeType.hasPrefix("image/") {
            return true
        }
        let ext = fileURL.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    static func isVideoAttachment(mimeType: String?, fileURL: URL) -> Bool {
        if let mimeType {
            if mimeType.hasPrefix("video/") { return true }
            if mimeType.hasPrefix("audio/") || mimeType.hasPrefix("image/") { return false }
        }

        let ext = fileURL.pathExtension.lowercased()
        if ambiguousAVExtensions.contains(ext) {
            if let hasVideo = hasTrack(at: fileURL, mediaType: .video) {
                return hasVideo
            }
            return true
        }
        if videoExtensions.contains(ext) {
            return true
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .audio) { return false }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return true
            }
        }
        return false
    }

    static func isAudioAttachment(mimeType: String?, fileURL: URL) -> Bool {
        if isVideoAttachment(mimeType: mimeType, fileURL: fileURL) {
            return false
        }
        if let mimeType, mimeType.hasPrefix("audio/") {
            return true
        }
        let ext = fileURL.pathExtension.lowercased()
        if audioExtensions.contains(ext) {
            return true
        }
        if ambiguousAVExtensions.contains(ext), hasTrack(at: fileURL, mediaType: .audio) == true {
            return true
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) {
            return true
        }
        return false
    }

    static func mimeType(for fileURL: URL) -> String? {
        if let type = UTType(filenameExtension: fileURL.pathExtension) {
            return type.preferredMIMEType
        }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "m4v", "avi", "mkv", "webm", "3gp", "3gpp"
    ]

    private static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aiff", "aif", "aac", "flac", "mpga", "oga", "ogg"
    ]

    /// Containers that may be audio-only or have a video track.
    private static let ambiguousAVExtensions: Set<String> = [
        "mp4", "mpeg", "mpg", "m4p"
    ]

    private static func hasTrack(at fileURL: URL, mediaType: AVMediaType) -> Bool? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let asset = AVURLAsset(url: fileURL)
        let tracks = asset.tracks(withMediaType: mediaType)
        return !tracks.isEmpty
    }
}
