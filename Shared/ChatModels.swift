//
//  ChatModels.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
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
    
    // Generate a smart title based on the first user message
    mutating func generateTitle() {
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