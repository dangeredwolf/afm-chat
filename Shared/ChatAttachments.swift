//
//  ChatAttachments.swift
//  Shared
//

import Foundation
import UniformTypeIdentifiers

enum ChatAttachments {
    static var isSupported: Bool {
        if #available(iOS 27, *) {
            return true
        }
        return false
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

    static func isImageAttachment(mimeType: String?, fileURL: URL) -> Bool {
        if let mimeType, mimeType.hasPrefix("image/") {
            return true
        }
        let ext = fileURL.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"].contains(ext)
    }

    static func mimeType(for fileURL: URL) -> String? {
        if let type = UTType(filenameExtension: fileURL.pathExtension) {
            return type.preferredMIMEType
        }
        return nil
    }
}
