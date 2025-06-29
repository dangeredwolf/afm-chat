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
            - "Explain quantum mechanics to me." → "Explanation of Quantum Mechanics"
            - "Plan a trip to Japan" → "Japan Travel Planning"
            - "Hello" - "User Greetings"
            
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
        // Get system prompt and tools setting for this chat
        let chat = getChatById(chatId)
        let systemPrompt = chat?.systemPrompt ?? "You are a helpful assistant."
        let toolsEnabled = chat?.toolsEnabled ?? true
        
        // Get messages for transcript rehydration
        var messagesToInclude: [ChatMessage] = []
        if let chat = chat {
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
        
        // Create session with conditional tools based on chat settings
        let tools: [any Tool] = toolsEnabled ? [
//                SafeWeatherTool(),
                JavaScriptTool(),
                LocationTool()
            ] : []
        
        print("Creating session with \(tools.count) tools, toolsEnabled: \(toolsEnabled)")
        
        // Create session with transcript rehydration
        // Note: When using transcript, instructions should be included in the transcript itself
        return LanguageModelSession(
            tools: tools,
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
    
    var currentToolsEnabled: Bool {
        return currentChat?.toolsEnabled ?? true
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
        let defaultToolsEnabled = UserDefaults.standard.object(forKey: "toolsEnabled") as? Bool ?? true
        
        let newChat = Chat(systemPrompt: defaultPrompt, temperature: defaultTemperature, toolsEnabled: defaultToolsEnabled)
        
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
    
    func updateChatSettings(systemPrompt: String, temperature: Double, toolsEnabled: Bool) {
        guard var chat = currentChat else { return }
        chat.systemPrompt = systemPrompt
        chat.temperature = temperature
        chat.toolsEnabled = toolsEnabled
        currentChat = chat
        
        // Recreate session with new settings and current transcript
        recreateCurrentSession()
        
        // Also save as defaults
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        UserDefaults.standard.set(temperature, forKey: "temperature")
        UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled")
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
        
        // Send to LLM with streaming and tool call tracking
        Task {
            await self.processLLMResponse(userMessage: userMessage, chat: chat)
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
    
    func retryMessage(_ messageId: UUID) {
        guard var chat = currentChat,
              let messageIndex = chat.messages.firstIndex(where: { $0.id == messageId }),
              !chat.messages[messageIndex].isUser,
              chat.messages[messageIndex].isError else { return }
        
        // Find the user message that triggered this error response
        let errorMessageTimestamp = chat.messages[messageIndex].timestamp
        guard let userMessageIndex = chat.messages.lastIndex(where: { $0.isUser && $0.timestamp < errorMessageTimestamp }) else { return }
        
        let userMessage = chat.messages[userMessageIndex].content
        
        // Remove the error message
        chat.messages.remove(at: messageIndex)
        
        // Create new placeholder for retry
        let aiMessage = ChatMessage(content: "", isUser: false)
        chat.messages.append(aiMessage)
        
        // Update the chat
        currentChat = chat
        isLoading = true
        
        // Retry the request with tool call tracking
        Task {
            await self.processLLMResponse(userMessage: userMessage, chat: chat)
        }
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
        if let data = UserDefaults.standard.data(forKey: "savedChats") {
            do {
                let decoded = try JSONDecoder().decode([Chat].self, from: data)
                self.chats = decoded
                print("Successfully loaded \(decoded.count) chats")
            } catch {
                print("Failed to decode saved chats: \(error)")
                print("This might be due to model changes. Attempting to recover...")
                
                // Try to recover by clearing the corrupted data
                // Note: This will lose the old chats, but prevents app crashes
                UserDefaults.standard.removeObject(forKey: "savedChats")
                
                // Backup the corrupted data before clearing
                let backupKey = "savedChats_backup_\(Date().timeIntervalSince1970)"
                UserDefaults.standard.set(data, forKey: backupKey)
                print("Corrupted data backed up to key: \(backupKey)")
                
                // Try to automatically recover from this backup
                self.chats = []
                print("Attempting automatic recovery...")
                if let recoveredChats = tryDecodeBackupData(data) {
                    self.chats = recoveredChats
                    saveChats() // Save in the new format
                    print("Successfully auto-recovered \(recoveredChats.count) chats!")
                    // Clean up the backup since we recovered successfully
                    UserDefaults.standard.removeObject(forKey: backupKey)
                } else {
                    print("Automatic recovery failed. Your previous chats were backed up but couldn't be loaded due to model changes.")
                    print("You can try manual recovery by calling tryRecoverChats() if needed.")
                }
            }
        }
    }
    
    func switchToChat(_ chatId: UUID) {
        // Clear any temporary chat when switching to a saved chat
        if let savedChat = chats.first(where: { $0.id == chatId }) {
            temporaryChat = nil
            currentChatId = chatId
        }
    }
    
    // Try to recover chats from backup (called manually if needed)
    @MainActor
    func tryRecoverChats() {
        let userDefaults = UserDefaults.standard
        let allKeys = userDefaults.dictionaryRepresentation().keys
        
        // Find backup keys
        let backupKeys = allKeys.filter { $0.hasPrefix("savedChats_backup_") }
        
        if !backupKeys.isEmpty {
            print("Found \(backupKeys.count) backup(s). Attempting to recover the most recent one...")
            
            if let mostRecentBackup = backupKeys.sorted().last,
               let backupData = userDefaults.data(forKey: mostRecentBackup) {
                
                print("Attempting to recover from: \(mostRecentBackup)")
                
                // Try to decode the backup data with a more flexible approach
                if let recoveredChats = tryDecodeBackupData(backupData) {
                    self.chats = recoveredChats
                    saveChats() // Save the recovered chats in the new format
                    print("Successfully recovered \(recoveredChats.count) chats!")
                    
                    // Clean up the backup
                    userDefaults.removeObject(forKey: mostRecentBackup)
                } else {
                    print("Failed to recover from backup")
                }
            }
        } else {
            print("No backup data found")
        }
    }
    
    private func tryDecodeBackupData(_ data: Data) -> [Chat]? {
        // This is a simplified recovery attempt
        // In a real implementation, you might want to try different decoding strategies
        do {
            let decoder = JSONDecoder()
            let chats = try decoder.decode([Chat].self, from: data)
            return chats
        } catch {
            print("Failed to decode backup data: \(error)")
            return nil
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
                // Log the specific error type for better debugging
                let chatError = ChatError.fromFoundationModelsError(error)
                print("Failed to generate AI title: \(chatError.title) - \(chatError.description)")
                // Fallback title is already set, so we don't need to do anything
            }
        }
    }
    
    // Process LLM response with real tool call information from transcript
    private func processLLMResponse(userMessage: String, chat: Chat) async {
        var lastToolCalls: [ToolCallInfo] = []
        var hasSeenToolCalls = false
        
        do {
            let generationOptions = GenerationOptions(temperature: chat.temperature)
            let responseStream = currentSession.streamResponse(to: userMessage, options: generationOptions)
            
            var currentResponse = ""
            var responseCount = 0
            var maxContentLength = 0
            var longestResponse = ""
            
            for try await response in responseStream {
                responseCount += 1
                print("Response chunk \(responseCount): \(response.prefix(50))...")
                await MainActor.run {
                    currentResponse = response
                    
                    // Track the longest response we've seen to preserve content
                    if response.count > maxContentLength {
                        maxContentLength = response.count
                        longestResponse = response
                        print("New longest response: \(response.count) chars")
                    }
                    
                    // Try to extract tool call information and full content from the session's transcript
                    // But don't let this block the response if it fails
                    var transcriptContent = ""
                    do {
                        let (extractedToolCalls, extractedContent) = self.extractToolCallsFromTranscript()
                        print("Extracted \(extractedToolCalls.count) tool calls")
                        transcriptContent = extractedContent
                        
                        // Keep track of tool calls - once we see them, keep showing them
                        if !extractedToolCalls.isEmpty {
                            hasSeenToolCalls = true
                            lastToolCalls = extractedToolCalls
                            print("Updated lastToolCalls with \(lastToolCalls.count) calls")
                        }
                    } catch {
                        print("Tool extraction failed: \(error)")
                        // Continue without tool calls if extraction fails
                    }
                    
                    // Use the tool calls we've seen (even if current extraction failed)
                    let toolCallsToShow = hasSeenToolCalls ? lastToolCalls : []
                    print("Showing \(toolCallsToShow.count) tool calls in UI")
                    
                    // Update the current chat's last message
                    // Use transcript content if available and longer, otherwise use response stream content
                    let finalContent: String
                    if !transcriptContent.isEmpty && transcriptContent.count >= currentResponse.count {
                        finalContent = transcriptContent
                        print("Using transcript content (\(transcriptContent.count) chars)")
                    } else {
                        finalContent = longestResponse.count > currentResponse.count ? longestResponse : currentResponse
                        print("Using response stream content (\(finalContent.count) chars)")
                    }
                    
                    if var currentChat = self.currentChat {
                        if let lastIndex = currentChat.messages.lastIndex(where: { !$0.isUser }) {
                            currentChat.messages[lastIndex] = ChatMessage(
                                content: finalContent,
                                isUser: false,
                                toolCalls: toolCallsToShow
                            )
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
                let chatError = ChatError.fromFoundationModelsError(error)
                
                if var currentChat = self.currentChat {
                    if let lastIndex = currentChat.messages.lastIndex(where: { !$0.isUser }) {
                        // Mark any existing tool calls as failed
                        var failedToolCalls = lastToolCalls
                        for i in failedToolCalls.indices {
                            failedToolCalls[i].status = .failed
                            failedToolCalls[i].error = error.localizedDescription
                        }
                        
                        currentChat.messages[lastIndex] = ChatMessage(
                            content: chatError.description,
                            isUser: false,
                            error: chatError,
                            toolCalls: failedToolCalls
                        )
                        self.currentChat = currentChat
                    }
                }
                self.isLoading = false
                self.saveChats()
            }
        }
    }
    
    // Extract tool call information and reconstruct full content from transcript
    private func extractToolCallsFromTranscript() -> ([ToolCallInfo], String) {
        var toolCalls: [ToolCallInfo] = []
        var toolOutputs: [String] = [] // Array of outputs in order
        var fullContent = ""
        
        // Access the transcript from the current session
        let transcript = currentSession.transcript
        let entries = Array(transcript)
        
        print("Transcript has \(entries.count) entries")
        
        // Find the most recent user prompt index
        var lastPromptIndex = -1
        for (index, entry) in entries.enumerated().reversed() {
            if case .prompt(_) = entry {
                lastPromptIndex = index
                break
            }
        }
        
        print("Last prompt index: \(lastPromptIndex)")
        
        // Collect tool calls, outputs, and responses that occurred after the last prompt
        if lastPromptIndex >= 0 && lastPromptIndex < entries.count - 1 {
            let relevantEntries = Array(entries[(lastPromptIndex + 1)...])
            print("Processing \(relevantEntries.count) relevant entries")
            
            // First pass: collect tool calls and build full content
            for (index, entry) in relevantEntries.enumerated() {
                print("Entry \(index): \(entry)")
                
                switch entry {
                case .response(let response):
                    // Add response content to full content
                    let responseText = response.segments.compactMap { segment in
                        switch segment {
                        case .text(let textSegment):
                            return textSegment.content
                        default:
                            return nil
                        }
                    }.joined(separator: "")
                    
                    if !responseText.isEmpty {
                        if !fullContent.isEmpty {
                            fullContent += "\n\n"
                        }
                        fullContent += responseText
                        print("Added response content: \(responseText.prefix(50))...")
                    }
                    
                case .toolCalls(let calls):
                    print("Found \(calls.count) tool calls")
                    for call in calls {
                        let toolCall = ToolCallInfo(
                            toolName: call.toolName,
                            toolDescription: getToolDescription(for: call.toolName),
                            arguments: String(describing: call.arguments),
                            status: .executing
                        )
                        toolCalls.append(toolCall)
                        print("Added tool call: \(call.toolName)")
                    }
                    
                case .toolOutput(let output):
                    let outputContent = extractToolOutputContent(from: output)
                    toolOutputs.append(outputContent)
                    print("Found tool output for: \(output.toolName) (output #\(toolOutputs.count))")
                    
                default:
                    print("Entry \(index) is other type")
                }
            }
            
            // Second pass: update tool call statuses by matching order
            for i in toolCalls.indices {
                if i < toolOutputs.count {
                    toolCalls[i].status = .completed
                    toolCalls[i].result = toolOutputs[i]
                    print("Marked tool call \(i) (\(toolCalls[i].toolName)) as completed with result: \(toolOutputs[i].prefix(20))...")
                }
            }
        }
        
        print("Returning \(toolCalls.count) tool calls and content: \(fullContent.prefix(100))...")
        return (toolCalls, fullContent)
    }
    
    // Get tool description for a given tool name
    private func getToolDescription(for toolName: String) -> String {
        switch toolName {
        case "getWeather":
            return "Retrieve the latest weather information for a city"
        case "Code Interpreter":
            return "Execute JavaScript code and returns the result"
        case "Location":
            return "Get the user's current location (coarse by default for privacy, with option for precise location)"
        default:
            return "Execute tool: \(toolName)"
        }
    }
    
    // Extract content from tool output
    private func extractToolOutputContent(from output: Transcript.ToolOutput) -> String {
        // Convert segments to readable text
        let content = output.segments.compactMap { segment in
            switch segment {
            case .text(let textSegment):
                return textSegment.content
            case .structure(let structuredSegment):
                return String(describing: structuredSegment.content)
            @unknown default:
                return nil
            }
        }.joined(separator: "\n")
        
        return content.isEmpty ? "Tool executed successfully" : content
    }

    

} 
