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
    @Binding var toolsEnabled: Bool
    // Per-tool bindings (parent)
    @Binding var toolCodeInterpreterEnabled: Bool
    @Binding var toolLocationEnabled: Bool
    @Binding var toolWebFetchEnabled: Bool
    @Binding var toolWebSearchEnabled: Bool
    let canEditToolsAndPrompt: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var tempPrompt: String = ""
    @State private var tempTemperature: Double = 1.0
    @State private var tempToolsEnabled: Bool = true
    // Temp per-tool states used within the sheet until Save
    @State private var tempToolCodeInterpreterEnabled: Bool = true
    @State private var tempToolLocationEnabled: Bool = true
    @State private var tempToolWebFetchEnabled: Bool = true
    @State private var tempToolWebSearchEnabled: Bool = true
    let onSave: () -> Void
    
    private let defaultPrompt = "You are a helpful assistant."
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("System Prompt")) {
                    Text("Customize how the language model behaves by modifying the system prompt below:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $tempPrompt)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)
                    
                    Button("Reset to Default") {
                        tempPrompt = defaultPrompt
                    }
                    .foregroundColor(.blue)
                    .disabled(!canEditToolsAndPrompt)
                    .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)
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
                
                Section(header: Text("Tools")) {
                    Text("The language model can use tools to enable more advanced functionality such as executing code or retrieving information from your device and the internet. Note: With tools enabled, the model might be less willing to answer general questions without using tools.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Toggle("Enable Tools (Experimental)", isOn: $tempToolsEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .padding(.vertical, 6)
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)
                    
                    if tempToolsEnabled {
                        Toggle(isOn: $tempToolCodeInterpreterEnabled) {
                            HStack {
                                Image(systemName: "gear").foregroundColor(.blue)
                                Text("Code Interpreter")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)

                        Toggle(isOn: $tempToolLocationEnabled) {
                            HStack {
                                Image(systemName: "location").foregroundColor(.green)
                                Text("Location")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)

                        Toggle(isOn: $tempToolWebFetchEnabled) {
                            HStack {
                                Image(systemName: "safari").foregroundColor(.purple)
                                Text("Web Fetch")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)

                        Toggle(isOn: $tempToolWebSearchEnabled) {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.orange)
                                Text("Web Search")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!canEditToolsAndPrompt)
                        .opacity(canEditToolsAndPrompt ? 1.0 : 0.6)
                    }
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
                        toolsEnabled = tempToolsEnabled
                        toolCodeInterpreterEnabled = tempToolCodeInterpreterEnabled
                        toolLocationEnabled = tempToolLocationEnabled
                        toolWebFetchEnabled = tempToolWebFetchEnabled
                        toolWebSearchEnabled = tempToolWebSearchEnabled
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
            tempToolsEnabled = toolsEnabled
            tempToolCodeInterpreterEnabled = toolCodeInterpreterEnabled
            tempToolLocationEnabled = toolLocationEnabled
            tempToolWebFetchEnabled = toolWebFetchEnabled
            tempToolWebSearchEnabled = toolWebSearchEnabled
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
