//
//  ContentView.swift
//  afm-chat
//
//  Created by dangered wolf on 6/10/25.
//

import SwiftUI
import FoundationModels

struct ContentView: View {
    @State private var systemPrompt: String = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
    @State private var session: LanguageModelSession
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var showingSettings: Bool = false
    @FocusState private var isInputFocused: Bool
    
    init() {
        let savedPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
        _session = State(initialValue: LanguageModelSession(instructions: savedPrompt))
    }
    
    var body: some View {
        NavigationView {
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
            .navigationTitle("FM Chat")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    
                    Button(action: clearChat) {
                        Image(systemName: "trash")
                    }
                    .disabled(messages.isEmpty)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(systemPrompt: $systemPrompt, onSave: updateSession)
            }
        }
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
    
    private func clearChat() {
        // Clear messages
        messages.removeAll()
        
        // Create a new session to start fresh
        session = LanguageModelSession(instructions: systemPrompt)
        
        // Dismiss keyboard if it's visible
        isInputFocused = false
    }
    
    private func updateSession() {
        // Save to UserDefaults
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        
        // Create new session with updated prompt
        session = LanguageModelSession(instructions: systemPrompt)
    }
}

struct SettingsView: View {
    @Binding var systemPrompt: String
    @Environment(\.dismiss) private var dismiss
    @State private var tempPrompt: String = ""
    let onSave: () -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("System Prompt")) {
                    Text("Customize how the AI assistant behaves by modifying the system prompt below:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $tempPrompt)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        systemPrompt = tempPrompt
                        onSave()
                        dismiss()
                    }
                    .disabled(tempPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            tempPrompt = systemPrompt
        }
    }
}

struct PromptPresetButton: View {
    let title: String
    let prompt: String
    @Binding var tempPrompt: String
    
    var body: some View {
        Button(action: {
            tempPrompt = prompt
        }) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
}

struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(message.isUser ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .cornerRadius(16)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.isUser ? .trailing : .leading)
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !message.isUser {
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
}
