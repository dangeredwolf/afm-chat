//
//  ChatBubble.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import MarkdownUI

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
        case "getweather": return "Weather"
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
                        // AI messages: rendered markdown with inline tool calls
                        VStack(alignment: .leading, spacing: 8) {
                            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Split content into paragraphs and try to place tool calls inline
                                let contentParts = message.content.components(separatedBy: "\n\n")
                                let toolCallsToDistribute = message.toolCalls
                                
                                // Pre-calculate which tool calls go where to avoid duplicates
                                let toolCallPlacements = calculateToolCallPlacements(
                                    contentParts: contentParts,
                                    toolCalls: toolCallsToDistribute
                                )
                                
                                ForEach(Array(contentParts.enumerated()), id: \.offset) { index, part in
                                    // Show content part
                                    if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Markdown(part)
//                                            .markdownTheme(.gitHub)
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
                                    
                                    // Show tool calls assigned to this section
                                    if let toolCallsForSection = toolCallPlacements[index], !toolCallsForSection.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(toolCallsForSection) { toolCall in
                                                ToolCallView(toolCall: toolCall)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            } else if message.hasToolCalls {
                                // If no content, just show tool calls
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(message.toolCalls) { toolCall in
                                        ToolCallView(toolCall: toolCall)
                                    }
                                }
                            }
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
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !message.isUser {
                Spacer()
            }
        }
    }
    
    // Distribute tool calls across content sections based on content cues
    private func getToolCallsForSection(
        sectionIndex: Int,
        totalSections: Int,
        allToolCalls: [ToolCallInfo],
        sectionContent: String
    ) -> [ToolCallInfo] {
        guard !allToolCalls.isEmpty else { return [] }
        
        // Debug: print section info (only for non-empty sections)
        if !sectionContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("Section \(sectionIndex): '\(sectionContent.prefix(50))...'")
        }
        
        // Smart strategy: place tool calls based on content cues
        // Skip empty sections
        guard !sectionContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        
        // Very simple approach: place tool calls in the middle sections
        // Avoid first and last sections, distribute evenly in between
        if totalSections >= 3 && sectionIndex > 0 && sectionIndex < totalSections - 1 {
            // Calculate which tool call belongs to this middle section
            let middleSections = totalSections - 2 // Exclude first and last
            let toolCallIndex = ((sectionIndex - 1) * allToolCalls.count) / middleSections
            
            if toolCallIndex < allToolCalls.count && toolCallIndex >= 0 {
                print("Placing tool call \(toolCallIndex) after middle section \(sectionIndex)")
                return [allToolCalls[toolCallIndex]]
            }
        }
        
        // For short conversations (1-2 sections), place all tool calls after first section
        if totalSections <= 2 && sectionIndex == 0 {
            print("Placing all \(allToolCalls.count) tool calls after first section in short conversation")
            return allToolCalls
        }
        
        return []
    }
    
    // Pre-calculate tool call placements to avoid duplicates
    private func calculateToolCallPlacements(
        contentParts: [String],
        toolCalls: [ToolCallInfo]
    ) -> [Int: [ToolCallInfo]] {
        var placements: [Int: [ToolCallInfo]] = [:]
        var usedToolCalls: Set<UUID> = []
        
        // Go through each section and determine which tool calls should appear there
        for (index, part) in contentParts.enumerated() {
            let toolCallsForSection = getToolCallsForSection(
                sectionIndex: index,
                totalSections: contentParts.count,
                allToolCalls: toolCalls,
                sectionContent: part
            )
            
            // Filter out already used tool calls
            let newToolCalls = toolCallsForSection.filter { toolCall in
                !usedToolCalls.contains(toolCall.id)
            }
            
            if !newToolCalls.isEmpty {
                placements[index] = newToolCalls
                
                // Mark these as used
                for toolCall in newToolCalls {
                    usedToolCalls.insert(toolCall.id)
                }
            }
        }
        
        return placements
    }
} 
