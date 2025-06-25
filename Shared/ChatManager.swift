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
    
    // Store sessions per chat to maintain context
    private var sessions: [UUID: LanguageModelSession] = [:]
    
    // Separate session for generating titles (not tied to any specific chat)
    private lazy var titleGenerationSession: LanguageModelSession = {
        return LanguageModelSession(instructions: """
            You are a helpful assistant that creates concise, descriptive titles for conversations.
            
            Your task is to generate a short, clear title (3-6 words) that captures the main topic or intent of the user's message.
            
            Guidelines:
            - Keep titles under 50 characters
            - Use title case (capitalize important words)
            - Use the same language as the original message (not always English)
            - Be specific and descriptive
            - Avoid generic phrases like "User Question" or "Help Request"
            - Focus on the main topic, action, or subject matter
            - Avoid quoting the text verbatim where possible
            
            Examples:
            - "How to bake chocolate cookies" → "Chocolate Cookie Recipe"
            - "What's the weather like today?" → "Today's Weather Forecast"
            - "Help me write a resume" → "Resume Writing Help"
            - "Explicar la física cuántica" → "Explicación de la Física Cuántica"
            - "Plan a trip to Japan" → "Japan Travel Planning"
            - "Hola" - "Saludo de Usuario"
            
            Respond with only the title in the same language as the original message, no additional text or punctuation.
            """)
    }()
    
    // Current session for the active chat
    private var currentSession: LanguageModelSession {
        guard let chatId = currentChatId else {
            // Fallback session if no chat is selected
            return LanguageModelSession(
                 instructions: "You are a helpful assistant."
            )
        }
        
        // Get or create session for this chat
        if let existingSession = sessions[chatId] {
            return existingSession
        } else {
            let newSession = createSessionForChat(chatId: chatId)
            sessions[chatId] = newSession
            return newSession
        }
    }
    

    
    // Create a new session for a specific chat with transcript rehydration
    private func createSessionForChat(chatId: UUID, upToMessage: UUID? = nil) -> LanguageModelSession {
        // Get system prompt for this chat
        let systemPrompt = getChatById(chatId)?.systemPrompt ?? "You are a helpful assistant."
        
        // Get messages for transcript rehydration
        var messagesToInclude: [ChatMessage] = []
        if let chat = getChatById(chatId) {
            if let upToMessageId = upToMessage {
                // When editing, only include messages up to (but not including) the message being edited
                if let messageIndex = chat.messages.firstIndex(where: { $0.id == upToMessageId }) {
                    messagesToInclude = Array(chat.messages.prefix(messageIndex))
                }
            } else {
                // Include all messages for full rehydration
                messagesToInclude = chat.messages
            }
        }
        
        // Create transcript from existing messages
        // let transcript = createTranscriptFromMessages(messagesToInclude)
        
        // Create session with transcript rehydration
        // Note: When using transcript, instructions should be included in the transcript itself
        return LanguageModelSession(
            // tools: [
            //     WeatherTool()
            // ],
            // transcript: transcript,
            instructions: systemPrompt
        )
    }
    
    // Convert ChatMessages to Transcript for session rehydration
//    private func createTranscriptFromMessages(_ messages: [ChatMessage]) -> Transcript {
//        let entries: [Transcript.Entry] = messages.compactMap { message in
//            if message.isUser {
//                // Create user prompt entry
//                let textSegment = Transcript.Segment.text(Transcript.TextSegment(content: message.content))
//                let prompt = Transcript.Prompt(segments: [textSegment])
//                return .prompt(prompt)
//            } else {
//                // Create assistant response entry (only include non-empty responses)
//                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                    let textSegment = Transcript.Segment.text(Transcript.TextSegment(content: message.content))
//                    let response = Transcript.Response(assetIDs: [], segments: [textSegment])
//                    return .response(response)
//                }
//                return nil
//            }
//        }
//        
        // TODO: This builds fine but crashes in 26.0 beta 2
//        return Transcript.init(entries: entries)
//    }
    
    // Helper method to get chat by ID from either temporary or saved chats
    private func getChatById(_ chatId: UUID) -> Chat? {
        if let tempChat = temporaryChat, tempChat.id == chatId {
            return tempChat
        }
        return chats.first { $0.id == chatId }
    }
    
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
        loadChats()
        
        // Don't automatically create a chat - let the navigation handle it
        // Users will explicitly navigate to create new chats or select existing ones
        // Sessions will be created per-chat as needed
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
            // Clean up session
            sessions.removeValue(forKey: chatId)
            return
        }
        
        // Handle saved chats
        guard chats.count > 1 else { return } // Always keep at least one chat
        
        chats.removeAll { $0.id == chatId }
        
        // Clean up session for deleted chat
        sessions.removeValue(forKey: chatId)
        
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
        
        // Recreate session with new settings and current transcript
        recreateCurrentSession()
        
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
            // After confirming edit, recreate session with full transcript including the new message
            if let chatId = currentChatId {
                // We'll recreate the session after adding the new user message
                // This ensures the transcript includes the edited conversation flow
            }
        }
        
        // Add user message
        let userChatMessage = ChatMessage(content: userMessage, isUser: true)
        chat.messages.append(userChatMessage)
        
        // Generate AI title from first message if needed
        if chat.messages.filter({ $0.isUser }).count == 1 {
            // Generate fallback title immediately
            chat.generateFallbackTitle()
            
            // Generate AI title in the background
            generateAITitle(for: chat.id, userMessage: userMessage)
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
        
        // If we were editing, recreate the session with the full transcript including the new edited flow
        let wasEditing = editingMessageId != nil
        
        // Clear input and editing state
        inputText = ""
        editingMessageId = nil
        isLoading = true
        
        // Recreate session if we were editing to ensure proper transcript rehydration
        if wasEditing, let chatId = currentChatId {
            let newSession = createSessionForChat(chatId: chatId)
            sessions[chatId] = newSession
        }
        
        // Send to LLM with streaming
        Task {
            do {
                let generationOptions = GenerationOptions(temperature: chat.temperature)
                let responseStream = currentSession.streamResponse(to: userMessage, options: generationOptions)
                
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
        
        // Recreate the session with transcript up to the edit point
        if let chatId = currentChatId {
            let newSession = createSessionForChat(chatId: chatId, upToMessage: messageId)
            sessions[chatId] = newSession
        }
        
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
        
        // Recreate the session with the full transcript
        if let chatId = currentChatId {
            let newSession = createSessionForChat(chatId: chatId)
            sessions[chatId] = newSession
        }
        
        // Clear editing state
        editingMessageId = nil
        savedMessagesForEdit = []
        inputText = ""
        
        saveChats()
    }
    
    private func updateSession() {
        // Update or create session for current chat
        // Each chat maintains its own session to preserve conversation context
        guard let chatId = currentChatId else { return }
        
        // Force recreation of the session to ensure transcript is up to date
        // This is important when switching between chats or when settings change
        let newSession = createSessionForChat(chatId: chatId)
        sessions[chatId] = newSession
    }
    
    // Force recreation of the current session (useful when settings change)
    func recreateCurrentSession() {
        guard let chatId = currentChatId else { return }
        let newSession = createSessionForChat(chatId: chatId)
        sessions[chatId] = newSession
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
    
    private func generateAITitle(for chatId: UUID, userMessage: String) {
        // Generate AI title in the background
        Task {
            do {
                let prompt = "Generate a title for a conversation whose first message is: \"\(userMessage)\""
                let response = try await titleGenerationSession.respond(to: prompt)
                
                await MainActor.run {
                    // Find and update the chat with the AI-generated title
                    let aiTitle = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Validate the AI title (ensure it's not too long and not empty)
                    if !aiTitle.isEmpty && aiTitle.count <= 50 {
                        // Update the chat in the appropriate location (temporary or saved)
                        if let tempChat = self.temporaryChat, tempChat.id == chatId {
                            var updatedTempChat = tempChat
                            updatedTempChat.title = aiTitle
                            self.temporaryChat = updatedTempChat
                        } else if let chatIndex = self.chats.firstIndex(where: { $0.id == chatId }) {
                            self.chats[chatIndex].title = aiTitle
                            self.saveChats()
                        }
                        
                        // Force UI update
                        self.objectWillChange.send()
                    } else {
                        // Keep the fallback title if AI title is invalid
                        print("AI title invalid or too long: \(aiTitle)")
                    }
                }
            } catch {
                print("Failed to generate AI title: \(error)")
                // Fallback title is already set, so we don't need to do anything
            }
        }
    }
} 
