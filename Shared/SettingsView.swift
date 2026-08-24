//
//  SettingsView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
internal import Combine

@MainActor
final class ChatSettingsDraft: ObservableObject {
    let scope: ChatSettingsScope
    private let chatManager: ChatManager
    private var loaded: ChatSettingsValues

    @Published var systemPrompt: String
    @Published var temperature: Double
    @Published var model: LLMModelChoice
    @Published var reasoningLevel: LLMReasoningLevel
    @Published var thinkingEnabled: Bool
    @Published var thinkingBudgetTokens: Int?
    @Published var toolsEnabled: Bool
    @Published var toolCodeInterpreterEnabled: Bool
    @Published var toolWebSearchEnabled: Bool
    @Published var toolWebFetchEnabled: Bool
    @Published var appendDateToSystemPrompt: Bool

    init(chatManager: ChatManager, scope: ChatSettingsScope) {
        self.chatManager = chatManager
        self.scope = scope
        let values = chatManager.settingsValues(for: scope)
        self.loaded = values
        self.systemPrompt = values.systemPrompt
        self.temperature = values.temperature
        self.model = values.model
        self.reasoningLevel = values.reasoningLevel
        self.thinkingEnabled = values.thinkingEnabled
        self.thinkingBudgetTokens = values.thinkingBudgetTokens
        self.toolsEnabled = values.toolsEnabled
        self.toolCodeInterpreterEnabled = values.toolCodeInterpreterEnabled
        self.toolWebSearchEnabled = values.toolWebSearchEnabled
        self.toolWebFetchEnabled = values.toolWebFetchEnabled
        self.appendDateToSystemPrompt = values.appendDateToSystemPrompt
    }

    var isEditable: Bool {
        scope == .defaults || !chatManager.isLoading
    }

    func applySelectedModel(_ model: LLMModelChoice) {
        guard isEditable else { return }
        self.model = model
        loaded.model = model
        chatManager.selectModel(model, scope: scope)
        if model.mlxModelID != nil, !AFMModelCatalog.mlxCanDisableThinking(model) {
            thinkingEnabled = true
            loaded.thinkingEnabled = true
        }
    }

    func persistIfNeeded() {
        guard isEditable else { return }
        var values = currentValues
        if values.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.systemPrompt = loaded.systemPrompt
            systemPrompt = loaded.systemPrompt
        }
        if values.model.mlxModelID != nil {
            values.thinkingEnabled = AFMModelCatalog.mlxCanDisableThinking(values.model)
                ? values.thinkingEnabled
                : true
            thinkingEnabled = values.thinkingEnabled
        }
        guard values != loaded else { return }
        chatManager.persistSettings(values, scope: scope)
        loaded = values
    }

    private var currentValues: ChatSettingsValues {
        ChatSettingsValues(
            systemPrompt: systemPrompt,
            temperature: temperature,
            model: model,
            reasoningLevel: reasoningLevel,
            thinkingEnabled: thinkingEnabled,
            thinkingBudgetTokens: thinkingBudgetTokens,
            toolsEnabled: toolsEnabled,
            toolCodeInterpreterEnabled: toolCodeInterpreterEnabled,
            toolWebSearchEnabled: toolWebSearchEnabled,
            toolWebFetchEnabled: toolWebFetchEnabled,
            appendDateToSystemPrompt: appendDateToSystemPrompt
        )
    }
}

struct ModelSettingsView: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var draft: ChatSettingsDraft

    private let defaultPrompt = "You are a helpful assistant."

    private var isEditable: Bool {
        draft.scope == .defaults || !chatManager.isLoading
    }

    var body: some View {
        Form {
            Section(header: Text("System Prompt")) {

                TextEditor(text: $draft.systemPrompt)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1.0 : 0.6)

                Toggle("Append today's date", isOn: $draft.appendDateToSystemPrompt)
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1.0 : 0.6)


                Button("Reset to Default") {
                    draft.systemPrompt = defaultPrompt
                }
                .foregroundColor(.blue)
                .disabled(!isEditable)
                .opacity(isEditable ? 1.0 : 0.6)
            }

            Section(header: Text("Temperature")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature: \(draft.temperature, specifier: "%.1f")")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }

                    Slider(value: $draft.temperature, in: 0.0...2.0, step: 0.1) {
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
                    .disabled(!isEditable)
                }
                .padding(.vertical, 4)
                .opacity(isEditable ? 1.0 : 0.6)
            }

            if AFMModelCatalog.usesAppleReasoningLevels(draft.model) {
                appleReasoningSection
            } else if draft.model.mlxModelID != nil {
                mlxThinkingSection
            }
        }
        .navigationTitle("Model Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft.model.mlxModelID != nil, !AFMModelCatalog.mlxCanDisableThinking(draft.model) {
                draft.thinkingEnabled = true
            }
        }
        .onDisappear {
            draft.persistIfNeeded()
        }
    }

    private var appleReasoningSection: some View {
        Section(header: Text("Reasoning Level")) {
            Text("Controls how much the model thinks before responding. Light is fastest; Deep allows more analysis.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Reasoning Level", selection: $draft.reasoningLevel) {
                ForEach(LLMReasoningLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isEditable)
            .opacity(isEditable ? 1.0 : 0.6)

            Text(draft.reasoningLevel.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var mlxThinkingSection: some View {
        let canDisable = AFMModelCatalog.mlxCanDisableThinking(draft.model)
        let supportsBudget = AFMModelCatalog.mlxSupportsThinkingBudget(draft.model)
        return Section(header: Text("Thinking")) {
            Toggle("Thinking", isOn: $draft.thinkingEnabled)
                .disabled(!isEditable || !canDisable)
                .opacity(isEditable ? 1.0 : 0.6)

            if !canDisable {
                Text("This model always thinks and cannot turn it off.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if supportsBudget && (draft.thinkingEnabled || !canDisable) {
                Picker("Thinking Budget", selection: $draft.thinkingBudgetTokens) {
                    Text("Unlimited").tag(Optional<Int>.none)
                    ForEach(LLMThinkingBudget.presets, id: \.self) { tokens in
                        Text("\(tokens) tokens").tag(Optional(tokens))
                    }
                }
                .disabled(!isEditable)
                .opacity(isEditable ? 1.0 : 0.6)

                Text("Caps how many tokens the model may spend thinking before it answers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ToolsSettingsView: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var draft: ChatSettingsDraft

    private var isEditable: Bool {
        draft.scope == .defaults || !chatManager.isLoading
    }

    private var webSearchAvailable: Bool {
        AppToolID.webSearch.isAvailable
    }

    private var webSearchEnabledBinding: Binding<Bool> {
        webSearchAvailable ? $draft.toolWebSearchEnabled : .constant(false)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Tools", isOn: $draft.toolsEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .padding(.vertical, 6)
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1.0 : 0.6)

                if draft.toolsEnabled {
                    Toggle(isOn: $draft.toolCodeInterpreterEnabled) {
                        HStack {
                            Image(systemName: "gear").foregroundColor(.blue)
                            Text(AppToolID.codeInterpreter.definition.displayName)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1.0 : 0.6)

                    Toggle(isOn: webSearchEnabledBinding) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(webSearchAvailable ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppToolID.webSearch.definition.displayName)
                                if !webSearchAvailable {
                                    Text("Temporarily unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .disabled(!isEditable || !webSearchAvailable)
                    .opacity(isEditable && webSearchAvailable ? 1.0 : 0.6)

                    Toggle(isOn: $draft.toolWebFetchEnabled) {
                        HStack {
                            Image(systemName: "doc.text").foregroundColor(.green)
                            Text(AppToolID.webFetch.definition.displayName)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1.0 : 0.6)
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            draft.persistIfNeeded()
        }
    }
}
