//
//  ChatContainerView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct ChatContainerView: View {
    @State private var showingSettings: Bool = false
    @State private var chatView = ChatView()
    
    var body: some View {
        NavigationView {
            chatView
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gear")
                        }
                    
                        Button(action: chatView.clearChat) {
                            Image(systemName: "trash")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(
                        systemPrompt: chatView.systemPromptBinding,
                        onSave: chatView.updateSession
                    )
                }
        }
    }
} 