//
//  ChatView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import FoundationModels

struct ChatView: View {
    @StateObject var chatManager: ChatManager
    @FocusState private var isInputFocused: Bool
    
    init(chatManager: ChatManager = ChatManager()) {
        _chatManager = StateObject(wrappedValue: chatManager)
    }
    
    var body: some View {
        VStack {
            // Chat messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatManager.currentMessages.isEmpty {
                            // Welcome message for new chats
                            VStack(spacing: 16) {
                                // Image(systemName: "message.circle")
                                //     .font(.system(size: 60))
                                //     .foregroundColor(.secondary.opacity(0.6))
                                
                                Text("Start a New Conversation")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                // Show current chat settings
                                VStack(spacing: 8) {
                                    Text("Chat Settings")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Temperature: \(chatManager.currentTemperature, specifier: "%.1f")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(12)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                        } else {
                            ForEach(chatManager.currentMessages) { message in
                                ChatBubble(
                                    message: message,
                                    onEdit: { messageId in
                                        chatManager.editMessage(messageId)
                                        isInputFocused = true
                                    },
                                    onCopy: { messageId in
                                        chatManager.copyMessage(messageId)
                                    },
                                    onRetry: { messageId in
                                        chatManager.retryMessage(messageId)
                                    }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: chatManager.currentMessages.count) { _ in
                    // Auto-scroll to bottom when new messages are added
                    if let lastMessage = chatManager.currentMessages.last {
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
            
            // Editing indicator
            if chatManager.editingMessageId != nil {
                HStack {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundColor(.orange)
                    Text("Editing message...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") {
                        chatManager.cancelEditing()
                        isInputFocused = false
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .background(Color.orange.opacity(0.05))
            }
            
            // Input area
            HStack {
                TextField(
                    chatManager.editingMessageId != nil ? "Edit your message..." : "Type your message...",
                    text: $chatManager.inputText,
                    axis: .vertical
                )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(1...4)
                    .disabled(chatManager.isLoading)
                    .focused($isInputFocused)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .onSubmit {
                        chatManager.sendMessage()
                        isInputFocused = false
                    }
                
                Button(action: {
                    chatManager.sendMessage()
                    isInputFocused = false
                }) {
                    if chatManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: chatManager.editingMessageId != nil ? "checkmark" : "paperplane.fill")
                    }
                }
                .disabled(chatManager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatManager.isLoading)
            }
            .padding()
        }
    }
} 
