//
//  ChatBubble.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import MarkdownUI
import UIKit

private struct DisclosureHeader: View, Equatable {
    let title: String
    var qualifier: String? = nil
    let isExpanded: Bool
    var showsChevron: Bool = true
    var isFailed: Bool = false
    var isInProgress: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if isInProgress {
                ProgressView()
                    .tint(isFailed ? Color.red.opacity(0.85) : Color.secondary)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.subheadline)
                .foregroundStyle(isFailed ? Color.red.opacity(0.85) : Color.secondary)

            if let qualifier, !qualifier.isEmpty {
                Text(qualifier)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

struct ReasoningView: View {
    let reasoningContent: String?
    let reasoningDuration: TimeInterval?
    let isThinkingActive: Bool
    let maxWidth: CGFloat
    @State private var isExpanded = false

    private var hasExpandableContent: Bool {
        guard let reasoningContent else { return false }
        return !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var headerTitle: String {
        isThinkingActive ? "Thinking" : "Thought"
    }

    private var headerQualifier: String? {
        guard !isThinkingActive, let duration = reasoningDuration, duration >= 0 else {
            return nil
        }
        if duration < 2 {
            return "briefly"
        }
        return "for \(formatThinkingDuration(duration))"
    }

    private var accessibilityTitle: String {
        if let qualifier = headerQualifier {
            return "\(headerTitle) \(qualifier)"
        }
        return headerTitle
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasExpandableContent else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                DisclosureHeader(
                    title: headerTitle,
                    qualifier: headerQualifier,
                    isExpanded: isExpanded,
                    showsChevron: hasExpandableContent,
                    isInProgress: isThinkingActive
                )
            }
            .buttonStyle(.plain)
            .disabled(!hasExpandableContent)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(isExpanded ? "Collapse thinking" : "Expand thinking")
            .accessibilityAddTraits(.isButton)

            if isExpanded, hasExpandableContent, let reasoningContent {
                Markdown(reasoningContent)
                    .markdownTextStyle(\.text) {
                        FontSize(.em(0.85))
                        ForegroundColor(.secondary)
                    }
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    let maxWidth: CGFloat
    @State private var isExpanded = false

    private var headerTitle: String {
        toolCallTitle(name: toolCall.toolName, status: toolCall.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                ToolCallHeaderView(
                    toolName: toolCall.toolName,
                    status: toolCall.status,
                    isExpanded: isExpanded
                )
                .equatable()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                ToolCallExpandedContent(toolCall: toolCall)
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

private func toolCallTitle(name: String, status: ToolCallStatus) -> String {
    let inProgress = status == .pending || status == .executing
    let failed = status == .failed

    switch AppToolCatalog.resolve(name)?.id {
    case .webSearch:
        if failed { return "Search failed" }
        return inProgress ? "Searching the web" : "Searched the web"
    case .webFetch:
        if failed { return "Couldn't read page" }
        return inProgress ? "Reading page" : "Read page"
    case .codeInterpreter:
        if failed { return "Code failed" }
        return inProgress ? "Running code" : "Ran code"
    case .readAttachment:
        if failed { return "Couldn't read file" }
        return inProgress ? "Reading file" : "Read file"
    case nil:
        if failed { return "\(name) failed" }
        return inProgress ? "Using \(name)" : "Used \(name)"
    }
}

private struct ToolCallHeaderView: View, Equatable {
    let toolName: String
    let status: ToolCallStatus
    let isExpanded: Bool

    var body: some View {
        DisclosureHeader(
            title: toolCallTitle(name: toolName, status: status),
            isExpanded: isExpanded,
            isFailed: status == .failed,
            isInProgress: status == .pending || status == .executing
        )
    }
}

private struct ToolCallExpandedContent: View {
    let toolCall: ToolCallInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !toolCall.arguments.isEmpty {
                Text(formatArguments(toolCall.arguments))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = toolCall.result, !result.isEmpty, toolCall.status != .failed {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if toolCall.status == .failed, let error = toolCall.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

private struct MessageFileAttachmentView: View {
    let attachment: ChatMessageAttachment
    var maxWidth: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            fileThumbnail
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(attachment.label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: maxWidth.map { max(0, $0 - 44) }, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var fileThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: fileSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileSymbolName: String {
        if attachment.isVideo {
            return "film"
        }
        if attachment.isAudio {
            return "waveform"
        }
        return "doc.fill"
    }
}

private struct MessageImageAttachmentView: View {
    let attachment: ChatMessageAttachment
    let maxWidth: CGFloat

    var body: some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: attachment.fileURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxWidth * 1.35)
            } else {
                MessageFileAttachmentView(attachment: attachment, maxWidth: maxWidth)
            }
        }
    }
}

private struct MessageImageAttachmentsView: View {
    let attachments: [ChatMessageAttachment]
    let alignment: HorizontalAlignment
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(attachments) { attachment in
                MessageImageAttachmentView(attachment: attachment, maxWidth: maxWidth)
            }
        }
    }
}

private struct MessageFileAttachmentsView: View {
    let attachments: [ChatMessageAttachment]
    let alignment: HorizontalAlignment
    let maxWidth: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 0) {
                    if alignment == .trailing {
                        Spacer(minLength: 0)
                    }
                    MessageFileAttachmentView(attachment: attachment, maxWidth: maxWidth)
                    if alignment == .leading {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: maxWidth, alignment: alignment == .trailing ? .trailing : .leading)
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    var generationPhase: ChatGenerationPhase = .idle
    let onEdit: ((UUID) -> Void)?
    let onCopy: ((UUID) -> Void)?
    let onRetry: ((UUID) -> Void)?

    init(
        message: ChatMessage,
        isStreaming: Bool = false,
        generationPhase: ChatGenerationPhase = .idle,
        onEdit: ((UUID) -> Void)? = nil,
        onCopy: ((UUID) -> Void)? = nil,
        onRetry: ((UUID) -> Void)? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.generationPhase = generationPhase
        self.onEdit = onEdit
        self.onCopy = onCopy
        self.onRetry = onRetry
    }

    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    private var trimmedContent: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTextContent: Bool {
        !trimmedContent.isEmpty
    }

    private var imageAttachments: [ChatMessageAttachment] {
        message.attachments.filter(\.isModelSupportedImage)
    }

    private var fileAttachments: [ChatMessageAttachment] {
        message.attachments.filter { !$0.isModelSupportedImage }
    }

    private var hasImageAttachments: Bool {
        !imageAttachments.isEmpty
    }

    private var hasFileAttachments: Bool {
        !fileAttachments.isEmpty
    }

    private var hasBubbleContent: Bool {
        message.isError || hasTextContent || hasImageAttachments
    }

    private var isImageOnlyUserMessage: Bool {
        message.isUser
            && hasImageAttachments
            && !hasTextContent
            && !hasFileAttachments
    }

    private var isUserMessageWithImageAndText: Bool {
        message.isUser && hasImageAttachments && hasTextContent
    }

    private var bubbleHorizontalAlignment: HorizontalAlignment {
        message.isUser ? .trailing : .leading
    }

    private var bubblePadding: EdgeInsets {
        if isImageOnlyUserMessage {
            return EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        }
        if isUserMessageWithImageAndText {
            return EdgeInsets()
        }
        return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isUser {
            userBubbleContent
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
        }
    }

    @ViewBuilder
    private var userBubbleContent: some View {
        if isUserMessageWithImageAndText {
            VStack(alignment: .trailing, spacing: 0) {
                MessageImageAttachmentsView(
                    attachments: imageAttachments,
                    alignment: .trailing,
                    maxWidth: maxBubbleWidth
                )

                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        } else {
            VStack(alignment: bubbleHorizontalAlignment, spacing: 6) {
                if hasImageAttachments {
                    MessageImageAttachmentsView(
                        attachments: imageAttachments,
                        alignment: bubbleHorizontalAlignment,
                        maxWidth: maxBubbleWidth - (isImageOnlyUserMessage ? 6 : 24)
                    )
                }

                if hasTextContent {
                    Text(message.content)
                }
            }
        }
    }

    @ViewBuilder
    private func assistantMarkdown(_ text: String) -> some View {
        Markdown(text)
            .markdownTextStyle(\.text) {
                ForegroundColor(.primary)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(.primary)
                UnderlineStyle(.single)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(.primary)
                BackgroundColor(.primary.opacity(0.1))
            }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isImageOnlyUserMessage {
            Color.clear
        } else if message.isUser {
            Color.indigo
        } else if message.isError {
            Color.red.opacity(0.1)
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private var firstTextBlockID: UUID? {
        message.displayBlocks.compactMap { block -> UUID? in
            guard case .text(let id, _) = block else { return nil }
            return id
        }.first
    }

    private var hasVisibleToolBlocks: Bool {
        message.displayBlocks.contains { block in
            guard case .tool(let id) = block else { return false }
            return message.toolCalls.contains { $0.id == id }
        }
    }

    private var isToolRunning: Bool {
        if message.hasActiveToolCalls { return true }
        if case .runningTool = generationPhase { return true }
        return false
    }

    @ViewBuilder
    private var assistantTranscript: some View {
        let blocks = message.displayBlocks
        let lastIndex = blocks.indices.last

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block {
                case .reasoning(_, let content, let duration):
                    ReasoningView(
                        reasoningContent: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content,
                        reasoningDuration: duration,
                        isThinkingActive: isStreaming
                            && index == lastIndex
                            && !isToolRunning,
                        maxWidth: maxBubbleWidth
                    )
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                case .tool(let id):
                    if let toolCall = message.toolCalls.first(where: { $0.id == id }) {
                        ToolCallView(toolCall: toolCall, maxWidth: maxBubbleWidth)
                            .id(toolCall.id)
                    }
                case .text(let id, let content):
                    VStack(alignment: .leading, spacing: 6) {
                        if id == firstTextBlockID, hasFileAttachments {
                            MessageFileAttachmentsView(
                                attachments: fileAttachments,
                                alignment: .leading,
                                maxWidth: maxBubbleWidth
                            )
                        }
                        styledBubble {
                            assistantTextBubbleContent(
                                text: content,
                                includeImages: id == firstTextBlockID
                            )
                        }
                    }
                }
            }

            if firstTextBlockID == nil {
                if hasFileAttachments {
                    MessageFileAttachmentsView(
                        attachments: fileAttachments,
                        alignment: .leading,
                        maxWidth: maxBubbleWidth
                    )
                }
                if message.isError {
                    styledBubble {
                        bubbleContent
                    }
                } else if hasImageAttachments {
                    styledBubble {
                        MessageImageAttachmentsView(
                            attachments: imageAttachments,
                            alignment: .leading,
                            maxWidth: maxBubbleWidth - 24
                        )
                    }
                } else if isStreaming && blocks.isEmpty {
                    StreamingStatusBubble(phase: generationPhase)
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                } else if isStreaming, case .runningTool = generationPhase, !hasVisibleToolBlocks {
                    StreamingStatusBubble(phase: generationPhase)
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                }
            } else if message.isError {
                styledBubble {
                    bubbleContent
                }
            }
        }
    }

    @ViewBuilder
    private func assistantTextBubbleContent(text: String, includeImages: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeImages, hasImageAttachments {
                MessageImageAttachmentsView(
                    attachments: imageAttachments,
                    alignment: .leading,
                    maxWidth: maxBubbleWidth - 24
                )
            }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantMarkdown(text)
            }
        }
    }

    @ViewBuilder
    private func styledBubble<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(bubblePadding)
            .background(bubbleBackground)
            .foregroundColor(
                message.isUser && !isImageOnlyUserMessage ? .white :
                message.isError ? .primary :
                .primary
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .compositingGroup()
            .shadow(
                color: isImageOnlyUserMessage ? Color.black.opacity(0.12) : .clear,
                radius: 4,
                y: 2
            )
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

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 0)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if message.isUser {
                    if hasFileAttachments {
                        MessageFileAttachmentsView(
                            attachments: fileAttachments,
                            alignment: .trailing,
                            maxWidth: maxBubbleWidth
                        )
                    }

                    if hasBubbleContent {
                        styledBubble {
                            bubbleContent
                        }
                    }
                } else {
                    assistantTranscript
                }
            }

            if !message.isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StreamingStatusBubble: View {
    let phase: ChatGenerationPhase

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.75)
                .frame(width: 16, height: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel(label)
    }

    private var label: String {
        switch phase {
        case .loadingModel(let name, let fraction):
            if let fraction, fraction > 0, fraction < 1 {
                return "Preparing \(name) \(Int((fraction * 100).rounded()))%"
            }
            return "Preparing \(name)…"
        case .compiling(let name), .generating(let name):
            return "Preparing \(name)…"
        case .runningTool(let name):
            return toolCallTitle(name: name, status: .executing)
        case .idle:
            return "Waiting…"
        }
    }
}
