//
//  ChatContainerView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct ChatContainerView: View {
    @StateObject private var chatManager = ChatManager()
    @State private var showingSettings: Bool = false
    
    var body: some View {
        NavigationView {
            ChatView(chatManager: chatManager)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gear")
                        }
                    
                        Button(action: chatManager.clearChat) {
                            Image(systemName: "trash")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(
                        systemPrompt: $chatManager.systemPrompt,
                        temperature: $chatManager.temperature,
                        onSave: { }
                    )
                }
        }
    }
} 