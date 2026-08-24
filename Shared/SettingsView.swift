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
    @Binding var model: LLMModelChoice
    @Binding var reasoningLevel: LLMReasoningLevel
    @Binding var thinkingEnabled: Bool
    @Binding var thinkingBudgetTokens: Int?
    @Binding var toolsEnabled: Bool
    @Binding var toolCodeInterpreterEnabled: Bool
    @Binding var toolWebSearchEnabled: Bool
    @Binding var toolWebFetchEnabled: Bool
    @Binding var appendDateToSystemPrompt: Bool
    let isSettingsEditable: Bool
    let hasConversationHistory: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var tempPrompt: String = ""
    @State private var tempTemperature: Double = 1.0
    @State private var tempModel: LLMModelChoice = .onDevice
    @State private var tempReasoningLevel: LLMReasoningLevel = .moderate
    @State private var tempThinkingEnabled: Bool = true
    @State private var tempThinkingBudgetTokens: Int? = nil
    @State private var tempToolsEnabled: Bool = true
    @State private var tempToolCodeInterpreterEnabled: Bool = true
    @State private var tempToolWebSearchEnabled: Bool = true
    @State private var tempToolWebFetchEnabled: Bool = true
    @State private var tempAppendDateToSystemPrompt: Bool = true
    let onSave: () -> Void

    private let defaultPrompt = "You are a helpful assistant."

    private var modelOptions: [LLMModelOption] {
        AFMModelCatalog.modelOptions()
    }

    private var selectedModelOption: LLMModelOption? {
        modelOptions.first { $0.choice == tempModel }
    }

    private var supportsReasoningForSelectedModel: Bool {
        AFMModelCatalog.supportsReasoning(tempModel)
    }

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
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)

                    Toggle("Append today's date", isOn: $tempAppendDateToSystemPrompt)
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)

                    Text("When enabled, adds the current date to the end of the system prompt sent to the model.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Reset to Default") {
                        tempPrompt = defaultPrompt
                    }
                    .foregroundColor(.blue)
                    .disabled(!isSettingsEditable)
                    .opacity(isSettingsEditable ? 1.0 : 0.6)
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
                        .disabled(!isSettingsEditable)
                    }
                    .padding(.vertical, 4)
                    .opacity(isSettingsEditable ? 1.0 : 0.6)
                }

                if supportsReasoningForSelectedModel {
                    if AFMModelCatalog.usesAppleReasoningLevels(tempModel) {
                        appleReasoningSection
                    } else {
                        mlxThinkingSection
                    }
                }

                Section(header: Text("Tools")) {
                    Toggle("Enable Tools", isOn: $tempToolsEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .padding(.vertical, 6)
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)

                    if tempToolsEnabled {
                        Toggle(isOn: $tempToolCodeInterpreterEnabled) {
                            HStack {
                                Image(systemName: "gear").foregroundColor(.blue)
                                Text("Code Interpreter")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)

                        Toggle(isOn: $tempToolWebSearchEnabled) {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.orange)
                                Text("Web Search")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)

                        Toggle(isOn: $tempToolWebFetchEnabled) {
                            HStack {
                                Image(systemName: "doc.text").foregroundColor(.green)
                                Text("Web Fetch")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .disabled(!isSettingsEditable)
                        .opacity(isSettingsEditable ? 1.0 : 0.6)
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
                        model = tempModel
                        reasoningLevel = tempReasoningLevel
                        if tempModel.mlxModelID != nil {
                            thinkingEnabled = AFMModelCatalog.mlxCanDisableThinking(tempModel)
                                ? tempThinkingEnabled
                                : true
                        } else {
                            thinkingEnabled = tempThinkingEnabled
                        }
                        thinkingBudgetTokens = tempThinkingBudgetTokens
                        toolsEnabled = tempToolsEnabled
                        toolCodeInterpreterEnabled = tempToolCodeInterpreterEnabled
                        toolWebSearchEnabled = tempToolWebSearchEnabled
                        toolWebFetchEnabled = tempToolWebFetchEnabled
                        appendDateToSystemPrompt = tempAppendDateToSystemPrompt
                        onSave()
                        dismiss()
                    }
                    .disabled(
                        !isSettingsEditable
                        || tempPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !(selectedModelOption?.isAvailable ?? false)
                    )
                }
            }
        }
        .onAppear {
            tempPrompt = systemPrompt
            tempTemperature = temperature
            tempModel = model
            tempReasoningLevel = reasoningLevel
            tempThinkingEnabled = thinkingEnabled
            if model.mlxModelID != nil, !AFMModelCatalog.mlxCanDisableThinking(model) {
                tempThinkingEnabled = true
            }
            tempThinkingBudgetTokens = thinkingBudgetTokens
            tempToolsEnabled = toolsEnabled
            tempToolCodeInterpreterEnabled = toolCodeInterpreterEnabled
            tempToolWebSearchEnabled = toolWebSearchEnabled
            tempToolWebFetchEnabled = toolWebFetchEnabled
            tempAppendDateToSystemPrompt = appendDateToSystemPrompt
        }
        .onChange(of: tempModel) { _, newModel in
            if newModel.mlxModelID != nil, !AFMModelCatalog.mlxCanDisableThinking(newModel) {
                tempThinkingEnabled = true
            }
        }
    }

    private var appleReasoningSection: some View {
        Section(header: Text("Reasoning Level")) {
            Text("Controls how much the model thinks before responding. Light is fastest; Deep allows more analysis.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Reasoning Level", selection: $tempReasoningLevel) {
                ForEach(LLMReasoningLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isSettingsEditable)
            .opacity(isSettingsEditable ? 1.0 : 0.6)

            Text(tempReasoningLevel.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var mlxThinkingSection: some View {
        let canDisable = AFMModelCatalog.mlxCanDisableThinking(tempModel)
        let supportsBudget = AFMModelCatalog.mlxSupportsThinkingBudget(tempModel)
        return Section(header: Text("Thinking")) {
            Text("When thinking is on, the model reasons before answering. You can inspect those tokens in the chat.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Thinking", isOn: $tempThinkingEnabled)
                .disabled(!isSettingsEditable || !canDisable)
                .opacity(isSettingsEditable ? 1.0 : 0.6)

            if !canDisable {
                Text("This model always thinks and cannot turn it off.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if supportsBudget && (tempThinkingEnabled || !canDisable) {
                Picker("Thinking Budget", selection: $tempThinkingBudgetTokens) {
                    Text("Unlimited").tag(Optional<Int>.none)
                    ForEach(LLMThinkingBudget.presets, id: \.self) { tokens in
                        Text("\(tokens) tokens").tag(Optional(tokens))
                    }
                }
                .disabled(!isSettingsEditable)
                .opacity(isSettingsEditable ? 1.0 : 0.6)

                Text("Caps how many tokens the model may spend thinking before it answers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
