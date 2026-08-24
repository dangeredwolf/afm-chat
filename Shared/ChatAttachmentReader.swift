//
//  ChatAttachmentReader.swift
//  Shared
//

import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ChatAttachmentReader {
    static let defaultMaxCharacters = 8_000

    struct ReadFailure: Error {
        let message: String
    }

    struct ReadResult {
        let content: String
        let totalCharacters: Int
        let offset: Int
        let returnedCharacters: Int
        let isTruncated: Bool
    }

    static func read(
        attachment: ChatMessageAttachment,
        offset: Int = 0,
        maxCharacters: Int = defaultMaxCharacters
    ) -> Result<ReadResult, ReadFailure> {
        guard Self.isPathWithinStorage(attachment.fileURL) else {
            return .failure(ReadFailure(message: "Access denied: file is outside the attachment storage directory."))
        }

        guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
            return .failure(ReadFailure(message: "File not found: \(attachment.label)"))
        }

        let fullText: String
        if isPDF(attachment) {
            guard let extracted = extractPDFText(from: attachment.fileURL) else {
                return .failure(ReadFailure(message: "Could not read PDF: \(attachment.label)"))
            }
            if extracted.isEmpty {
                return .failure(ReadFailure(message: "No extractable text in \(attachment.label). The PDF may be image-only or scanned."))
            }
            fullText = extracted
        } else if isTextReadable(attachment) {
            guard let text = extractText(from: attachment.fileURL) else {
                return .failure(ReadFailure(message: "Could not decode text from \(attachment.label). The file may be binary or use an unsupported encoding."))
            }
            fullText = text
        } else {
            return .failure(ReadFailure(message: "Unsupported file type for \(attachment.label). Supported formats: plain text, markdown, JSON, CSV, code files, PDF, and audio recordings."))
        }

        return .success(paginate(fullText, offset: offset, maxCharacters: maxCharacters))
    }

    static func formatOutput(_ result: ReadResult, label: String) -> String {
        var output = "File: \(label)\n"
        if result.isTruncated {
            let end = result.offset + result.returnedCharacters
            output += "[Showing characters \(result.offset)-\(end) of \(result.totalCharacters). Call again with a higher offset to read more.]\n\n"
        } else if result.offset > 0 {
            output += "[Showing characters \(result.offset)-\(result.offset + result.returnedCharacters) of \(result.totalCharacters).]\n\n"
        }
        output += result.content
        return output
    }

    static func paginateText(
        _ text: String,
        offset: Int = 0,
        maxCharacters: Int = defaultMaxCharacters
    ) -> ReadResult {
        paginate(text, offset: offset, maxCharacters: maxCharacters)
    }

    static func isPathWithinStorage(_ fileURL: URL) -> Bool {
        let storagePath = ChatAttachments.storageDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath.hasPrefix(storagePath + "/") || filePath == storagePath
    }

    private static func isPDF(_ attachment: ChatMessageAttachment) -> Bool {
        if attachment.mimeType == "application/pdf" { return true }
        return attachment.fileURL.pathExtension.lowercased() == "pdf"
    }

    private static func isTextReadable(_ attachment: ChatMessageAttachment) -> Bool {
        if let mimeType = attachment.mimeType {
            if mimeType.hasPrefix("text/") { return true }
            if mimeType == "application/json" { return true }
            if mimeType == "application/xml" { return true }
        }

        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml",
            "swift", "py", "js", "ts", "html", "htm", "css", "sql", "log",
            "ini", "cfg", "conf", "toml", "rtf", "sh", "bash", "zsh",
        ]
        return textExtensions.contains(attachment.fileURL.pathExtension.lowercased())
    }

    private static func extractText(from fileURL: URL) -> String? {
        if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
            return utf8
        }
        if let latin1 = try? String(contentsOf: fileURL, encoding: .isoLatin1) {
            return latin1
        }
        return nil
    }

    private static func extractPDFText(from fileURL: URL) -> String? {
        guard let document = PDFDocument(url: fileURL) else { return nil }

        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pages.append(trimmed)
            }
        }

        guard !pages.isEmpty else { return "" }
        return pages.joined(separator: "\n\n")
    }

    private static func paginate(_ text: String, offset: Int, maxCharacters: Int) -> ReadResult {
        let safeOffset = max(0, offset)
        let safeMax = max(1, maxCharacters)
        let total = text.count

        guard safeOffset < total else {
            return ReadResult(
                content: "",
                totalCharacters: total,
                offset: safeOffset,
                returnedCharacters: 0,
                isTruncated: false
            )
        }

        let start = text.index(text.startIndex, offsetBy: safeOffset)
        let remaining = text.distance(from: start, to: text.endIndex)
        let length = min(safeMax, remaining)
        let end = text.index(start, offsetBy: length)
        let slice = String(text[start..<end])

        return ReadResult(
            content: slice,
            totalCharacters: total,
            offset: safeOffset,
            returnedCharacters: length,
            isTruncated: safeOffset + length < total
        )
    }
}
