//
//  ReadAttachmentTool.swift
//  Shared
//

import Foundation
import FoundationModels

/// Maps attachment labels to sandboxed files available in the current chat session.
struct AttachmentRegistry: Sendable {
    private let byExactLabel: [String: ChatMessageAttachment]
    private let byLowercaseLabel: [String: ChatMessageAttachment]

    init(attachments: [ChatMessageAttachment]) {
        var exact: [String: ChatMessageAttachment] = [:]
        var lowercase: [String: ChatMessageAttachment] = [:]

        for attachment in attachments where !attachment.isModelSupportedImage && !attachment.isAudio && !attachment.isVideo {
            exact[attachment.label] = attachment
            lowercase[attachment.label.lowercased()] = attachment
        }

        self.byExactLabel = exact
        self.byLowercaseLabel = lowercase
    }

    var availableLabels: [String] {
        byExactLabel.keys.sorted()
    }

    func resolve(label filename: String) -> ChatMessageAttachment? {
        if let match = byExactLabel[filename] {
            return match
        }
        return byLowercaseLabel[filename.lowercased()]
    }
}

/// Reads text content from user-attached non-image files in the current chat.
struct ReadAttachmentTool: Tool {
    private static let definition = AppToolID.readAttachment.definition

    var name: String { Self.definition.displayName }
    var description: String { Self.definition.description }
    var parameters: GenerationSchema { Self.definition.generationSchema() }

    private let registry: AttachmentRegistry

    init(registry: AttachmentRegistry) {
        self.registry = registry
    }

    @Generable
    struct Arguments {
        var filename: String
        var offset: Int?
        var maxCharacters: Int?
    }

    func call(arguments: Arguments) async throws -> [String] {
        var trackedArguments: [String: String] = ["filename": arguments.filename]
        if let offset = arguments.offset {
            trackedArguments["offset"] = String(offset)
        }
        if let maxCharacters = arguments.maxCharacters {
            trackedArguments["maxCharacters"] = String(maxCharacters)
        }
        ToolExecutionTracker.begin(toolName: name, arguments: trackedArguments)
        defer { ToolExecutionTracker.end(toolName: name, arguments: trackedArguments) }

        let trimmedName = arguments.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return ["Error: filename is required. Available files: \(formatAvailableLabels())"]
        }

        guard let attachment = registry.resolve(label: trimmedName) else {
            return ["Error: No attachment named \"\(trimmedName)\". Available files: \(formatAvailableLabels())"]
        }

        let offset = arguments.offset ?? 0
        let maxCharacters = arguments.maxCharacters ?? ChatAttachmentReader.defaultMaxCharacters

        if ChatAttachmentTranscriber.isTranscribable(attachment) {
            switch await ChatAttachmentTranscriber.transcribe(attachment: attachment) {
            case .success(let transcript):
                let result = ChatAttachmentReader.paginateText(
                    transcript,
                    offset: offset,
                    maxCharacters: maxCharacters
                )
                return [ChatAttachmentReader.formatOutput(result, label: attachment.label)]
            case .failure(let error):
                return [error.message]
            }
        }

        switch ChatAttachmentReader.read(attachment: attachment, offset: offset, maxCharacters: maxCharacters) {
        case .success(let result):
            return [ChatAttachmentReader.formatOutput(result, label: attachment.label)]
        case .failure(let error):
            return [error.message]
        }
    }

    private func formatAvailableLabels() -> String {
        let labels = registry.availableLabels
        return labels.isEmpty ? "(none)" : labels.joined(separator: ", ")
    }
}
