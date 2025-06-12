//
//  ChatContainerView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct ChatContainerView: View {
    @StateObject private var chatManager = ChatManager()
    @State private var selectedChatId: UUID?
    
    var body: some View {
        NavigationStack {
            ChatListView(chatManager: chatManager, selectedChatId: $selectedChatId)
        }
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
                                temperature: chatManager.currentTemperature
                            )
                        }
                    ),
                    temperature: Binding(
                        get: { chatManager.currentTemperature },
                        set: { newTemperature in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: newTemperature
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
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            defaultPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
            defaultTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 1.0
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
