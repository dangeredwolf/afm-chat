//
//  ChatModels.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import Foundation

// Error handling for FoundationModels
enum ChatError: Identifiable, Codable {
    case guardrailViolation(String)
    case exceededContextWindowSize(String)
    case unsupportedGuide(String)
    case decodingFailure(String)
    case assetsUnavailable(String)
    case privateCloudComputeNotPermitted(String)
    case unknownError(String)
    
    var id: String {
        switch self {
        case .guardrailViolation: return "guardrail"
        case .exceededContextWindowSize: return "contextWindow"
        case .unsupportedGuide: return "unsupportedGuide"
        case .decodingFailure: return "decodingFailure"
        case .assetsUnavailable: return "assetsUnavailable"
        case .privateCloudComputeNotPermitted: return "pccNotPermitted"
        case .unknownError: return "unknownError"
        }
    }
    
    var title: String {
        switch self {
        case .guardrailViolation: return "Guardrail Violation"
        case .exceededContextWindowSize: return "Message Too Long"
        case .unsupportedGuide: return "Unsupported Guide"
        case .decodingFailure: return "Response Processing Error"
        case .assetsUnavailable: return "Language Model Unavailable"
        case .privateCloudComputeNotPermitted: return "Private Cloud Compute Unavailable"
        case .unknownError: return "Unknown Error"
        }
    }
    
    var description: String {
        switch self {
        case .guardrailViolation(let message):
            return "Your message was rejected by the system guardrails. This might be because you are asking about a sensitive topic.\n\nDetails: \(message)"
        case .exceededContextWindowSize(let message):
            return "Your conversation is too long. Try starting a new chat or clear some messages.\n\nDetails: \(message)"
        case .unsupportedGuide(let message):
            return "This feature is not supported in the current version.\n\nDetails: \(message)"
        case .decodingFailure(let message):
            return "Failed to process the response. Please try again.\n\nDetails: \(message)"
        case .assetsUnavailable(let message):
            return "The on-device language model is temporarily unavailable. Please try again later.\n\nDetails: \(message)"
        case .privateCloudComputeNotPermitted:
            return """
            Private Cloud Compute is not enabled for this app. Apple requires a managed entitlement before third-party apps can use PCC.

            To enable it, an Account Holder must request the Private Cloud Compute capability in Certificates, Identifiers & Profiles, then add it to this app in Xcode.

            Switch to On-Device in Settings to continue chatting.
            """
        case .unknownError(let message):
            return "An unexpected error occurred. Please try again.\n\nDetails: \(message)"
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .guardrailViolation, .exceededContextWindowSize, .unsupportedGuide, .privateCloudComputeNotPermitted:
            return false
        case .decodingFailure, .assetsUnavailable, .unknownError:
            return true
        }
    }
    
    var systemIcon: String {
        switch self {
        case .guardrailViolation: return "exclamationmark.shield"
        case .exceededContextWindowSize: return "doc.text.fill"
        case .unsupportedGuide: return "questionmark.circle"
        case .decodingFailure: return "exclamationmark.triangle"
        case .assetsUnavailable: return "server.rack"
        case .privateCloudComputeNotPermitted: return "icloud.slash"
        case .unknownError: return "exclamationmark.circle"
        }
    }
    
    static func fromError(_ error: Error) -> ChatError {
        // Generic mapping independent of provider
        let errorDescription = error.localizedDescription
        if errorDescription.localizedCaseInsensitiveContains("operation not permitted") {
            return .privateCloudComputeNotPermitted(errorDescription)
        }
        if errorDescription.localizedCaseInsensitiveContains("context") ||
            errorDescription.localizedCaseInsensitiveContains("too long") {
            return .exceededContextWindowSize(errorDescription)
        }
        if errorDescription.localizedCaseInsensitiveContains("guardrail") ||
            errorDescription.localizedCaseInsensitiveContains("policy") {
            return .guardrailViolation(errorDescription)
        }
        if errorDescription.localizedCaseInsensitiveContains("decode") {
            return .decodingFailure(errorDescription)
        }
        if errorDescription.localizedCaseInsensitiveContains("asset") ||
            errorDescription.localizedCaseInsensitiveContains("model unavailable") {
            return .assetsUnavailable(errorDescription)
        }
        // Tool-related errors
        if errorDescription.contains("tool:") || errorDescription.contains("Tool ") {
            return .unknownError("Tool execution failed: \(errorDescription)")
        }
        return .unknownError(errorDescription)
    }
}

// Tool call tracking
struct ToolCallInfo: Identifiable, Codable {
    let id: UUID
    var transcriptID: String
    let toolName: String
    let toolDescription: String
    let arguments: String
    var status: ToolCallStatus = .pending
    var result: String?
    var error: String?
    let timestamp: Date

    init(
        toolName: String,
        toolDescription: String,
        arguments: String,
        status: ToolCallStatus = .pending,
        result: String? = nil,
        error: String? = nil,
        transcriptID: String = UUID().uuidString
    ) {
        self.id = UUID()
        self.transcriptID = transcriptID
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.arguments = arguments
        self.status = status
        self.result = result
        self.error = error
        self.timestamp = Date()
    }

    init(
        id: UUID,
        toolName: String,
        toolDescription: String,
        arguments: String,
        status: ToolCallStatus,
        result: String?,
        error: String?,
        transcriptID: String,
        timestamp: Date
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.arguments = arguments
        self.status = status
        self.result = result
        self.error = error
        self.timestamp = timestamp
    }

    func updated(from call: LLMToolCallEvent, toolDescription: String) -> ToolCallInfo {
        let status: ToolCallStatus
        switch call.status {
        case .pending: status = .pending
        case .executing: status = .executing
        case .completed: status = .completed
        case .failed: status = .failed
        }

        let resolvedArguments = call.arguments.isEmpty ? arguments : call.arguments
        return ToolCallInfo(
            id: id,
            toolName: call.toolName,
            toolDescription: toolDescription,
            arguments: resolvedArguments,
            status: status,
            result: call.result,
            error: call.error,
            transcriptID: call.transcriptID,
            timestamp: timestamp
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, transcriptID, toolName, toolDescription, arguments, status, result, error, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        transcriptID = try container.decodeIfPresent(String.self, forKey: .transcriptID) ?? id.uuidString
        toolName = try container.decode(String.self, forKey: .toolName)
        toolDescription = try container.decode(String.self, forKey: .toolDescription)
        arguments = try container.decode(String.self, forKey: .arguments)
        status = try container.decodeIfPresent(ToolCallStatus.self, forKey: .status) ?? .pending
        result = try container.decodeIfPresent(String.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}

enum ChatMessageAttachmentKind: String, Codable {
    case image
    case video
    case audio
    case file
}

struct ChatMessageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ChatMessageAttachmentKind
    let label: String
    let relativePath: String
    let mimeType: String?

    var fileURL: URL {
        ChatAttachments.resolveURL(relativePath: relativePath)
    }

    var resolvedKind: ChatMessageAttachmentKind {
        if kind != .file {
            return kind
        }
        return ChatAttachments.kind(mimeType: mimeType, fileURL: fileURL)
    }

    var isModelSupportedImage: Bool {
        resolvedKind == .image
    }

    var isVideo: Bool {
        resolvedKind == .video
    }

    var isAudio: Bool {
        resolvedKind == .audio
    }

    init(id: UUID = UUID(), kind: ChatMessageAttachmentKind, label: String, relativePath: String, mimeType: String?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.relativePath = relativePath
        self.mimeType = mimeType
    }

    init(fileURL: URL, chatId: UUID, label: String, kind: ChatMessageAttachmentKind) {
        self.id = UUID()
        self.kind = kind
        self.label = label
        self.relativePath = ChatAttachments.relativePath(for: fileURL)
        self.mimeType = ChatAttachments.mimeType(for: fileURL)
    }

    func toLLMAttachment() -> LLMAttachment {
        LLMAttachment(
            label: label,
            fileURL: fileURL,
            mediaKind: resolvedKind.mediaKind
        )
    }
}

extension ChatMessageAttachmentKind {
    var mediaKind: LLMMediaKind {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .file: return .file
        }
    }
}

enum ChatTranscriptBlock: Identifiable, Codable, Equatable {
    case reasoning(id: UUID, content: String, duration: TimeInterval?)
    case tool(id: UUID)
    case text(id: UUID, content: String)

    var id: UUID {
        switch self {
        case .reasoning(let id, _, _):
            return id
        case .tool(let id):
            return id
        case .text(let id, _):
            return id
        }
    }
}

enum ToolCallStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case executing = "executing"
    case completed = "completed"
    case failed = "failed"
    
    var displayName: String {
        switch self {
        case .pending: return "Queued"
        case .executing: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
    
    var systemIcon: String {
        switch self {
        case .pending: return "clock"
        case .executing: return "gear"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let content: String
    let isUser: Bool
    let timestamp: Date
    let error: ChatError?
    var toolCalls: [ToolCallInfo]
    var reasoningContent: String?
    var reasoningDuration: TimeInterval?
    var reasoningTokenCount: Int?
    var transcriptBlocks: [ChatTranscriptBlock]
    var attachments: [ChatMessageAttachment]
    var model: LLMModelChoice?

    private static let legacyReasoningBlockID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001")!
    private static let legacyTextBlockID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-000000000002")!

    init(
        content: String,
        isUser: Bool,
        error: ChatError? = nil,
        toolCalls: [ToolCallInfo] = [],
        reasoningContent: String? = nil,
        reasoningDuration: TimeInterval? = nil,
        reasoningTokenCount: Int? = nil,
        transcriptBlocks: [ChatTranscriptBlock] = [],
        attachments: [ChatMessageAttachment] = [],
        model: LLMModelChoice? = nil
    ) {
        self.id = UUID()
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
        self.error = error
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.reasoningDuration = reasoningDuration
        self.reasoningTokenCount = reasoningTokenCount
        self.transcriptBlocks = transcriptBlocks
        self.attachments = attachments
        self.model = model
    }

    // Private initializer for decoding
    private init(
        id: UUID,
        content: String,
        isUser: Bool,
        timestamp: Date,
        error: ChatError?,
        toolCalls: [ToolCallInfo],
        reasoningContent: String?,
        reasoningDuration: TimeInterval?,
        reasoningTokenCount: Int?,
        transcriptBlocks: [ChatTranscriptBlock],
        attachments: [ChatMessageAttachment],
        model: LLMModelChoice?
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.error = error
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.reasoningDuration = reasoningDuration
        self.reasoningTokenCount = reasoningTokenCount
        self.transcriptBlocks = transcriptBlocks
        self.attachments = attachments
        self.model = model
    }

    var hasAttachments: Bool {
        !attachments.isEmpty
    }
    
    var isError: Bool {
        return error != nil
    }
    
    var hasToolCalls: Bool {
        return !toolCalls.isEmpty
    }
    
    var hasActiveToolCalls: Bool {
        return toolCalls.contains { $0.status == .pending || $0.status == .executing }
    }

    var hasReasoningContent: Bool {
        if reasoningDuration != nil {
            return true
        }
        guard let reasoningContent else { return false }
        return !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayBlocks: [ChatTranscriptBlock] {
        if !transcriptBlocks.isEmpty {
            return transcriptBlocks
        }
        return Self.legacyDisplayBlocks(
            reasoningContent: reasoningContent,
            reasoningDuration: reasoningDuration,
            toolCalls: toolCalls,
            content: content
        )
    }

    func historyTranscriptBlocks() -> [LLMTranscriptBlock] {
        guard !transcriptBlocks.isEmpty else { return [] }
        return transcriptBlocks.compactMap { block in
            switch block {
            case .reasoning(_, let content, _):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .reasoning(content: content)
            case .tool(let id):
                guard let tool = toolCalls.first(where: { $0.id == id }),
                      tool.status == .completed || tool.status == .failed else { return nil }
                return .tool(transcriptID: tool.transcriptID)
            case .text(_, let content):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .text(content: content)
            }
        }
    }

    func updatedForStreaming(
        content: String,
        toolCalls: [ToolCallInfo],
        reasoningContent: String?,
        reasoningDuration: TimeInterval?,
        reasoningTokenCount: Int?,
        transcriptBlocks: [ChatTranscriptBlock]
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            content: content,
            isUser: isUser,
            timestamp: timestamp,
            error: error,
            toolCalls: toolCalls,
            reasoningContent: reasoningContent,
            reasoningDuration: reasoningDuration,
            reasoningTokenCount: reasoningTokenCount,
            transcriptBlocks: transcriptBlocks,
            attachments: attachments,
            model: model
        )
    }

    private static func legacyDisplayBlocks(
        reasoningContent: String?,
        reasoningDuration: TimeInterval?,
        toolCalls: [ToolCallInfo],
        content: String
    ) -> [ChatTranscriptBlock] {
        var blocks: [ChatTranscriptBlock] = []
        let hasReasoningText = reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if hasReasoningText || reasoningDuration != nil {
            blocks.append(
                .reasoning(
                    id: legacyReasoningBlockID,
                    content: reasoningContent ?? "",
                    duration: reasoningDuration
                )
            )
        }
        for toolCall in toolCalls {
            blocks.append(.tool(id: toolCall.id))
        }
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(id: legacyTextBlockID, content: content))
        }
        return blocks
    }
}

// When adding tool calls, etc it broke loading old chats, so this lets us carefully load properties to make everything work
extension ChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, isUser, timestamp, error, toolCalls, reasoningContent, reasoningDuration, reasoningTokenCount, transcriptBlocks, attachments, model
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Try to decode all properties, providing defaults for new ones
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let content = try container.decode(String.self, forKey: .content)
        let isUser = try container.decode(Bool.self, forKey: .isUser)
        let timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        
        // Optional properties (new additions that might not exist in old data)
        let error = try container.decodeIfPresent(ChatError.self, forKey: .error)
        let toolCalls = try container.decodeIfPresent([ToolCallInfo].self, forKey: .toolCalls) ?? []
        let reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        let reasoningDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .reasoningDuration)
        let reasoningTokenCount = try container.decodeIfPresent(Int.self, forKey: .reasoningTokenCount)
        let transcriptBlocks = try container.decodeIfPresent([ChatTranscriptBlock].self, forKey: .transcriptBlocks) ?? []
        let attachments = try container.decodeIfPresent([ChatMessageAttachment].self, forKey: .attachments) ?? []
        let model = try container.decodeIfPresent(LLMModelChoice.self, forKey: .model)
        
        self.init(
            id: id,
            content: content,
            isUser: isUser,
            timestamp: timestamp,
            error: error,
            toolCalls: toolCalls,
            reasoningContent: reasoningContent,
            reasoningDuration: reasoningDuration,
            reasoningTokenCount: reasoningTokenCount,
            transcriptBlocks: transcriptBlocks,
            attachments: attachments,
            model: model
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(reasoningDuration, forKey: .reasoningDuration)
        try container.encodeIfPresent(reasoningTokenCount, forKey: .reasoningTokenCount)
        if !transcriptBlocks.isEmpty {
            try container.encode(transcriptBlocks, forKey: .transcriptBlocks)
        }
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encodeIfPresent(model, forKey: .model)
    }
}

struct Chat: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var systemPrompt: String
    var temperature: Double
    var model: LLMModelChoice
    var reasoningLevel: LLMReasoningLevel
    var thinkingEnabled: Bool
    var thinkingBudgetTokens: Int?
    var saveMemory: Bool
    var maxOutputTokens: Int?
    var generationSeed: UInt64?
    var toolsEnabled: Bool
    // Per-tool enablement (effective only when toolsEnabled == true)
    var toolCodeInterpreterEnabled: Bool
    var toolWebSearchEnabled: Bool
    var toolWebFetchEnabled: Bool
    var appendDateToSystemPrompt: Bool
    
    init(title: String = "New Chat",
         systemPrompt: String = "You are a helpful assistant.",
         temperature: Double = 1.0,
         model: LLMModelChoice = .onDevice,
         reasoningLevel: LLMReasoningLevel = .moderate,
         thinkingEnabled: Bool = true,
         thinkingBudgetTokens: Int? = nil,
         saveMemory: Bool = true,
         maxOutputTokens: Int? = nil,
         generationSeed: UInt64? = nil,
         toolsEnabled: Bool = true,
         toolCodeInterpreterEnabled: Bool = true,
         toolWebSearchEnabled: Bool = true,
         toolWebFetchEnabled: Bool = true,
         appendDateToSystemPrompt: Bool = true) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.model = model
        self.reasoningLevel = reasoningLevel
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.saveMemory = saveMemory
        self.maxOutputTokens = maxOutputTokens
        self.generationSeed = generationSeed
        self.toolsEnabled = toolsEnabled
        self.toolCodeInterpreterEnabled = toolCodeInterpreterEnabled
        self.toolWebSearchEnabled = toolWebSearchEnabled
        self.toolWebFetchEnabled = toolWebFetchEnabled
        self.appendDateToSystemPrompt = appendDateToSystemPrompt
    }
    
    // Custom Codable implementation for backward compatibility
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, systemPrompt, temperature, model, reasoningLevel,
             thinkingEnabled, thinkingBudgetTokens, saveMemory, maxOutputTokens, generationSeed, toolsEnabled,
             toolCodeInterpreterEnabled, toolLocationEnabled, toolWebFetchEnabled, toolWebSearchEnabled,
             appendDateToSystemPrompt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode all properties, providing defaults for missing ones
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        
        // For createdAt, try to use the earliest message timestamp if createdAt is missing
        if let savedCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
            self.createdAt = savedCreatedAt
        } else {
            // Fallback: use the earliest message timestamp, or current date if no messages
            let earliestMessageDate = self.messages.map(\.timestamp).min()
            self.createdAt = earliestMessageDate ?? Date()
        }
        
        self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        self.model = try container.decodeIfPresent(LLMModelChoice.self, forKey: .model) ?? .onDevice
        self.reasoningLevel = try container.decodeIfPresent(LLMReasoningLevel.self, forKey: .reasoningLevel) ?? .moderate
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? true
        if let budget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudgetTokens), budget > 0 {
            self.thinkingBudgetTokens = budget
        } else {
            self.thinkingBudgetTokens = nil
        }
        self.saveMemory = try container.decodeIfPresent(Bool.self, forKey: .saveMemory) ?? true
        if let maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens), maxTokens > 0 {
            self.maxOutputTokens = maxTokens
        } else {
            self.maxOutputTokens = nil
        }
        if let seed = try container.decodeIfPresent(UInt64.self, forKey: .generationSeed) {
            self.generationSeed = seed
        } else {
            self.generationSeed = nil
        }
        self.toolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? false
        self.toolCodeInterpreterEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolCodeInterpreterEnabled) ?? true
        _ = try container.decodeIfPresent(Bool.self, forKey: .toolLocationEnabled)
        self.toolWebFetchEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolWebFetchEnabled) ?? true
        self.toolWebSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolWebSearchEnabled) ?? true
        self.appendDateToSystemPrompt = try container.decodeIfPresent(Bool.self, forKey: .appendDateToSystemPrompt) ?? true
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(model, forKey: .model)
        try container.encode(reasoningLevel, forKey: .reasoningLevel)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encodeIfPresent(thinkingBudgetTokens, forKey: .thinkingBudgetTokens)
        try container.encode(saveMemory, forKey: .saveMemory)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(generationSeed, forKey: .generationSeed)
        try container.encode(toolsEnabled, forKey: .toolsEnabled)
        try container.encode(toolCodeInterpreterEnabled, forKey: .toolCodeInterpreterEnabled)
        try container.encode(toolWebFetchEnabled, forKey: .toolWebFetchEnabled)
        try container.encode(toolWebSearchEnabled, forKey: .toolWebSearchEnabled)
        try container.encode(appendDateToSystemPrompt, forKey: .appendDateToSystemPrompt)
    }
    
    var lastActivityDate: Date {
        messages.last?.timestamp ?? createdAt
    }

    // Generate a fallback title based on the first user message (used if AI generation fails)
    mutating func generateFallbackTitle() {
        if let firstUserMessage = messages.first(where: { $0.isUser }) {
            let trimmed = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleSource: String
            if trimmed.isEmpty, let firstAttachment = firstUserMessage.attachments.first {
                titleSource = firstAttachment.label
            } else {
                titleSource = trimmed
            }
            guard !titleSource.isEmpty else { return }
            let words = titleSource.components(separatedBy: .whitespacesAndNewlines)
            if words.count > 4 {
                self.title = words.prefix(4).joined(separator: " ") + "..."
            } else {
                self.title = titleSource
            }
        }
    }
}

enum ChatSettingsScope {
    case currentChat
    case defaults
}

struct ChatSettingsValues: Equatable {
    var systemPrompt: String
    var temperature: Double
    var model: LLMModelChoice
    var reasoningLevel: LLMReasoningLevel
    var thinkingEnabled: Bool
    var thinkingBudgetTokens: Int?
    var saveMemory: Bool
    var maxOutputTokens: Int?
    var generationSeed: UInt64?
    var toolsEnabled: Bool
    var toolCodeInterpreterEnabled: Bool
    var toolWebSearchEnabled: Bool
    var toolWebFetchEnabled: Bool
    var appendDateToSystemPrompt: Bool

    init(
        systemPrompt: String,
        temperature: Double,
        model: LLMModelChoice,
        reasoningLevel: LLMReasoningLevel,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?,
        saveMemory: Bool,
        maxOutputTokens: Int?,
        generationSeed: UInt64?,
        toolsEnabled: Bool,
        toolCodeInterpreterEnabled: Bool,
        toolWebSearchEnabled: Bool,
        toolWebFetchEnabled: Bool,
        appendDateToSystemPrompt: Bool
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.model = model
        self.reasoningLevel = reasoningLevel
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.saveMemory = saveMemory
        self.maxOutputTokens = maxOutputTokens
        self.generationSeed = generationSeed
        self.toolsEnabled = toolsEnabled
        self.toolCodeInterpreterEnabled = toolCodeInterpreterEnabled
        self.toolWebSearchEnabled = toolWebSearchEnabled
        self.toolWebFetchEnabled = toolWebFetchEnabled
        self.appendDateToSystemPrompt = appendDateToSystemPrompt
    }

    init(from chat: Chat) {
        self.init(
            systemPrompt: chat.systemPrompt,
            temperature: chat.temperature,
            model: chat.model,
            reasoningLevel: chat.reasoningLevel,
            thinkingEnabled: chat.thinkingEnabled,
            thinkingBudgetTokens: chat.thinkingBudgetTokens,
            saveMemory: chat.saveMemory,
            maxOutputTokens: chat.maxOutputTokens,
            generationSeed: chat.generationSeed,
            toolsEnabled: chat.toolsEnabled,
            toolCodeInterpreterEnabled: chat.toolCodeInterpreterEnabled,
            toolWebSearchEnabled: chat.toolWebSearchEnabled,
            toolWebFetchEnabled: chat.toolWebFetchEnabled,
            appendDateToSystemPrompt: chat.appendDateToSystemPrompt
        )
    }

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> ChatSettingsValues {
        let storedBudget = defaults.object(forKey: "thinkingBudgetTokens") as? Int
        let storedMaxTokens = defaults.object(forKey: "maxOutputTokens") as? Int
        let storedSeed = (defaults.object(forKey: "generationSeed") as? NSNumber)?.uint64Value
        return ChatSettingsValues(
            systemPrompt: defaults.string(forKey: "systemPrompt") ?? "You are a helpful assistant.",
            temperature: defaults.object(forKey: "temperature") as? Double ?? 1.0,
            model: LLMModelChoice(
                rawValue: defaults.string(forKey: "model") ?? LLMModelChoice.onDevice.rawValue
            ) ?? .onDevice,
            reasoningLevel: LLMReasoningLevel(
                rawValue: defaults.string(forKey: "reasoningLevel") ?? LLMReasoningLevel.moderate.rawValue
            ) ?? .moderate,
            thinkingEnabled: defaults.object(forKey: "thinkingEnabled") as? Bool ?? true,
            thinkingBudgetTokens: (storedBudget ?? 0) > 0 ? storedBudget : nil,
            saveMemory: defaults.object(forKey: "saveMemory") as? Bool ?? true,
            maxOutputTokens: (storedMaxTokens ?? 0) > 0 ? storedMaxTokens : nil,
            generationSeed: storedSeed,
            toolsEnabled: defaults.object(forKey: "toolsEnabled") as? Bool ?? false,
            toolCodeInterpreterEnabled: defaults.object(forKey: "toolCodeInterpreterEnabled") as? Bool ?? true,
            toolWebSearchEnabled: defaults.object(forKey: "toolWebSearchEnabled") as? Bool ?? true,
            toolWebFetchEnabled: defaults.object(forKey: "toolWebFetchEnabled") as? Bool ?? true,
            appendDateToSystemPrompt: defaults.object(forKey: "appendDateToSystemPrompt") as? Bool ?? true
        )
    }
}

 
