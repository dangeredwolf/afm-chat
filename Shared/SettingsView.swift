//
//  SettingsView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct SettingsView: View {
    @Binding var systemPrompt: String
    @Binding var temperature: Double
    @Environment(\.dismiss) private var dismiss
    @State private var tempPrompt: String = ""
    @State private var tempTemperature: Double = 1.0
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
                
                Section(header: Text("Temperature")) {
                    Text("Controls randomness in responses. Lower values (0.0) make responses more focused and deterministic, while higher values (2.0) make them more creative and varied.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Temperature: \(tempTemperature, specifier: "%.1f")")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        Slider(value: $tempTemperature, in: 0.0...2.0, step: 0.1) {
                            Text("Temperature")
                        } minimumValueLabel: {
                            Text("0.0")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } maximumValueLabel: {
                            Text("2.0")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
                        temperature = tempTemperature
                        onSave()
                        dismiss()
                    }
                    .disabled(tempPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            tempPrompt = systemPrompt
            tempTemperature = temperature
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