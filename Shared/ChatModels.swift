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
            // Default to unknown error
            return .unknownError(error.localizedDescription)
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
    let error: ChatError?
    
    init(content: String, isUser: Bool, error: ChatError? = nil) {
        self.content = content
        self.isUser = isUser
        self.error = error
    }
    
    var isError: Bool {
        return error != nil
    }
}

struct Chat: Identifiable, Codable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    let createdAt = Date()
    var systemPrompt: String
    var temperature: Double
    
    init(title: String = "New Chat", systemPrompt: String = "You are a helpful assistant.", temperature: Double = 1.0) {
        self.title = title
        self.systemPrompt = systemPrompt
        self.temperature = temperature
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

extension ChatMessage: Codable {} 
