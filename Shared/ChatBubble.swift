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
    
    init(message: ChatMessage, onEdit: ((UUID) -> Void)? = nil, onCopy: ((UUID) -> Void)? = nil) {
        self.message = message
        self.onEdit = onEdit
        self.onCopy = onCopy
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
                .background(message.isUser ? Color.indigo : Color.gray.opacity(0.2))
                .foregroundColor(message.isUser ? .white : .primary)
                .cornerRadius(16)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.isUser ? .trailing : .leading)
                .contextMenu {
                    if message.isUser {
                        Button(action: {
                            onEdit?(message.id)
                        }) {
                            Label("Edit Message", systemImage: "pencil")
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
