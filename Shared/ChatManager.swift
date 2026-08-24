//
//  ChatManager.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
internal import Combine

@MainActor
class ChatManager: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var currentChatId: UUID? {
        didSet {
            if let chatId = currentChatId {
                UserDefaults.standard.set(chatId.uuidString, forKey: "currentChatId")
            }
            updateSession()
        }
    }
    @Published var inputText: String = ""
    @Published var pendingAttachments: [ChatMessageAttachment] = []
    @Published var isLoading: Bool = false
    @Published var generationPhase: ChatGenerationPhase = .idle
    @Published var editingMessageId: UUID? = nil
    @Published var savedMessagesForEdit: [ChatMessage] = []
    @Published var contextUsage: LLMContextUsage?
    @Published var contextWindowSizes: [LLMModelChoice: Int] = [:]
    
    // Temporary chat that hasn't been saved yet
    @Published var temporaryChat: Chat? = nil
    
    // Store sessions per chat to maintain context
    private var sessions: [UUID: LLMSession] = [:]
    private var cachedContextLimit: Int?
    private var generationTask: Task<Void, Never>?
    private var generationEpoch: UInt64 = 0

    private static let systemPromptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func resolvedInstructions(systemPrompt: String, appendDate: Bool) -> String {
        guard appendDate else { return systemPrompt }
        let dateString = systemPromptDateFormatter.string(from: Date())
        return "\(systemPrompt)\n\nToday's date is \(dateString)."
    }
    
    // Separate session for generating titles (not tied to any specific chat)
    private lazy var titleGenerationSession: LLMSession = {
        return LLMProviderManager.shared.client.createSession(
            instructions: """
            You are a helpful assistant that creates concise, descriptive titles for conversations.
            
            Your task is to generate a short, clear title (3-6 words) that captures the main topic or intent of the user's message.
            
            Guidelines:
            - Keep titles under 50 characters
            - Use title case (capitalize important words)
            - Use the same language as the original message (not always English)
            - Be specific and descriptive
            - Avoid generic phrases like User Question or Help Request
            - Focus on the main topic, action, or subject matter
            - Avoid quoting the text verbatim where possible
            
            Examples:
            - "How to bake chocolate cookies" → Chocolate Cookie Recipe
            - "What's the weather like today?" → Today's Weather Forecast
            - "Help me write a resume" → Resume Writing Help
            - "Explain quantum mechanics to me." → Explanation of Quantum Mechanics
            - "Plan a trip to Japan" → Japan Travel Planning
            - "Hello" → User Greetings
            
            Respond with only the title in the same language as the original message, no additional text or punctuation.
            """,
            tools: [],
            configuration: LLMSessionConfiguration(model: .onDevice, temperature: 0.7, reasoningLevel: .light)
        )
    }()
    
    // Current session for the active chat
    private var currentSession: LLMSession {
        guard let chatId = currentChatId else {
            // Fallback session if no chat is selected
            return LLMProviderManager.shared.client.createSession(
                instructions: "You are a helpful assistant.",
                tools: [],
                configuration: LLMSessionConfiguration()
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
    private func createSessionForChat(
        chatId: UUID,
        upToMessage: UUID? = nil,
        additionalFileAttachments: [ChatMessageAttachment] = []
    ) -> LLMSession {
        // Get system prompt and tools setting for this chat
        let chat = getChatById(chatId)
        let toolsEnabled = chat?.toolsEnabled ?? false
        
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
        
        let capabilities = AttachmentMediaSupport.capabilities(for: chat?.model ?? .onDevice)
        let includeFileNames = chat?.model.mlxModelID != nil
        let history = messagesToInclude.map { message -> LLMHistoryEntry in
            let entry = LLMHistoryEntry(
                isUser: message.isUser,
                content: message.content,
                attachments: message.isUser ? message.attachments.map { $0.toLLMAttachment() } : [],
                toolCalls: message.toolCalls.compactMap { toolCall in
                    guard toolCall.status == .completed || toolCall.status == .failed else { return nil }
                    return LLMHistoryToolCall(
                        transcriptID: toolCall.transcriptID,
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments,
                        result: toolCall.result,
                        error: toolCall.error
                    )
                },
                reasoningContent: message.isUser ? nil : message.reasoningContent,
                transcriptBlocks: message.isUser ? [] : message.historyTranscriptBlocks()
            )
            return AttachmentMediaSupport.preparedHistoryEntry(
                entry,
                capabilities: capabilities,
                includeFileNames: includeFileNames
            )
        }

        // Create session with conditional tools based on chat settings and per-tool flags
        var toolList: [LLMTool] = []
        if toolsEnabled {
            for definition in AppToolCatalog.userTogglable where isUserToolEnabled(definition.id, in: chat) {
                toolList.append(definition.asLLMTool())
            }
        }

        let fileAttachments = (messagesToInclude.flatMap(\.attachments) + additionalFileAttachments)
            .filter { !$0.isModelSupportedImage && !$0.isAudio && !$0.isVideo }

        if !fileAttachments.isEmpty {
            let registry = AttachmentRegistry(attachments: fileAttachments)
            toolList.append(AppToolID.readAttachment.definition.asLLMTool(attachmentRegistry: registry))
        }
        
        return LLMProviderManager.shared.client.createSession(
            instructions: Self.resolvedInstructions(
                systemPrompt: chat?.systemPrompt ?? "You are a helpful assistant.",
                appendDate: chat?.appendDateToSystemPrompt ?? true
            ),
            tools: toolList,
            configuration: LLMSessionConfiguration(
                model: chat?.model ?? .onDevice,
                temperature: chat?.temperature ?? 1.0,
                reasoningLevel: chat?.reasoningLevel ?? .moderate,
                thinkingEnabled: chat?.thinkingEnabled ?? true,
                thinkingBudgetTokens: chat?.thinkingBudgetTokens,
                history: history,
                guardrails: .permissiveContentTransformations
            )
        )
    }

    
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
            guard let newChat = newValue else { return }
            if let tempChat = temporaryChat, tempChat.id == newChat.id {
                temporaryChat = newChat
            } else if let index = chats.firstIndex(where: { $0.id == newChat.id }) {
                var updatedChats = chats
                updatedChats[index] = newChat
                chats = updatedChats
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

    var currentReasoningLevel: LLMReasoningLevel {
        return currentChat?.reasoningLevel ?? .moderate
    }

    var currentThinkingEnabled: Bool {
        return currentChat?.thinkingEnabled ?? true
    }

    var currentThinkingBudgetTokens: Int? {
        return currentChat?.thinkingBudgetTokens
    }

    var currentModel: LLMModelChoice {
        return currentChat?.model ?? .onDevice
    }
    
    var currentToolsEnabled: Bool {
        return currentChat?.toolsEnabled ?? false
    }

    var currentAppendDateToSystemPrompt: Bool {
        return currentChat?.appendDateToSystemPrompt ?? true
    }

    var showsContextUsageIndicator: Bool {
        (contextUsage?.usedTokens ?? 0) > 0
    }
    
    init() {
        loadChats()
        
        // Don't automatically create a chat - let the navigation handle it
        // Users will explicitly navigate to create new chats or select existing ones
        // Sessions will be created per-chat as needed
    }
    
    private func resolvedDefaultModel() -> LLMModelChoice {
        AFMModelCatalog.resolvedDefaultModel()
    }

    private func defaultSettingsValues() -> ChatSettingsValues {
        var values = ChatSettingsValues.fromUserDefaults()
        values.model = resolvedDefaultModel()
        return values
    }

    func createNewChat() -> UUID {
        let defaults = settingsValues(for: .defaults)
        let newChat = Chat(systemPrompt: defaults.systemPrompt,
                           temperature: defaults.temperature,
                           model: defaults.model,
                           reasoningLevel: defaults.reasoningLevel,
                           thinkingEnabled: defaults.thinkingEnabled,
                           thinkingBudgetTokens: defaults.thinkingBudgetTokens,
                           toolsEnabled: defaults.toolsEnabled,
                           toolCodeInterpreterEnabled: defaults.toolCodeInterpreterEnabled,
                           toolWebSearchEnabled: defaults.toolWebSearchEnabled,
                           toolWebFetchEnabled: defaults.toolWebFetchEnabled,
                           appendDateToSystemPrompt: defaults.appendDateToSystemPrompt)
        
        // Store as temporary chat (not saved until first message)
        temporaryChat = newChat
        currentChatId = newChat.id
        
        return newChat.id
    }
    
    func deleteChat(_ chatId: UUID) {
        if isLoading, currentChatId == chatId {
            stopGeneration()
        }
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
    
    func updateChatSettings(
        systemPrompt: String,
        temperature: Double,
        model: LLMModelChoice,
        reasoningLevel: LLMReasoningLevel,
        toolsEnabled: Bool,
        appendDateToSystemPrompt: Bool,
        perTools: (code: Bool, webSearch: Bool, webFetch: Bool)? = nil,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?
    ) {
        guard !isLoading, var chat = currentChat else { return }
        chat.systemPrompt = systemPrompt
        chat.temperature = temperature
        chat.model = model
        chat.reasoningLevel = reasoningLevel
        chat.thinkingEnabled = thinkingEnabled
        chat.thinkingBudgetTokens = thinkingBudgetTokens
        chat.toolsEnabled = toolsEnabled
        chat.appendDateToSystemPrompt = appendDateToSystemPrompt
        if let perTools = perTools {
            chat.toolCodeInterpreterEnabled = perTools.code
            chat.toolWebSearchEnabled = perTools.webSearch
            chat.toolWebFetchEnabled = perTools.webFetch
        }
        currentChat = chat
        
        // Recreate session with new settings and current transcript
        recreateCurrentSession()
        refreshContextWindowMetadata()
        
        updateDefaultSettings(
            systemPrompt: systemPrompt,
            temperature: temperature,
            model: model,
            reasoningLevel: reasoningLevel,
            toolsEnabled: toolsEnabled,
            appendDateToSystemPrompt: appendDateToSystemPrompt,
            perTools: perTools,
            thinkingEnabled: thinkingEnabled,
            thinkingBudgetTokens: thinkingBudgetTokens
        )

        saveChats()
    }

    func settingsValues(for scope: ChatSettingsScope) -> ChatSettingsValues {
        switch scope {
        case .currentChat:
            if let chat = currentChat {
                return ChatSettingsValues(from: chat)
            }
            return defaultSettingsValues()
        case .defaults:
            return defaultSettingsValues()
        }
    }

    func persistSettings(_ values: ChatSettingsValues, scope: ChatSettingsScope) {
        switch scope {
        case .currentChat:
            updateChatSettings(
                systemPrompt: values.systemPrompt,
                temperature: values.temperature,
                model: values.model,
                reasoningLevel: values.reasoningLevel,
                toolsEnabled: values.toolsEnabled,
                appendDateToSystemPrompt: values.appendDateToSystemPrompt,
                perTools: (
                    code: values.toolCodeInterpreterEnabled,
                    webSearch: values.toolWebSearchEnabled,
                    webFetch: values.toolWebFetchEnabled
                ),
                thinkingEnabled: values.thinkingEnabled,
                thinkingBudgetTokens: values.thinkingBudgetTokens
            )
        case .defaults:
            updateDefaultSettings(
                systemPrompt: values.systemPrompt,
                temperature: values.temperature,
                model: values.model,
                reasoningLevel: values.reasoningLevel,
                toolsEnabled: values.toolsEnabled,
                appendDateToSystemPrompt: values.appendDateToSystemPrompt,
                perTools: (
                    code: values.toolCodeInterpreterEnabled,
                    webSearch: values.toolWebSearchEnabled,
                    webFetch: values.toolWebFetchEnabled
                ),
                thinkingEnabled: values.thinkingEnabled,
                thinkingBudgetTokens: values.thinkingBudgetTokens
            )
        }
    }

    func updateDefaultSettings(
        systemPrompt: String,
        temperature: Double,
        model: LLMModelChoice,
        reasoningLevel: LLMReasoningLevel,
        toolsEnabled: Bool,
        appendDateToSystemPrompt: Bool,
        perTools: (code: Bool, webSearch: Bool, webFetch: Bool)? = nil,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?
    ) {
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        UserDefaults.standard.set(temperature, forKey: "temperature")
        UserDefaults.standard.set(model.rawValue, forKey: "model")
        UserDefaults.standard.set(reasoningLevel.rawValue, forKey: "reasoningLevel")
        UserDefaults.standard.set(thinkingEnabled, forKey: "thinkingEnabled")
        if let thinkingBudgetTokens, thinkingBudgetTokens > 0 {
            UserDefaults.standard.set(thinkingBudgetTokens, forKey: "thinkingBudgetTokens")
        } else {
            UserDefaults.standard.removeObject(forKey: "thinkingBudgetTokens")
        }
        UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled")
        UserDefaults.standard.set(appendDateToSystemPrompt, forKey: "appendDateToSystemPrompt")
        if let perTools {
            UserDefaults.standard.set(perTools.code, forKey: "toolCodeInterpreterEnabled")
            UserDefaults.standard.set(perTools.webSearch, forKey: "toolWebSearchEnabled")
            UserDefaults.standard.set(perTools.webFetch, forKey: "toolWebFetchEnabled")
        }
    }

    func selectModel(_ model: LLMModelChoice, scope: ChatSettingsScope = .currentChat) {
        switch scope {
        case .currentChat:
            updateChatSettings(
                systemPrompt: currentSystemPrompt,
                temperature: currentTemperature,
                model: model,
                reasoningLevel: currentReasoningLevel,
                toolsEnabled: currentToolsEnabled,
                appendDateToSystemPrompt: currentAppendDateToSystemPrompt,
                thinkingEnabled: currentThinkingEnabled,
                thinkingBudgetTokens: currentThinkingBudgetTokens
            )
        case .defaults:
            UserDefaults.standard.set(model.rawValue, forKey: "model")
        }
    }

    func resetChats(usingDeletedModel modelID: String) {
        let deleted = LLMModelChoice.mlx(id: modelID)
        var didChange = false

        if currentModel == deleted {
            selectModel(.onDevice)
        }

        for index in chats.indices where chats[index].model == deleted {
            chats[index].model = .onDevice
            sessions.removeValue(forKey: chats[index].id)
            didChange = true
        }
        if var tempChat = temporaryChat, tempChat.model == deleted {
            tempChat.model = .onDevice
            temporaryChat = tempChat
            sessions.removeValue(forKey: tempChat.id)
            didChange = true
        }
        if didChange {
            saveChats()
        }
    }
    
    func sendMessage() {
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard (!userMessage.isEmpty || !attachmentsToSend.isEmpty), var chat = currentChat else { return }
        
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
        let userChatMessage = ChatMessage(
            content: userMessage,
            isUser: true,
            attachments: attachmentsToSend,
            model: chat.model
        )
        chat.messages.append(userChatMessage)
        
        // Generate AI title from first message if needed
        if chat.messages.filter({ $0.isUser }).count == 1 {
            // Generate fallback title immediately
            chat.generateFallbackTitle()
            
            // Generate AI title in the background
            let titleSource = userMessage.isEmpty ? attachmentsToSend.first?.label ?? "Attachment" : userMessage
            generateAITitle(for: chat.id, userMessage: titleSource)
        }
        
        // If this is a temporary chat with its first message, save it permanently
        let isPromotingTemporary = temporaryChat?.id == chat.id
            && chat.messages.filter({ $0.isUser }).count == 1

        // Create placeholder AI message for streaming
        let aiMessage = ChatMessage(
            content: "",
            isUser: false,
            reasoningDuration: AFMModelCatalog.usesAppleReasoningLevels(chat.model) ? 0 : nil,
            model: chat.model
        )
        chat.messages.append(aiMessage)

        if isPromotingTemporary {
            temporaryChat = nil
            chats.append(chat)
        } else {
            updateStoredChat(chat)
        }
        
        // Clear input and editing state
        inputText = ""
        pendingAttachments = []
        editingMessageId = nil
        isLoading = true
        generationPhase = initialGenerationPhase(for: chat.model)

        // Recreate session before streaming so tools (e.g. Read Attachment) and transcript
        // reflect the outgoing message. History excludes the new user/assistant placeholders;
        // the user turn is sent via the stream prompt below.
        if let chatId = currentChatId {
            let newSession = createSessionForChat(
                chatId: chatId,
                upToMessage: userChatMessage.id,
                additionalFileAttachments: attachmentsToSend
            )
            sessions[chatId] = newSession
        }
        
        // Send to LLM with streaming and tool call tracking
        let llmPrompt = LLMPrompt(
            text: userMessage,
            attachments: attachmentsToSend.map { $0.toLLMAttachment() }
        )
        startGeneration(
            assistantMessageId: aiMessage.id,
            chat: chat,
            prompt: llmPrompt
        )
    }

    func stopGeneration() {
        guard isLoading else { return }
        let assistantId = currentChat?.messages.last(where: { !$0.isUser })?.id
        invalidateGeneration()
        finishStoppedGeneration(assistantMessageId: assistantId)
    }

    private func startGeneration(assistantMessageId: UUID, chat: Chat, prompt: LLMPrompt) {
        generationEpoch += 1
        let epoch = generationEpoch
        generationTask = Task { @MainActor in
            await self.prepareThenRespond(
                prompt: prompt,
                chat: chat,
                assistantMessageId: assistantMessageId,
                epoch: epoch
            )
        }
    }

    private func invalidateGeneration() {
        generationEpoch += 1
        generationTask?.cancel()
        generationTask = nil
    }

    private func isCurrentGeneration(_ epoch: UInt64) -> Bool {
        generationEpoch == epoch
    }

    private func finishStoppedGeneration(assistantMessageId: UUID?) {
        isLoading = false
        generationPhase = .idle
        generationTask = nil
        if let assistantMessageId {
            finalizeStoppedAssistantMessage(id: assistantMessageId)
        }
        if let chatId = currentChatId {
            sessions[chatId] = createSessionForChat(chatId: chatId)
        }
        refreshContextUsage()
        saveChats()
    }

    private func finalizeStoppedAssistantMessage(id: UUID) {
        guard var chat = currentChat,
              let index = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        let message = chat.messages[index]
        let hasText = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = !(message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTools = !message.toolCalls.isEmpty

        if !hasText && !hasReasoning && !hasTools {
            chat.messages.remove(at: index)
            currentChat = chat
            return
        }

        var toolCalls = message.toolCalls
        for toolIndex in toolCalls.indices {
            if toolCalls[toolIndex].status == .pending || toolCalls[toolIndex].status == .executing {
                toolCalls[toolIndex].status = .failed
                toolCalls[toolIndex].error = "Stopped"
            }
        }

        var blocks = message.transcriptBlocks
        if case .reasoning(_, let content, _) = blocks.last,
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.removeLast()
        }

        chat.messages[index] = message.updatedForStreaming(
            content: message.content,
            toolCalls: toolCalls,
            reasoningContent: message.reasoningContent,
            reasoningDuration: message.reasoningDuration,
            reasoningTokenCount: message.reasoningTokenCount,
            transcriptBlocks: blocks
        )
        currentChat = chat
    }

    func removePendingAttachment(_ attachmentId: UUID) {
        pendingAttachments = pendingAttachments.filter { $0.id != attachmentId }
    }

    func addPendingAttachment(from sourceURL: URL, label: String, kind _: ChatMessageAttachmentKind) {
        guard let chatId = currentChatId else {
            print("Failed to import attachment: no active chat")
            return
        }
        do {
            let storedURL = try ChatAttachments.importFile(from: sourceURL, chatId: chatId, suggestedName: label)
            let resolvedKind = ChatAttachments.kind(
                mimeType: ChatAttachments.mimeType(for: storedURL),
                fileURL: storedURL
            )
            let attachment = ChatMessageAttachment(fileURL: storedURL, chatId: chatId, label: label, kind: resolvedKind)
            pendingAttachments = pendingAttachments + [attachment]
        } catch {
            print("Failed to import attachment: \(error)")
        }
    }

    func addPendingImageAttachment(_ image: UIImage, label: String) {
        guard let chatId = currentChatId else { return }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            let storedURL = try ChatAttachments.saveData(
                data,
                chatId: chatId,
                suggestedName: label,
                fileExtension: "jpg"
            )
            let attachment = ChatMessageAttachment(
                fileURL: storedURL,
                chatId: chatId,
                label: label,
                kind: .image
            )
            pendingAttachments = pendingAttachments + [attachment]
        } catch {
            print("Failed to save image attachment: \(error)")
        }
    }

    func addPendingDataAttachment(_ data: Data, label: String) {
        if let image = UIImage(data: data) {
            addPendingImageAttachment(image, label: label)
            return
        }

        guard let chatId = currentChatId else { return }
        do {
            let storedURL = try ChatAttachments.saveData(
                data,
                chatId: chatId,
                suggestedName: label,
                fileExtension: "dat"
            )
            let attachment = ChatMessageAttachment(
                fileURL: storedURL,
                chatId: chatId,
                label: label,
                kind: .file
            )
            pendingAttachments = pendingAttachments + [attachment]
        } catch {
            print("Failed to save data attachment: \(error)")
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
        pendingAttachments = []
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
        
        let userMessage = chat.messages[userMessageIndex]
        let llmPrompt = LLMPrompt(
            text: userMessage.content,
            attachments: userMessage.attachments.map { $0.toLLMAttachment() }
        )
        
        // Remove the error message
        chat.messages.remove(at: messageIndex)
        
        // Create new placeholder for retry
        let aiMessage = ChatMessage(
            content: "",
            isUser: false,
            reasoningDuration: AFMModelCatalog.usesAppleReasoningLevels(chat.model) ? 0 : nil,
            model: chat.model
        )
        chat.messages.append(aiMessage)
        
        // Update the chat
        currentChat = chat
        isLoading = true
        generationPhase = initialGenerationPhase(for: chat.model)

        if let chatId = currentChatId {
            let newSession = createSessionForChat(
                chatId: chatId,
                upToMessage: userMessage.id,
                additionalFileAttachments: userMessage.attachments
            )
            sessions[chatId] = newSession
        }
        
        // Retry the request with tool call tracking
        startGeneration(
            assistantMessageId: aiMessage.id,
            chat: chat,
            prompt: llmPrompt
        )
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
        pendingAttachments = []
        
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
        refreshContextWindowMetadata()
        refreshContextUsage()
    }
    
    // Force recreation of the current session (useful when settings change)
    func recreateCurrentSession() {
        guard let chatId = currentChatId else { return }
        let newSession = createSessionForChat(chatId: chatId)
        sessions[chatId] = newSession
        refreshContextWindowMetadata()
        refreshContextUsage()
    }

    func refreshContextWindowMetadata() {
        let model = currentModel
        Task {
            await self.loadContextWindowMetadata(for: model)
        }
    }

    private func loadContextWindowMetadata(for model: LLMModelChoice) async {
        let sizes = await AFMModelCatalog.allContextSizes()
        contextWindowSizes = sizes
        cachedContextLimit = sizes[model]
        refreshContextUsage()
    }

    func refreshContextUsage() {
        guard let limit = cachedContextLimit else {
            contextUsage = nil
            return
        }

        contextUsage = currentSession.currentContextUsage(contextLimit: limit)
    }
    
    private func updateStoredChat(_ chat: Chat) {
        if let tempChat = temporaryChat, tempChat.id == chat.id {
            temporaryChat = chat
        } else if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            var updatedChats = chats
            updatedChats[index] = chat
            chats = updatedChats
        }
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
                    saveChats()
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
                let responseText = try await titleGenerationSession.respond(to: prompt, temperature: 0.7)
                
                await MainActor.run {
                    let aiTitle = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !aiTitle.isEmpty && aiTitle.count <= 50 {
                        if let tempChat = self.temporaryChat, tempChat.id == chatId {
                            var updatedTempChat = tempChat
                            updatedTempChat.title = aiTitle
                            self.temporaryChat = updatedTempChat
                        } else if let chatIndex = self.chats.firstIndex(where: { $0.id == chatId }) {
                            var updatedChats = self.chats
                            updatedChats[chatIndex].title = aiTitle
                            self.chats = updatedChats
                            self.saveChats()
                        }
                    } else {
                        // Keep the fallback title if AI title is invalid
                        print("AI title invalid or too long: \(aiTitle)")
                    }
                }
            } catch {
                // Log the specific error type for better debugging
                let chatError = ChatError.fromError(error)
                print("Failed to generate AI title: \(chatError.title) - \(chatError.description)")
                // Fallback title is already set, so we don't need to do anything
            }
        }
    }
    
    // Process LLM response with real tool call information from transcript
    private func processLLMResponse(
        prompt: LLMPrompt,
        chat: Chat,
        assistantMessageId: UUID,
        epoch: UInt64
    ) async {
        let assembler = AssistantTranscriptAssembler()
        let usesAppleReasoning = AFMModelCatalog.usesAppleReasoningLevels(chat.model)
        let tracksThinkingClock = usesAppleReasoning || chat.thinkingEnabled

        if usesAppleReasoning {
            assembler.startPlaceholderThinking()
            publishAssembledMessage(assembler, id: assistantMessageId)
        }

        do {
            let responseStream = currentSession.streamResponse(to: prompt, temperature: chat.temperature)
            for try await event in responseStream {
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.isCurrentGeneration(epoch) else { return }
                    switch event {
                    case .generationStarted:
                        if tracksThinkingClock && usesAppleReasoning {
                            assembler.startPlaceholderThinking()
                        }
                        assembler.refreshOpenReasoningDuration()
                    case .contentUpdated(let fullText):
                        assembler.applyContent(fullText)
                    case .toolCallsUpdated(let calls):
                        assembler.applyToolCalls(self.resolvedToolCalls(calls, existing: assembler.toolCalls))
                        self.updateGenerationPhaseForToolCalls(assembler.toolCalls, modelName: chat.model.displayName)
                    case .reasoningUpdated(let content, let tokenCount, let entryCount):
                        assembler.applyReasoning(content, tokenCount: tokenCount, entryCount: entryCount)
                    }
                    self.publishAssembledMessage(assembler, id: assistantMessageId)
                    self.refreshContextUsage()
                }
            }

            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                if assembler.reasoningTokenCount == nil {
                    assembler.reasoningTokenCount = self.contextUsage?.reasoningTokens
                }
                assembler.finalize()
                self.publishAssembledMessage(assembler, id: assistantMessageId)
                self.isLoading = false
                self.generationPhase = .idle
                self.generationTask = nil
                self.refreshContextUsage()
                self.saveChats()
            }
        } catch {
            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                if error is CancellationError || Task.isCancelled {
                    assembler.finalize()
                    self.publishAssembledMessage(assembler, id: assistantMessageId)
                    self.finishStoppedGeneration(assistantMessageId: assistantMessageId)
                    return
                }

                let chatError = ChatError.fromError(error)

                if var currentChat = self.currentChat {
                    if let lastIndex = currentChat.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                        assembler.failToolCalls(error.localizedDescription)
                        assembler.finalize()
                        let existingModel = currentChat.messages[lastIndex].model ?? currentChat.model
                        currentChat.messages[lastIndex] = ChatMessage(
                            content: chatError.description,
                            isUser: false,
                            error: chatError,
                            toolCalls: assembler.toolCalls,
                            reasoningContent: assembler.reasoningContent,
                            reasoningDuration: assembler.reasoningDuration,
                            reasoningTokenCount: assembler.reasoningTokenCount,
                            transcriptBlocks: assembler.blocks,
                            model: existingModel
                        )
                        self.currentChat = currentChat
                    }
                }
                self.isLoading = false
                self.generationPhase = .idle
                self.generationTask = nil
                self.refreshContextUsage()
                self.saveChats()
            }
        }
    }

    private func initialGenerationPhase(for model: LLMModelChoice) -> ChatGenerationPhase {
        #if AFM_MLX
        if case .mlx(let id) = model, !MLXRuntime.shared.isWarmed(id) {
            return .loadingModel(name: model.displayName, fraction: nil)
        }
        #endif
        return .generating(name: model.displayName)
    }

    private func releaseSessions(keepingMLX keepID: String?) {
        for chatId in Array(sessions.keys) {
            guard case .mlx(let id) = getChatById(chatId)?.model, id != keepID else { continue }
            sessions.removeValue(forKey: chatId)
        }
    }

    private func prepareThenRespond(
        prompt: LLMPrompt,
        chat: Chat,
        assistantMessageId: UUID,
        epoch: UInt64
    ) async {
        do {
            try await prepareModelIfNeeded(chat.model)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                await MainActor.run {
                    guard self.isCurrentGeneration(epoch) else { return }
                    self.finishStoppedGeneration(assistantMessageId: assistantMessageId)
                }
                return
            }
            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                let chatError = ChatError.fromError(error)
                if var currentChat = self.currentChat,
                   let lastIndex = currentChat.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    let existingModel = currentChat.messages[lastIndex].model ?? currentChat.model
                    currentChat.messages[lastIndex] = ChatMessage(
                        content: chatError.description,
                        isUser: false,
                        error: chatError,
                        model: existingModel
                    )
                    self.currentChat = currentChat
                }
                self.isLoading = false
                self.generationPhase = .idle
                self.generationTask = nil
                self.saveChats()
            }
            return
        }

        await MainActor.run {
            guard self.isCurrentGeneration(epoch) else { return }
            self.generationPhase = .generating(name: chat.model.displayName)
        }
        let capabilities = AttachmentMediaSupport.capabilities(for: chat.model)
        let includeFileNames = chat.model.mlxModelID != nil
        let historyAttachments = chat.messages
            .filter(\.isUser)
            .flatMap(\.attachments)
            .map { $0.toLLMAttachment() }
        await AttachmentMediaSupport.ensureTranscripts(
            attachments: prompt.attachments + historyAttachments,
            capabilities: capabilities
        )
        if Task.isCancelled {
            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                self.finishStoppedGeneration(assistantMessageId: assistantMessageId)
            }
            return
        }
        let preparedPrompt = AttachmentMediaSupport.preparePrompt(
            prompt,
            capabilities: capabilities,
            includeFileNames: includeFileNames
        )
        if let chatId = currentChatId {
            let upToMessage = chat.messages.last(where: \.isUser)?.id
            let outgoingAttachments = chat.messages.last(where: \.isUser)?.attachments ?? []
            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                let newSession = self.createSessionForChat(
                    chatId: chatId,
                    upToMessage: upToMessage,
                    additionalFileAttachments: outgoingAttachments
                )
                self.sessions[chatId] = newSession
            }
        }
        guard isCurrentGeneration(epoch), !Task.isCancelled else {
            await MainActor.run {
                guard self.isCurrentGeneration(epoch) else { return }
                self.finishStoppedGeneration(assistantMessageId: assistantMessageId)
            }
            return
        }
        await processLLMResponse(
            prompt: preparedPrompt,
            chat: chat,
            assistantMessageId: assistantMessageId,
            epoch: epoch
        )
    }

    /// Loads GPU weights only for an in-flight send. Browsing other chats or
    /// switching models leaves the last resident model in memory until then.
    private func prepareModelIfNeeded(_ model: LLMModelChoice) async throws {
        #if AFM_MLX
        let keepID = model.mlxModelID
        let pipelineTag = keepID.flatMap { DownloadedModelStore.pipelineTag(for: $0) }
        releaseSessions(keepingMLX: keepID)
        try await MLXRuntime.shared.activate(
            id: keepID,
            pipelineTag: pipelineTag,
            displayName: model.displayName,
            onPhase: { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.isLoading else { return }
                    self.generationPhase = phase
                }
            }
        )
        #endif
    }

    private func publishAssembledMessage(_ assembler: AssistantTranscriptAssembler, id: UUID) {
        updateInFlightAssistantMessage(
            id: id,
            content: assembler.content,
            toolCalls: assembler.toolCalls,
            reasoningContent: assembler.reasoningContent,
            reasoningDuration: assembler.reasoningDuration,
            reasoningTokenCount: assembler.reasoningTokenCount,
            transcriptBlocks: assembler.blocks
        )
    }

    private func resolvedToolCalls(_ calls: [LLMToolCallEvent], existing: [ToolCallInfo]) -> [ToolCallInfo] {
        calls.map { call in
            let match = existing.first { candidate in
                if candidate.transcriptID == call.transcriptID {
                    return true
                }
                guard candidate.toolName == call.toolName else { return false }
                if candidate.arguments == call.arguments {
                    return true
                }
                let candidateIsActive = candidate.status == .executing || candidate.status == .pending
                return candidateIsActive && call.result == nil && call.error == nil
            }
            if let match {
                return match.updated(
                    from: call,
                    toolDescription: getToolDescription(for: call.toolName)
                )
            }
            let status: ToolCallStatus
            switch call.status {
            case .pending: status = .pending
            case .executing: status = .executing
            case .completed: status = .completed
            case .failed: status = .failed
            }
            return ToolCallInfo(
                toolName: call.toolName,
                toolDescription: getToolDescription(for: call.toolName),
                arguments: call.arguments,
                status: status,
                result: call.result,
                error: call.error,
                transcriptID: call.transcriptID
            )
        }
    }

    private func updateInFlightAssistantMessage(
        id: UUID,
        content: String,
        toolCalls: [ToolCallInfo],
        reasoningContent: String?,
        reasoningDuration: TimeInterval? = nil,
        reasoningTokenCount: Int? = nil,
        transcriptBlocks: [ChatTranscriptBlock] = []
    ) {
        guard var chat = currentChat else { return }
        guard let lastIndex = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        chat.messages[lastIndex] = chat.messages[lastIndex].updatedForStreaming(
            content: content,
            toolCalls: toolCalls,
            reasoningContent: reasoningContent,
            reasoningDuration: reasoningDuration,
            reasoningTokenCount: reasoningTokenCount,
            transcriptBlocks: transcriptBlocks
        )
        updateStoredChat(chat)
    }

    private func isUserToolEnabled(_ id: AppToolID, in chat: Chat?) -> Bool {
        guard id.isAvailable else { return false }
        switch id {
        case .codeInterpreter:
            return chat?.toolCodeInterpreterEnabled ?? true
        case .webSearch:
            return chat?.toolWebSearchEnabled ?? true
        case .webFetch:
            return chat?.toolWebFetchEnabled ?? true
        case .readAttachment:
            return true
        }
    }

    private func getToolDescription(for toolName: String) -> String {
        AppToolCatalog.resolve(toolName)?.description ?? "Execute tool: \(toolName)"
    }

    private func updateGenerationPhaseForToolCalls(_ toolCalls: [ToolCallInfo], modelName: String) {
        if let running = toolCalls.last(where: { $0.status == .pending || $0.status == .executing }) {
            generationPhase = .runningTool(name: running.toolName)
        } else if isLoading, case .runningTool = generationPhase {
            generationPhase = .generating(name: modelName)
        }
    }
    
    
}

@MainActor
private final class AssistantTranscriptAssembler {
    private(set) var blocks: [ChatTranscriptBlock] = []
    private(set) var toolCalls: [ToolCallInfo] = []
    var reasoningTokenCount: Int?

    private var previousReasoning = ""
    private var previousText = ""
    private var committedTextPrefix = ""
    private var reasoningStartDate: Date?
    private var reasoningEntryCount = 0

    var content: String {
        textContents.joined(separator: "\n\n")
    }

    var reasoningContent: String? {
        let parts = blocks.compactMap { block -> String? in
            guard case .reasoning(_, let content, _) = block else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : content
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    var reasoningDuration: TimeInterval? {
        let durations = blocks.compactMap { block -> TimeInterval? in
            guard case .reasoning(_, _, let duration) = block else { return nil }
            return duration
        }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +)
    }

    func startPlaceholderThinking() {
        if isReasoningClockRunning {
            refreshOpenReasoningDuration()
            return
        }
        if case .reasoning(_, let content, _) = blocks.last,
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasoningStartDate = Date()
            refreshOpenReasoningDuration()
            return
        }
        blocks.append(.reasoning(id: UUID(), content: "", duration: 0))
        reasoningStartDate = Date()
        refreshOpenReasoningDuration()
    }

    func applyReasoning(_ full: String?, tokenCount: Int? = nil, entryCount: Int? = nil) {
        if let entryCount, entryCount > reasoningEntryCount {
            reasoningEntryCount = entryCount
            startPlaceholderThinking()
        }
        if let tokenCount {
            let grew = tokenCount > (reasoningTokenCount ?? 0)
            reasoningTokenCount = tokenCount
            if grew {
                startReasoningClockFromTokenGrowthIfNeeded()
            }
        }

        let raw = full ?? ""
        let usable = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { previousReasoning = raw }

        guard !usable.isEmpty else {
            refreshOpenReasoningDuration()
            return
        }

        let delta: String
        if raw.hasPrefix(previousReasoning) {
            delta = String(raw.dropFirst(previousReasoning.count))
        } else {
            delta = usable
        }
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)

        if case .reasoning(let id, let content, let duration) = blocks.last {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, trimmedDelta.isEmpty {
                refreshOpenReasoningDuration()
                return
            }
            let nextContent = mergedReasoning(existing: content, delta: delta, usable: usable)
            blocks[blocks.count - 1] = .reasoning(id: id, content: nextContent, duration: duration)
            if reasoningStartDate == nil {
                reasoningStartDate = Date()
            }
        } else {
            closeTextIfNeeded()
            let nextContent: String
            if raw.hasPrefix(previousReasoning) {
                nextContent = trimmedDelta
            } else if let stored = reasoningContent, usable.hasPrefix(stored), !stored.isEmpty {
                nextContent = String(usable.dropFirst(stored.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                nextContent = usable
            }
            guard !nextContent.isEmpty else {
                refreshOpenReasoningDuration()
                return
            }
            blocks.append(.reasoning(id: UUID(), content: nextContent, duration: 0))
            reasoningStartDate = Date()
        }
        refreshOpenReasoningDuration()
    }

    func applyContent(_ fullText: String) {
        let usable = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { previousText = fullText }
        guard !usable.isEmpty else { return }
        if isStaleContentSnapshot(fullText) {
            return
        }

        closeReasoningIfNeeded()

        if case .text(let id, let current) = blocks.last {
            if fullText.hasPrefix(committedTextPrefix) {
                let remainder = strippedLeadingSeparators(String(fullText.dropFirst(committedTextPrefix.count)))
                blocks[blocks.count - 1] = .text(id: id, content: remainder.isEmpty ? current : remainder)
            } else if fullText.hasPrefix(current) || current.hasPrefix(fullText) {
                blocks[blocks.count - 1] = .text(id: id, content: fullText)
            } else {
                blocks.append(.text(id: UUID(), content: usable))
            }
        } else if fullText.hasPrefix(committedTextPrefix), !committedTextPrefix.isEmpty {
            let remainder = strippedLeadingSeparators(String(fullText.dropFirst(committedTextPrefix.count)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { return }
            blocks.append(.text(id: UUID(), content: remainder))
        } else {
            blocks.append(.text(id: UUID(), content: fullText))
        }
    }

    func applyToolCalls(_ calls: [ToolCallInfo]) {
        toolCalls = calls
        var seen = Set(blocks.compactMap { block -> UUID? in
            guard case .tool(let id) = block else { return nil }
            return id
        })
        for call in calls {
            guard !seen.contains(call.id) else { continue }
            closeReasoningIfNeeded()
            closeTextIfNeeded()
            blocks.append(.tool(id: call.id))
            seen.insert(call.id)
        }
        refreshOpenReasoningDuration()
    }

    func failToolCalls(_ error: String) {
        for index in toolCalls.indices {
            toolCalls[index].status = .failed
            toolCalls[index].error = error
        }
    }

    func finalize() {
        closeReasoningIfNeeded()
        refreshOpenReasoningDuration()
    }

    func refreshOpenReasoningDuration() {
        guard let reasoningStartDate, case .reasoning(let id, let content, _) = blocks.last else { return }
        let duration = Date().timeIntervalSince(reasoningStartDate)
        blocks[blocks.count - 1] = .reasoning(id: id, content: content, duration: duration)
    }

    private var textContents: [String] {
        blocks.compactMap { block in
            guard case .text(_, let content) = block else { return nil }
            return content
        }
    }

    private var isReasoningClockRunning: Bool {
        guard reasoningStartDate != nil else { return false }
        if case .reasoning = blocks.last { return true }
        return false
    }

    private func startReasoningClockFromTokenGrowthIfNeeded() {
        switch blocks.last {
        case .none, .tool:
            startPlaceholderThinking()
        case .reasoning:
            if reasoningStartDate == nil {
                startPlaceholderThinking()
            }
        case .text:
            break
        }
    }

    private func isStaleContentSnapshot(_ fullText: String) -> Bool {
        if fullText == previousText {
            return true
        }
        guard !committedTextPrefix.isEmpty, fullText.hasPrefix(committedTextPrefix) else {
            return false
        }
        let remainder = strippedLeadingSeparators(String(fullText.dropFirst(committedTextPrefix.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty
    }

    private func closeReasoningIfNeeded() {
        guard let start = reasoningStartDate else { return }
        if case .reasoning(let id, let content, _) = blocks.last {
            blocks[blocks.count - 1] = .reasoning(
                id: id,
                content: content,
                duration: Date().timeIntervalSince(start)
            )
        }
        reasoningStartDate = nil
    }

    private func closeTextIfNeeded() {
        if case .text = blocks.last {
            committedTextPrefix = previousText
        }
    }

    private func mergedReasoning(existing: String, delta: String, usable: String) -> String {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            return trimmedDelta.isEmpty ? usable : trimmedDelta
        }
        if trimmedDelta.isEmpty {
            return existing
        }
        if delta.hasPrefix("\n\n") {
            return existing + "\n\n" + trimmedDelta
        }
        if usable.hasPrefix(existing) {
            return usable
        }
        return existing + delta
    }

    private func strippedLeadingSeparators(_ text: String) -> String {
        String(text.drop(while: { $0.isNewline }))
    }
}

