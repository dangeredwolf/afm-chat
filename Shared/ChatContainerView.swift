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
    
    // Configuration options
    let showSettings: Bool
    let showClearButton: Bool
    let navigationTitle: String
    
    init(showSettings: Bool = true, showClearButton: Bool = true, navigationTitle: String = "AFM Chat") {
        self.showSettings = showSettings
        self.showClearButton = showClearButton
        self.navigationTitle = navigationTitle
    }
    
    var body: some View {
        NavigationView {
            chatView
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if showSettings {
                            Button(action: { showingSettings = true }) {
                                Image(systemName: "gear")
                            }
                        }
                        
                        if showClearButton {
                            Button(action: chatView.clearChat) {
                                Image(systemName: "trash")
                            }
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