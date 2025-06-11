//
//  SettingsView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct SettingsView: View {
    @Binding var systemPrompt: String
    @Environment(\.dismiss) private var dismiss
    @State private var tempPrompt: String = ""
    let onSave: () -> Void
    
    private let defaultPrompt = "You are a helpful assistant."
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("System Prompt")) {
                    Text("Customize how the AI assistant behaves by modifying the system prompt below:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $tempPrompt)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    
                    Button("Reset to Default") {
                        tempPrompt = defaultPrompt
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        systemPrompt = tempPrompt
                        onSave()
                        dismiss()
                    }
                    .disabled(tempPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            tempPrompt = systemPrompt
        }
    }
}

struct PromptPresetButton: View {
    let title: String
    let prompt: String
    @Binding var tempPrompt: String
    
    var body: some View {
        Button(action: {
            tempPrompt = prompt
        }) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
} 