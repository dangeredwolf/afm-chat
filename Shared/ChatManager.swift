//
//  ChatManager.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import FoundationModels
internal import Combine

class ChatManager: ObservableObject {
    @Published var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
            updateSession()
        }
    }
    
    @Published var temperature: Double {
        didSet {
            UserDefaults.standard.set(temperature, forKey: "temperature")
        }
    }
    
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    
    private var session: LanguageModelSession
    
    init() {
        let savedPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
        let savedTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 1.0
        
        self.systemPrompt = savedPrompt
        self.temperature = savedTemperature
        self.session = LanguageModelSession(instructions: savedPrompt)
    }
    
    func sendMessage() {
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }
        
        // Add user message
        let userChatMessage = ChatMessage(content: userMessage, isUser: true)
        messages.append(userChatMessage)
        
        // Create placeholder AI message for streaming
        let aiMessage = ChatMessage(content: "", isUser: false)
        messages.append(aiMessage)
        
        // Clear input and set loading state
        inputText = ""
        isLoading = true
        
        // Send to LLM with streaming
        Task {
            do {
                let generationOptions = GenerationOptions(temperature: temperature)
                let responseStream = session.streamResponse(to: userMessage, options: generationOptions)
                
                for try await response in responseStream {
                    await MainActor.run {
                        // Update the last message (AI response) with streaming content
                        if let lastIndex = self.messages.lastIndex(where: { !$0.isUser }) {
                            self.messages[lastIndex] = ChatMessage(content: response, isUser: false)
                        }
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    // Replace the placeholder with error message
                    if let lastIndex = self.messages.lastIndex(where: { !$0.isUser }) {
                        self.messages[lastIndex] = ChatMessage(content: "Error calling FoundationModel: \(error.localizedDescription)", isUser: false)
                    }
                    self.isLoading = false
                }
            }
        }
    }
    
    func clearChat() {
        messages.removeAll()
        updateSession()
    }
    
    private func updateSession() {
        session = LanguageModelSession(instructions: systemPrompt)
    }
} 
