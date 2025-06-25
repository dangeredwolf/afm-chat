//
//  ChatContainerView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import FoundationModels

struct ChatContainerView: View {
    @StateObject private var chatManager = ChatManager()
    @State private var selectedChatId: UUID?
    @State private var showingModelUnavailableAlert = false
    
    private var model = SystemLanguageModel.default
    
    var body: some View {
        NavigationStack {
            switch model.availability {
            case .available:
                ChatListView(chatManager: chatManager, selectedChatId: $selectedChatId)
            case .unavailable(.deviceNotEligible):
                ModelUnavailableView(
                    title: "Device Not Compatible",
                    message: "Your device doesn't support Apple Intelligence features. Apple Intelligence requires an A17 Pro, A18, or M1 chip or better.",
                    icon: "exclamationmark.triangle"
                )
            case .unavailable(.appleIntelligenceNotEnabled):
                ModelUnavailableView(
                    title: "Apple Intelligence Required",
                    message: "You need to enable Apple Intelligence in Settings. It might take a few minutes for your device to download the language model.",
                    icon: "brain.head.profile",
                    showSettingsButton: true
                )
            case .unavailable(.modelNotReady):
                ModelUnavailableView(
                    title: "Model Downloading",
                    message: "The Apple Intelligence language model is currently downloading in the background. Check its status in Settings.",
                    icon: "arrow.down.circle",
                    showSettingsButton: true
                )
            case .unavailable(let other):
                ModelUnavailableView(
                    title: "Model Unavailable",
                    message: "The Apple Intelligence language model is currently unavailable. Please try again later.\n\nError: \(other)",
                    icon: "exclamationmark.circle"
                )
            }
        }
    }
}

struct ModelUnavailableView: View {
    let title: String
    let message: String
    let icon: String
    let showSettingsButton: Bool
    
    init(title: String, message: String, icon: String, showSettingsButton: Bool = false) {
        self.title = title
        self.message = message
        self.icon = icon
        self.showSettingsButton = showSettingsButton
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
            
            if showSettingsButton {
                Button(action: openSettings) {
                    Text("Open Settings")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
        }
        .padding(.horizontal, 32)
        .navigationTitle("AFM Chat")
    }
    
    private func openSettings() {
        
        UIApplication.shared.open(URL(string:"App-prefs:SIRI")!)
    }
}

struct ChatListView: View {
    @ObservedObject var chatManager: ChatManager
    @Binding var selectedChatId: UUID?
    @State private var showingSettings: Bool = false
    
    var body: some View {
        List {
            // New Chat button at the top
            NavigationLink(destination: ChatDetailView(chatManager: chatManager, chatId: nil)) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title2)
                    Text("New Chat")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            
            if !chatManager.chats.isEmpty {
                Section(header: Text("Recent Chats")) {
                    ForEach(chatManager.chats) { chat in
                        NavigationLink(destination: ChatDetailView(chatManager: chatManager, chatId: chat.id, initialTitle: chat.title)) {
                            ChatRowView(
                                chat: chat,
                                isSelected: chat.id == chatManager.currentChatId,
                                onSelect: { }
                            )
                        }
                    }
                    .onDelete(perform: deleteChats)
                }
            }
        }
        .navigationTitle("AFM Chat")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            GlobalSettingsView(chatManager: chatManager)
        }
    }
    
    private func deleteChats(offsets: IndexSet) {
        for index in offsets {
            let chat = chatManager.chats[index]
            chatManager.deleteChat(chat.id)
        }
    }
}

struct ChatDetailView: View {
    @ObservedObject var chatManager: ChatManager
    let chatId: UUID?
    @State private var showingSettings: Bool = false
    @State private var chatTitle: String
    @Environment(\.dismiss) private var dismiss
    let initialTitle: String
    
    init(chatManager: ChatManager, chatId: UUID?, initialTitle: String = "New Chat") {
        self.chatManager = chatManager
        self.chatId = chatId
        self.initialTitle = initialTitle
        self._chatTitle = State(initialValue: initialTitle)
    }
    
    var body: some View {
        ChatView(chatManager: chatManager)
            .navigationBarBackButtonHidden(false)
            .navigationTitle(chatTitle)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    
                    Button(action: chatManager.clearCurrentChat) {
                        Image(systemName: "trash")
                    }
                    .disabled(chatManager.currentMessages.isEmpty)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    systemPrompt: Binding(
                        get: { chatManager.currentSystemPrompt },
                        set: { newPrompt in
                            chatManager.updateChatSettings(
                                systemPrompt: newPrompt,
                                temperature: chatManager.currentTemperature,
                                toolsEnabled: chatManager.currentToolsEnabled
                            )
                        }
                    ),
                    temperature: Binding(
                        get: { chatManager.currentTemperature },
                        set: { newTemperature in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: newTemperature,
                                toolsEnabled: chatManager.currentToolsEnabled
                            )
                        }
                    ),
                    toolsEnabled: Binding(
                        get: { chatManager.currentToolsEnabled },
                        set: { newToolsEnabled in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                toolsEnabled: newToolsEnabled
                            )
                        }
                    ),
                    onSave: { }
                )
            }
            .onAppear {
                if let chatId = chatId {
                    chatManager.switchToChat(chatId)
                } else {
                    // Create new chat if chatId is nil
                    let newChatId = chatManager.createNewChat()
                    chatManager.currentChatId = newChatId
                }
            }
            .onChange(of: chatManager.currentChat?.title) { newTitle in
                // Update title when chat title changes (e.g., after first message)
                if let newTitle = newTitle {
                    chatTitle = newTitle
                }
            }
    }
}

struct GlobalSettingsView: View {
    @ObservedObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss
    @State private var defaultPrompt: String = ""
    @State private var defaultTemperature: Double = 1.0
    @State private var defaultToolsEnabled: Bool = true
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Default Settings for New Chats")) {
                    Text("These settings will be used when creating new chats.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("System Prompt")
                        .font(.headline)
                    TextEditor(text: $defaultPrompt)
                        .frame(minHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Temperature: \(defaultTemperature, specifier: "%.1f")")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Slider(value: $defaultTemperature, in: 0.0...2.0, step: 0.1)
                    }
                }
                
                Section(header: Text("Tools")) {
                    Text("Set the default tools behavior for new chats. This controls whether new chats will have access to tools like code execution and information lookup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Toggle("Enable Tools by Default", isOn: $defaultToolsEnabled)
                        .toggleStyle(SwitchToggleStyle())
                    
                    if defaultToolsEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available Tools:")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Image(systemName: "gear")
                                    .foregroundColor(.blue)
                                Text("Code Interpreter")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
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
                        UserDefaults.standard.set(defaultPrompt, forKey: "systemPrompt")
                        UserDefaults.standard.set(defaultTemperature, forKey: "temperature")
                        UserDefaults.standard.set(defaultToolsEnabled, forKey: "toolsEnabled")
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            defaultPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
            defaultTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 1.0
            defaultToolsEnabled = UserDefaults.standard.object(forKey: "toolsEnabled") as? Bool ?? true
        }
    }
}

struct ChatRowView: View {
    let chat: Chat
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chat.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Spacer()
                Text(chat.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let lastMessage = chat.messages.last {
                Text(lastMessage.content)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            } else {
                Text("No messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            
        }
        .padding(.vertical, 4)
    }
} 
