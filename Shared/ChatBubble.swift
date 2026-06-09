//
//  ChatBubble.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import MarkdownUI

struct ReasoningView: View {
    let reasoningContent: String?
    let reasoningTokenCount: Int?
    let isStreaming: Bool
    @State private var isExpanded = false

    private var tokenLabel: String? {
        guard let reasoningTokenCount, reasoningTokenCount > 0 else { return nil }
        return "\(reasoningTokenCount) tokens"
    }

    private var bodyText: String? {
        if let reasoningContent,
           !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reasoningContent
        }
        if isStreaming, tokenLabel != nil {
            return "Thinking…"
        }
        if tokenLabel != nil {
            return ""
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    if isStreaming {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(.purple)
                            .frame(width: 16, height: 16)
                    }

                    HStack(spacing: 4) {
                        Text("Thinking")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        if isStreaming {
                            Text("...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let tokenLabel {
                            Text("(\(tokenLabel))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if let reasoningContent {
                            Text("(\(reasoningContent.count) chars)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded, let bodyText {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)

                    ScrollView {
                        Text(bodyText)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            if isStreaming {
                isExpanded = true
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            }
        }
    }
}

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded: Bool = false
    @State private var rotationAngle: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main tool call header (always visible)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    // Status icon with loading animation
                    Group {
                        if toolCall.status == .executing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: toolCall.status.systemIcon)
                                .foregroundColor(colorForStatus(toolCall.status))
                                .frame(width: 16, height: 16)
                        }
                    }
                    
                    // Tool usage text
                    HStack(spacing: 4) {
                        Text("Using")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(displayNameForTool(toolCall.toolName))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        if toolCall.status == .executing {
                            Text("...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .opacity(0.7)
                        }
                    }
                    
                    Spacer()
                    
                    
                    // Expand/collapse arrow
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(PlainButtonStyle())
            
            // Expandable details section
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        // Tool description
                        HStack {
                            Text("Description:")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Text(toolCall.toolDescription)
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Arguments section
                        if !toolCall.arguments.isEmpty {
                            HStack {
                                Text("Arguments:")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.top, 4)
                            
                            Text(formatArguments(toolCall.arguments))
                                .font(.caption2)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        // Result section (if completed)
                        if toolCall.status == .completed, let result = toolCall.result, !result.isEmpty {
                            HStack {
                                Text("Result:")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.top, 4)
                            
                            Text(result)
                                .font(.caption2)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        // Error section (if failed)
                        if toolCall.status == .failed, let error = toolCall.error {
                            HStack {
                                Text("Error:")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding(.top, 4)
                            
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(backgroundColorForStatus(toolCall.status))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(colorForStatus(toolCall.status).opacity(0.3), lineWidth: 1)
        )
    }
    
    private func colorForStatus(_ status: ToolCallStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .executing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private func backgroundColorForStatus(_ status: ToolCallStatus) -> Color {
        switch status {
        case .pending: return .orange.opacity(0.05)
        case .executing: return .blue.opacity(0.05)
        case .completed: return .green.opacity(0.05)
        case .failed: return .red.opacity(0.05)
        }
    }
    
    private func displayNameForTool(_ toolName: String) -> String {
        switch toolName.lowercased() {
        case "websearch": return "Web Search"
        case "calculator": return "Calculator"
        default: return toolName.capitalized
        }
    }
    
    private func formatArguments(_ arguments: String) -> String {
        // Try to format JSON arguments nicely, fallback to raw string
        if let data = arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let formattedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let formattedString = String(data: formattedData, encoding: .utf8) {
            return formattedString
        }
        return arguments
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onEdit: ((UUID) -> Void)?
    let onCopy: ((UUID) -> Void)?
    let onRetry: ((UUID) -> Void)?

    init(message: ChatMessage, isStreaming: Bool = false, onEdit: ((UUID) -> Void)? = nil, onCopy: ((UUID) -> Void)? = nil, onRetry: ((UUID) -> Void)? = nil) {
        self.message = message
        self.isStreaming = isStreaming
        self.onEdit = onEdit
        self.onCopy = onCopy
        self.onRetry = onRetry
    }
    
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    private var hasBubbleContent: Bool {
        message.isUser
            || message.isError
            || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isUser {
            Text(message.content)
        } else if message.isError, let error = message.error {
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
            let contentParts = message.content.components(separatedBy: "\n\n")
            ForEach(Array(contentParts.enumerated()), id: \.offset) { _, part in
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Markdown(part)
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
        }
    }

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if !message.isUser {
                    if message.hasReasoningContent {
                        ReasoningView(
                            reasoningContent: message.reasoningContent,
                            reasoningTokenCount: message.reasoningTokenCount,
                            isStreaming: isStreaming
                        )
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    }

                    if message.hasToolCalls {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.toolCalls) { toolCall in
                                ToolCallView(toolCall: toolCall)
                            }
                        }
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    }
                }

                if hasBubbleContent {
                    bubbleContent
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
                        .frame(maxWidth: maxBubbleWidth, alignment: message.isUser ? .trailing : .leading)
                        .contextMenu {
                            Button(action: {
                                onCopy?(message.id)
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
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
