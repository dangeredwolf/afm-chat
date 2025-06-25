//
//  ChatBubble.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import MarkdownUI

struct ChatBubble: View {
    let message: ChatMessage
    let onEdit: ((UUID) -> Void)?
    let onCopy: ((UUID) -> Void)?
    let onRetry: ((UUID) -> Void)?
    
    init(message: ChatMessage, onEdit: ((UUID) -> Void)? = nil, onCopy: ((UUID) -> Void)? = nil, onRetry: ((UUID) -> Void)? = nil) {
        self.message = message
        self.onEdit = onEdit
        self.onCopy = onCopy
        self.onRetry = onRetry
    }
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if message.isUser {
                        // User messages: plain text
                        Text(message.content)
                    } else if message.isError, let error = message.error {
                        // Error messages: special error UI
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: error.systemIcon)
                                    .foregroundColor(.red)
                                Text(error.title)
                                    .font(.headline)
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            
                            Text(error.description)
                                .font(.body)
                                .foregroundColor(.primary)
                            
                            // Retry button for recoverable errors
                            if error.isRecoverable {
                                HStack {
                                    Button(action: {
                                        onRetry?(message.id)
                                    }) {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Try Again")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    } else {
                        // AI messages: rendered markdown
                        Markdown(message.content)
//                            .markdownTheme(.gitHub)
                            .markdownTextStyle(\.text) {
                                ForegroundColor(.primary)
                            }
                            .markdownTextStyle(\.code) {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                                ForegroundColor(.primary)
                                BackgroundColor(.primary.opacity(0.1))
                            }
                    }
                }
                .padding(12)
                .background(
                    message.isUser ? Color.indigo :
                    message.isError ? Color.red.opacity(0.1) :
                    Color.gray.opacity(0.2)
                )
                .foregroundColor(
                    message.isUser ? .white :
                    message.isError ? .primary :
                    .primary
                )
                .cornerRadius(16)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.isUser ? .trailing : .leading)
                .contextMenu {
                    if message.isUser {
                        Button(action: {
                            onEdit?(message.id)
                        }) {
                            Label("Edit Message", systemImage: "pencil")
                        }
                    } else if message.isError {
                        Button(action: {
                            onRetry?(message.id)
                        }) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        Button(action: {
                            onCopy?(message.id)
                        }) {
                            Label("Copy Error", systemImage: "doc.on.doc")
                        }
                    } else {
                        Button(action: {
                            onCopy?(message.id)
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
                
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
