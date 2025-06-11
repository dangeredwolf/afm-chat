//
//  ChatModels.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
} 