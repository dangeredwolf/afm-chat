//
//  ChatView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import FoundationModels

struct ChatView: View {
    @State private var systemPrompt: String = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
    @State private var session: LanguageModelSession
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @FocusState private var isInputFocused: Bool
    
    // Configuration options
    let showSettings: Bool
    let showClearButton: Bool
    let navigationTitle: String
    
    init(showSettings: Bool = true, showClearButton: Bool = true, navigationTitle: String = "AFM Chat") {
        self.showSettings = showSettings
        self.showClearButton = showClearButton
        self.navigationTitle = navigationTitle
        
        let savedPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
        _session = State(initialValue: LanguageModelSession(instructions: savedPrompt))
    }
    
    var body: some View {
        VStack {
            // Chat messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    // Auto-scroll to bottom when new messages are added
                    if let lastMessage = messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onTapGesture {
                    // Dismiss keyboard when tapping on chat area
                    isInputFocused = false
                }
            }
            
            // Input area
            HStack {
                TextField("Type your message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(1...4)
                    .disabled(isLoading)
                    .focused($isInputFocused)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            .padding()
        }
        .navigationTitle(navigationTitle)
    }
    
    private func sendMessage() {
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }
        
        // Add user message
        let userChatMessage = ChatMessage(content: userMessage, isUser: true)
        messages.append(userChatMessage)
        
        // Clear input, dismiss keyboard, and set loading state
        inputText = ""
        isInputFocused = false
        isLoading = true
        
        // Send to LLM
        Task {
            do {
                let response = try await session.respond(to: userMessage)
                
                await MainActor.run {
                    // Add AI response
                    let aiMessage = ChatMessage(content: response.content, isUser: false)
                    messages.append(aiMessage)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    // Add error message
                    let errorMessage = ChatMessage(content: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false)
                    messages.append(errorMessage)
                    isLoading = false
                }
            }
        }
    }
    
    func clearChat() {
        // Clear messages
        messages.removeAll()
        
        // Create a new session to start fresh
        session = LanguageModelSession(instructions: systemPrompt)
        
        // Dismiss keyboard if it's visible
        isInputFocused = false
    }
    
    func updateSession() {
        // Save to UserDefaults
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        
        // Create new session with updated prompt
        session = LanguageModelSession(instructions: systemPrompt)
    }
    
    // Bindings for external access
    var systemPromptBinding: Binding<String> {
        Binding(
            get: { systemPrompt },
            set: { newValue in
                systemPrompt = newValue
                updateSession()
            }
        )
    }
} 