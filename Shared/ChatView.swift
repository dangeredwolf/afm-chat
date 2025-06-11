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
                        ForEach(chatManager.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatManager.messages.count) { _ in
                    // Auto-scroll to bottom when new messages are added
                    if let lastMessage = chatManager.messages.last {
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
                TextField("Type your message...", text: $chatManager.inputText, axis: .vertical)
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
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(chatManager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatManager.isLoading)
            }
            .padding()
        }
        .navigationTitle("AFM Chat")
    }
    

} 