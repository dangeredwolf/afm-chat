//
//  ChatBubble.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import MarkdownUI

struct ReasoningView: View {
    let reasoningDuration: TimeInterval?
    let isStreaming: Bool
    let isThinkingActive: Bool
    @State private var thinkingStartDate: Date?

    private func formatThinkingDuration(_ seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m \(remainingSeconds)s"
    }

    private func elapsedDuration(at date: Date) -> TimeInterval? {
        guard let thinkingStartDate else { return reasoningDuration }
        return date.timeIntervalSince(thinkingStartDate)
    }

    private func durationLabel(at date: Date) -> String? {
        let elapsed: TimeInterval?
        if isThinkingActive {
            elapsed = elapsedDuration(at: date)
        } else {
            elapsed = reasoningDuration
        }
        guard let elapsed, elapsed >= 0, elapsed > 0 || isThinkingActive else { return nil }
        return formatThinkingDuration(elapsed)
    }

    var body: some View {
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

            Group {
                if isThinkingActive {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        reasoningHeader(durationLabel: durationLabel(at: context.date))
                    }
                } else {
                    reasoningHeader(durationLabel: durationLabel(at: .now))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            syncThinkingStartDate()
        }
        .onChange(of: isThinkingActive) { _, _ in
            syncThinkingStartDate()
        }
        .onChange(of: reasoningDuration) { _, _ in
            syncThinkingStartDate()
        }
    }

    @ViewBuilder
    private func reasoningHeader(durationLabel: String?) -> some View {
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

            if let durationLabel {
                Text("(\(durationLabel))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func syncThinkingStartDate() {
        if isThinkingActive {
            thinkingStartDate = Date().addingTimeInterval(-(reasoningDuration ?? 0))
        } else {
            thinkingStartDate = nil
        }
    }
}

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded: Bool = false
    @State private var rotationAngle: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 6) {
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

    init(
        message: ChatMessage,
        isStreaming: Bool = false,
        onEdit: ((UUID) -> Void)? = nil,
        onCopy: ((UUID) -> Void)? = nil,
        onRetry: ((UUID) -> Void)? = nil
    ) {
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
            Markdown(message.content)
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

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if !message.isUser {
                    if message.hasReasoningContent {
                        ReasoningView(
                            reasoningDuration: message.reasoningDuration,
                            isStreaming: isStreaming,
                            isThinkingActive: isStreaming
                                && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
