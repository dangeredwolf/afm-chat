//
//  ChatSearch.swift
//  Shared
//

import Foundation

private let snippetMaxLength = 120

func chatsMatching(_ chats: [Chat], query: String) -> [Chat] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return chats }
    return chats.filter { chat in
        chat.title.localizedCaseInsensitiveContains(trimmed)
            || chat.messages.contains { $0.content.localizedCaseInsensitiveContains(trimmed) }
    }
}

func searchResultSections(from chats: [Chat], query: String) -> [(title: String, chats: [Chat])] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return groupedChats(chats)
    }
    let matches = chatsMatching(chats, query: trimmed)
        .sorted { $0.lastActivityDate > $1.lastActivityDate }
    return matches.isEmpty ? [] : [("All Results", matches)]
}

extension Chat {
    func matchingSnippet(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return lastMessagePreview
        }

        if title.localizedCaseInsensitiveContains(trimmed) {
            if let preview = lastMessagePreview {
                return preview
            }
            return title
        }

        if let matchingMessage = messages.first(where: {
            $0.content.localizedCaseInsensitiveContains(trimmed)
        }) {
            return Self.truncatedSnippet(from: matchingMessage.content)
        }

        return lastMessagePreview
    }

    private var lastMessagePreview: String? {
        if let lastMessage = messages.last, !lastMessage.content.isEmpty {
            return Self.truncatedSnippet(from: lastMessage.content)
        }
        return nil
    }

    private static func truncatedSnippet(from text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > snippetMaxLength else { return collapsed }
        return String(collapsed.prefix(snippetMaxLength)) + "..."
    }
}
