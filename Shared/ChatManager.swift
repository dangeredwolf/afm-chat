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
    @Published var chats: [Chat] = []
    @Published var currentChatId: UUID? {
        didSet {
            if let chatId = currentChatId {
                UserDefaults.standard.set(chatId.uuidString, forKey: "currentChatId")
            }
            updateSession()
            // Force UI update
            objectWillChange.send()
        }
    }
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var editingMessageId: UUID? = nil
    @Published var savedMessagesForEdit: [ChatMessage] = []
    
    // Temporary chat that hasn't been saved yet
    @Published var temporaryChat: Chat? = nil
    
    private var session: LanguageModelSession
    
    // Computed property for current chat
    var currentChat: Chat? {
        get {
            // If we have a temporary chat and it matches current ID, return it
            if let tempChat = temporaryChat, tempChat.id == currentChatId {
                return tempChat
            }
            // Otherwise look in saved chats
            guard let currentChatId = currentChatId else { return nil }
            return chats.first { $0.id == currentChatId }
        }
        set {
            if let newChat = newValue {
                // If this is a temporary chat, update the temporary chat
                if let tempChat = temporaryChat, tempChat.id == newChat.id {
                    temporaryChat = newChat
                    // Force UI update when chat content changes
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                    }
                } else if let index = chats.firstIndex(where: { $0.id == newChat.id }) {
                    // Update saved chat
                    chats[index] = newChat
                    saveChats()
                    // Force UI update when chat content changes
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                    }
                }
            }
        }
    }
    
    // Computed property for current messages
    var currentMessages: [ChatMessage] {
        return currentChat?.messages ?? []
    }
    
    // Current chat's settings
    var currentSystemPrompt: String {
        return currentChat?.systemPrompt ?? "You are a helpful assistant."
    }
    
    var currentTemperature: Double {
        return currentChat?.temperature ?? 1.0
    }
    
    init() {
        // Initialize with default session
        self.session = LanguageModelSession(instructions: "You are a helpful assistant.")
        
        loadChats()
        
        // Don't automatically create a chat - let the navigation handle it
        // Users will explicitly navigate to create new chats or select existing ones
    }
    
    func createNewChat() -> UUID {
        // Get default settings from UserDefaults or use defaults
        let defaultPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
        let defaultTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 1.0
        
        let newChat = Chat(systemPrompt: defaultPrompt, temperature: defaultTemperature)
        
        // Store as temporary chat (not saved until first message)
        temporaryChat = newChat
        currentChatId = newChat.id
        updateSession()
        
        // Ensure UI updates
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        
        return newChat.id
    }
    
    func deleteChat(_ chatId: UUID) {
        // Check if it's a temporary chat
        if let tempChat = temporaryChat, tempChat.id == chatId {
            temporaryChat = nil
            currentChatId = nil
            return
        }
        
        // Handle saved chats
        guard chats.count > 1 else { return } // Always keep at least one chat
        
        chats.removeAll { $0.id == chatId }
        
        // If we deleted the current chat, switch to another one
        if currentChatId == chatId {
            currentChatId = chats.first?.id
        }
        
        saveChats()
    }
    
    func updateChatSettings(systemPrompt: String, temperature: Double) {
        guard var chat = currentChat else { return }
        chat.systemPrompt = systemPrompt
        chat.temperature = temperature
        currentChat = chat
        updateSession()
        
        // Also save as defaults
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        UserDefaults.standard.set(temperature, forKey: "temperature")
    }
    
    func sendMessage() {
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty, var chat = currentChat else { return }
        
        // If we're editing, clear the saved messages (confirming the edit)
        if editingMessageId != nil {
            savedMessagesForEdit = []
        }
        
        // Add user message
        let userChatMessage = ChatMessage(content: userMessage, isUser: true)
        chat.messages.append(userChatMessage)
        
        // Generate title from first message if needed
        if chat.messages.filter({ $0.isUser }).count == 1 {
            chat.generateTitle()
        }
        
        // If this is a temporary chat with its first message, save it permanently
        if let tempChat = temporaryChat, tempChat.id == chat.id, chat.messages.filter({ $0.isUser }).count == 1 {
            chats.insert(chat, at: 0) // Insert at beginning for most recent first
            temporaryChat = nil // Clear temporary chat
        }
        
        // Create placeholder AI message for streaming
        let aiMessage = ChatMessage(content: "", isUser: false)
        chat.messages.append(aiMessage)
        
        // Update the chat
        currentChat = chat
        
        // Clear input and editing state
        inputText = ""
        editingMessageId = nil
        isLoading = true
        
        // Send to LLM with streaming
        Task {
            do {
                let generationOptions = GenerationOptions(temperature: chat.temperature)
                let responseStream = session.streamResponse(to: userMessage, options: generationOptions)
                
                for try await response in responseStream {
                    await MainActor.run {
                        // Update the current chat's last message
                        if var currentChat = self.currentChat {
                            if let lastIndex = currentChat.messages.lastIndex(where: { !$0.isUser }) {
                                currentChat.messages[lastIndex] = ChatMessage(content: response, isUser: false)
                                self.currentChat = currentChat
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                    self.saveChats()
                }
            } catch {
                await MainActor.run {
                    // Replace the placeholder with error message
                    if var currentChat = self.currentChat {
                        if let lastIndex = currentChat.messages.lastIndex(where: { !$0.isUser }) {
                            currentChat.messages[lastIndex] = ChatMessage(content: "Error calling FoundationModel: \(error.localizedDescription)", isUser: false)
                            self.currentChat = currentChat
                        }
                    }
                    self.isLoading = false
                    self.saveChats()
                }
            }
        }
    }
    
    func clearCurrentChat() {
        guard var chat = currentChat else { return }
        chat.messages.removeAll()
        currentChat = chat
        updateSession()
        saveChats()
    }
    
    func editMessage(_ messageId: UUID) {
        guard var chat = currentChat,
              let messageIndex = chat.messages.firstIndex(where: { $0.id == messageId }),
              chat.messages[messageIndex].isUser else { return }
        
        let message = chat.messages[messageIndex]
        inputText = message.content
        editingMessageId = messageId
        
        // Save messages that will be temporarily hidden (including the message being edited)
        savedMessagesForEdit = Array(chat.messages[messageIndex...])
        
        // Temporarily remove this message and all subsequent messages
        chat.messages.removeAll { $0.timestamp >= message.timestamp }
        currentChat = chat
        // Don't save yet - we'll save when edit is confirmed or cancelled
    }
    
    func copyMessage(_ messageId: UUID) {
        guard let chat = currentChat,
              let message = chat.messages.first(where: { $0.id == messageId }) else { return }
        
        UIPasteboard.general.string = message.content
    }
    
    func cancelEditing() {
        guard var chat = currentChat else { return }
        
        // Restore the saved messages
        chat.messages.append(contentsOf: savedMessagesForEdit)
        currentChat = chat
        
        // Clear editing state
        editingMessageId = nil
        savedMessagesForEdit = []
        inputText = ""
        
        saveChats()
    }
    
    private func updateSession() {
        session = LanguageModelSession(instructions: currentSystemPrompt)
    }
    
    private func saveChats() {
        if let encoded = try? JSONEncoder().encode(chats) {
            UserDefaults.standard.set(encoded, forKey: "savedChats")
        }
    }
    
    private func loadChats() {
        if let data = UserDefaults.standard.data(forKey: "savedChats"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data) {
            self.chats = decoded
        }
    }
    
    func switchToChat(_ chatId: UUID) {
        // Clear any temporary chat when switching to a saved chat
        if let savedChat = chats.first(where: { $0.id == chatId }) {
            temporaryChat = nil
            currentChatId = chatId
        }
    }
} 
