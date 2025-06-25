//
//  ChatModels.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import Foundation
import FoundationModels

// Error handling for FoundationModels
enum ChatError: Identifiable, Codable {
    case guardrailViolation(String)
    case exceededContextWindowSize(String)
    case unsupportedGuide(String)
    case decodingFailure(String)
    case assetsUnavailable(String)
    case unknownError(String)
    
    var id: String {
        switch self {
        case .guardrailViolation: return "guardrail"
        case .exceededContextWindowSize: return "contextWindow"
        case .unsupportedGuide: return "unsupportedGuide"
        case .decodingFailure: return "decodingFailure"
        case .assetsUnavailable: return "assetsUnavailable"
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
        case .unknownError(let message):
            return "An unexpected error occurred. Please try again.\n\nDetails: \(message)"
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .guardrailViolation, .exceededContextWindowSize, .unsupportedGuide:
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
        case .unknownError: return "exclamationmark.circle"
        }
    }
    
    static func fromFoundationModelsError(_ error: Error) -> ChatError {
        // Check if it's a FoundationModels error
        if let languageModelError = error as? LanguageModelSession.GenerationError {
            switch languageModelError {
            case .guardrailViolation(let message):
                return .guardrailViolation(message.debugDescription)
            case .exceededContextWindowSize(let message):
                return .exceededContextWindowSize(message.debugDescription)
            case .unsupportedGuide(let message):
                return .unsupportedGuide(message.debugDescription)
            case .decodingFailure(let message):
                return .decodingFailure(message.debugDescription)
            case .assetsUnavailable(let message):
                return .assetsUnavailable(message.debugDescription)
            @unknown default:
                return .unknownError(error.localizedDescription)
            }
        } else {
            // Check for tool-related errors
            let errorDescription = error.localizedDescription
            if errorDescription.contains("tool:") || errorDescription.contains("WeatherTool") {
                return .unknownError("Tool execution failed: \(errorDescription)")
            }
            // Default to unknown error
            return .unknownError(error.localizedDescription)
        }
    }
}

// Tool call tracking
struct ToolCallInfo: Identifiable, Codable {
    let id = UUID()
    let toolName: String
    let toolDescription: String
    let arguments: String
    var status: ToolCallStatus = .pending
    var result: String?
    var error: String?
    let timestamp = Date()
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
    
    init(content: String, isUser: Bool, error: ChatError? = nil, toolCalls: [ToolCallInfo] = []) {
        self.id = UUID()
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
        self.error = error
        self.toolCalls = toolCalls
    }
    
    // Private initializer for decoding
    private init(id: UUID, content: String, isUser: Bool, timestamp: Date, error: ChatError?, toolCalls: [ToolCallInfo]) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.error = error
        self.toolCalls = toolCalls
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
}

// When adding tool calls, etc it broke loading old chats, so this lets us carefully load properties to make everything work
extension ChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, isUser, timestamp, error, toolCalls
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
        
        self.init(id: id, content: content, isUser: isUser, timestamp: timestamp, error: error, toolCalls: toolCalls)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(toolCalls, forKey: .toolCalls)
    }
}

struct Chat: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var systemPrompt: String
    var temperature: Double
    var toolsEnabled: Bool
    
    init(title: String = "New Chat", systemPrompt: String = "You are a helpful assistant.", temperature: Double = 1.0, toolsEnabled: Bool = true) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.toolsEnabled = toolsEnabled
    }
    
    // Custom Codable implementation for backward compatibility
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, systemPrompt, temperature, toolsEnabled
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode all properties, providing defaults for missing ones
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        self.toolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? true // Default to true for old chats
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(toolsEnabled, forKey: .toolsEnabled)
    }
    
    // Generate a fallback title based on the first user message (used if AI generation fails)
    mutating func generateFallbackTitle() {
        if let firstUserMessage = messages.first(where: { $0.isUser })?.content.trimmingCharacters(in: .whitespacesAndNewlines) {
            let words = firstUserMessage.components(separatedBy: .whitespacesAndNewlines)
            if words.count > 4 {
                self.title = words.prefix(4).joined(separator: " ") + "..."
            } else {
                self.title = firstUserMessage
            }
        }
    }
}

 
