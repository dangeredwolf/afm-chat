//
//  ChatContainerView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct ChatContainerView: View {
    @StateObject private var chatManager = ChatManager()
    @State private var selectedChatId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showingModelUnavailableAlert = false
    
    private var availability: LLMAvailability { LLMProviderManager.shared.client.availability }
    
    var body: some View {
        Group {
            switch availability {
            case .available:
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ChatListView(
                        chatManager: chatManager,
                        selectedChatId: $selectedChatId
                    )
                } detail: {
                    detailContent
                }
            case .unavailable(.deviceNotEligible):
                NavigationStack {
                    ModelUnavailableView(
                        title: "Device Not Compatible",
                        message: "Your device doesn't support Apple Intelligence features. Apple Intelligence requires an A17 Pro, A18, or M1 chip or better.",
                        icon: "exclamationmark.triangle"
                    )
                }
            case .unavailable(.notEnabled):
                NavigationStack {
                    ModelUnavailableView(
                        title: "Apple Intelligence Required",
                        message: "You need to enable Apple Intelligence in Settings. It might take a few minutes for your device to download the language model.",
                        icon: "brain.head.profile",
                        showSettingsButton: true
                    )
                }
            case .unavailable(.modelNotReady):
                NavigationStack {
                    ModelUnavailableView(
                        title: "Model Downloading",
                        message: "The Apple Intelligence language model is currently downloading in the background. Check its status in Settings.",
                        icon: "arrow.down.circle",
                        showSettingsButton: true
                    )
                }
            case .unavailable(let other):
                NavigationStack {
                    ModelUnavailableView(
                        title: "Model Unavailable",
                        message: "The Apple Intelligence language model is currently unavailable. Please try again later.\n\nError: \(other)",
                        icon: "exclamationmark.circle"
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private var detailContent: some View {
        if let selectedChatId {
            let title = chatManager.chats.first(where: { $0.id == selectedChatId })?.title ?? "New Chat"
            ChatDetailView(
                chatManager: chatManager,
                chatId: selectedChatId,
                initialTitle: title
            )
        } else {
            ChatDetailPlaceholderView()
        }
    }
}

struct ModelUnavailableView: View {
    let title: String
    let message: String
    let icon: String
    let showSettingsButton: Bool
    
    init(title: String, message: String, icon: String, showSettingsButton: Bool = false) {
        self.title = title
        self.message = message
        self.icon = icon
        self.showSettingsButton = showSettingsButton
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
            
            if showSettingsButton {
                Button(action: openSettings) {
                    Text("Open Settings")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
        }
        .padding(.horizontal, 32)
        .navigationTitle("AFM Chat")
    }
    
    private func openSettings() {
        
        UIApplication.shared.open(URL(string:"App-prefs:SIRI")!)
    }
}

struct ChatListView: View {
    @ObservedObject var chatManager: ChatManager
    @Binding var selectedChatId: UUID?
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var isSearchPresented = false

    private var displayedSections: [ChatListSection] {
        let sortedChats = chatsSortedByActivity(chatManager.chats)
        if isActivelySearching || !searchText.isEmpty {
            return searchResultSections(from: sortedChats, query: searchText)
        }
        return groupedChats(sortedChats)
    }

    private var isActivelySearching: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        isSearchPresented
        #endif
    }

    private var isShowingEmptySearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && displayedSections.isEmpty
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        macBody
        #else
        iosBody
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private var macBody: some View {
        chatList
            .safeAreaInset(edge: .top, spacing: 0) {
                MacSidebarSearchField(text: $searchText)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: createNewChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Chat")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    .help("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                GlobalSettingsView(chatManager: chatManager)
            }
            .onChange(of: selectedChatId) { _, newId in
                handleSelectionChange(newId)
            }
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    private var iosBody: some View {
        ZStack(alignment: .bottom) {
            chatList
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: FloatingActionButton.hitSize + 16)
                }

            GlassEffectContainer(spacing: 16) {
                HStack {
                    Spacer(minLength: 0)

                    FloatingActionButton(icon: "square.and.pencil") {
                        createNewChat()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: FloatingActionButton.hitSize)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .zIndex(1)
        }
        .navigationTitle(isSearchPresented ? "" : "Conversations")
        .navigationBarTitleDisplayMode(isSearchPresented ? .inline : .large)
        .toolbar(isSearchPresented ? .hidden : .visible, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearchPresented {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: dismissSearch) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Cancel")

                        IOSSearchField(text: $searchText, isFocused: $isSearchFieldFocused)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .toolbar {
            if !isSearchPresented {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            GlobalSettingsView(chatManager: chatManager)
        }
        .onChange(of: isSearchPresented) { _, presented in
            if presented {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: selectedChatId) { _, newId in
            handleSelectionChange(newId)
        }
    }
    #endif

    private var chatList: some View {
        List(selection: $selectedChatId) {
            ForEach(displayedSections) { section in
                Section {
                    ForEach(section.chats) { chat in
                        ChatRowView(chat: chat, searchQuery: searchText)
                            .tag(chat.id)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteChat(chat)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .listStyle(.sidebar)
        #else
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        .listRowSeparator(.visible)
        .overlay {
            if isShowingEmptySearchResults {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func createNewChat() {
        let newChatId = chatManager.createNewChat()
        selectedChatId = newChatId
    }

    #if !targetEnvironment(macCatalyst)
    private func dismissSearch() {
        isSearchPresented = false
        searchText = ""
        isSearchFieldFocused = false
    }
    #endif

    private func handleSelectionChange(_ newId: UUID?) {
        if let newId {
            if chatManager.temporaryChat?.id == newId {
                chatManager.currentChatId = newId
            } else {
                chatManager.switchToChat(newId)
            }
        }
    }

    private func deleteChat(_ chat: Chat) {
        if chat.id == selectedChatId {
            selectedChatId = nil
        }
        chatManager.deleteChat(chat.id)
    }
}

#if !targetEnvironment(macCatalyst)
private struct IOSSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.body)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
#endif

#if targetEnvironment(macCatalyst)
private struct MacSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
#endif

struct FloatingActionButton: View {
    static let hitSize: CGFloat = 72
    private static let visualSize: CGFloat = 54

    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: Self.visualSize, height: Self.visualSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Circle())
    }
}

struct ChatDetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Start a New Conversation")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("Select a conversation or tap compose to start a new one.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        #if targetEnvironment(macCatalyst)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle("AFM Chat")
        #endif
    }
}

struct ChatDetailView: View {
    @ObservedObject var chatManager: ChatManager
    let chatId: UUID
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingSettings: Bool = false
    @State private var chatTitle: String
    let initialTitle: String
    
    init(
        chatManager: ChatManager,
        chatId: UUID,
        initialTitle: String = "New Chat"
    ) {
        self.chatManager = chatManager
        self.chatId = chatId
        self.initialTitle = initialTitle
        self._chatTitle = State(initialValue: initialTitle)
    }
    
    var body: some View {
        ChatView(chatManager: chatManager)
            .navigationBarBackButtonHidden(horizontalSizeClass == .regular)
            .navigationTitle(chatTitle)
            #if targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if chatManager.showsContextUsageIndicator,
                   let usage = chatManager.contextUsage {
                    ToolbarItem(placement: .topBarTrailing) {
                        ContextUsageIndicator(
                            usage: usage,
                            contextWindowSizes: chatManager.contextWindowSizes
                        )
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    #if targetEnvironment(macCatalyst)
                    .help("Chat Settings")
                    #endif
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    systemPrompt: Binding(
                        get: { chatManager.currentSystemPrompt },
                        set: { newPrompt in
                            chatManager.updateChatSettings(
                                systemPrompt: newPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    temperature: Binding(
                        get: { chatManager.currentTemperature },
                        set: { newTemperature in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: newTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    model: Binding(
                        get: { chatManager.currentModel },
                        set: { newModel in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: newModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    reasoningLevel: Binding(
                        get: { chatManager.currentReasoningLevel },
                        set: { newReasoningLevel in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: newReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    toolsEnabled: Binding(
                        get: { chatManager.currentToolsEnabled },
                        set: { newToolsEnabled in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: newToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    toolCodeInterpreterEnabled: Binding(
                        get: { chatManager.currentChat?.toolCodeInterpreterEnabled ?? true },
                        set: { newValue in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: newValue,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    toolWebSearchEnabled: Binding(
                        get: { chatManager.currentChat?.toolWebSearchEnabled ?? true },
                        set: { newValue in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: newValue,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    toolWebFetchEnabled: Binding(
                        get: { chatManager.currentChat?.toolWebFetchEnabled ?? true },
                        set: { newValue in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: chatManager.currentAppendDateToSystemPrompt,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: newValue
                                )
                            )
                        }
                    ),
                    appendDateToSystemPrompt: Binding(
                        get: { chatManager.currentAppendDateToSystemPrompt },
                        set: { newValue in
                            chatManager.updateChatSettings(
                                systemPrompt: chatManager.currentSystemPrompt,
                                temperature: chatManager.currentTemperature,
                                model: chatManager.currentModel,
                                reasoningLevel: chatManager.currentReasoningLevel,
                                toolsEnabled: chatManager.currentToolsEnabled,
                                appendDateToSystemPrompt: newValue,
                                perTools: (
                                    code: chatManager.currentChat?.toolCodeInterpreterEnabled ?? true,
                                    webSearch: chatManager.currentChat?.toolWebSearchEnabled ?? true,
                                    webFetch: chatManager.currentChat?.toolWebFetchEnabled ?? true
                                )
                            )
                        }
                    ),
                    isSettingsEditable: !chatManager.isLoading,
                    hasConversationHistory: !chatManager.currentMessages.isEmpty,
                    onSave: { }
                )
            }
            .onAppear {
                activateChat(chatId)
            }
            .onChange(of: chatId) { _, newId in
                activateChat(newId)
            }
            .onChange(of: chatManager.currentChat?.title) { _, newTitle in
                // Update title when chat title changes (e.g., after first message)
                if let newTitle = newTitle {
                    chatTitle = newTitle
                }
            }
    }
    
    private func activateChat(_ id: UUID) {
        if chatManager.temporaryChat?.id == id {
            chatManager.currentChatId = id
        } else {
            chatManager.switchToChat(id)
        }
        
        if let chat = chatManager.chats.first(where: { $0.id == id }) {
            chatTitle = chat.title
        } else {
            chatTitle = "New Chat"
        }
        
        chatManager.refreshContextWindowMetadata()
    }
}

struct GlobalSettingsView: View {
    @ObservedObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss
    @State private var defaultPrompt: String = ""
    @State private var defaultTemperature: Double = 1.0
    @State private var defaultModel: LLMModelChoice = .onDevice
    @State private var defaultReasoningLevel: LLMReasoningLevel = .moderate
    @State private var defaultToolsEnabled: Bool = true
    @State private var defaultToolCodeInterpreterEnabled: Bool = true
    @State private var defaultToolWebSearchEnabled: Bool = true
    @State private var defaultToolWebFetchEnabled: Bool = true
    @State private var defaultAppendDateToSystemPrompt: Bool = true
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Default Settings for New Chats")) {
                    Text("These settings will be used when creating new chats.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("System Prompt")
                        .font(.headline)
                    TextEditor(text: $defaultPrompt)
                        .frame(minHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    Toggle("Append today's date", isOn: $defaultAppendDateToSystemPrompt)

                    Text("When enabled, adds the current date to the end of the system prompt sent to the model.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Model", selection: $defaultModel) {
                            ForEach(AFMModelCatalog.modelOptions()) { option in
                                Text(option.displayName).tag(option.choice)
                            }
                        }
                        .pickerStyle(.menu)

                        if let option = AFMModelCatalog.modelOptions().first(where: { $0.choice == defaultModel }) {
                            Text(option.description)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if !option.isAvailable,
                               let note = option.unavailabilityNote {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    if AFMModelCatalog.supportsReasoning(defaultModel) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Reasoning Level", selection: $defaultReasoningLevel) {
                                ForEach(LLMReasoningLevel.allCases) { level in
                                    Text(level.displayName).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(defaultReasoningLevel.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Temperature: \(defaultTemperature, specifier: "%.1f")")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Slider(value: $defaultTemperature, in: 0.0...2.0, step: 0.1)
                    }
                }
                
                Section(header: Text("Tools")) {
                    Toggle("Enable Tools", isOn: $defaultToolsEnabled)
                        .toggleStyle(SwitchToggleStyle())
                    
                    if defaultToolsEnabled {
                        Toggle(isOn: $defaultToolCodeInterpreterEnabled) {
                            HStack {
                                Image(systemName: "gear").foregroundColor(.blue)
                                Text("Code Interpreter")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        Toggle(isOn: $defaultToolWebSearchEnabled) {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundColor(.orange)
                                Text("Web Search")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        Toggle(isOn: $defaultToolWebFetchEnabled) {
                            HStack {
                                Image(systemName: "doc.text").foregroundColor(.green)
                                Text("Web Fetch")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
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
                        UserDefaults.standard.set(defaultPrompt, forKey: "systemPrompt")
                        UserDefaults.standard.set(defaultTemperature, forKey: "temperature")
                        UserDefaults.standard.set(defaultModel.rawValue, forKey: "model")
                        UserDefaults.standard.set(defaultReasoningLevel.rawValue, forKey: "reasoningLevel")
                        UserDefaults.standard.set(defaultToolsEnabled, forKey: "toolsEnabled")
                        UserDefaults.standard.set(defaultToolCodeInterpreterEnabled, forKey: "toolCodeInterpreterEnabled")
                        UserDefaults.standard.set(defaultToolWebSearchEnabled, forKey: "toolWebSearchEnabled")
                        UserDefaults.standard.set(defaultToolWebFetchEnabled, forKey: "toolWebFetchEnabled")
                        UserDefaults.standard.set(defaultAppendDateToSystemPrompt, forKey: "appendDateToSystemPrompt")
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            defaultPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
            defaultTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 1.0
            defaultModel = LLMModelChoice(
                rawValue: UserDefaults.standard.string(forKey: "model") ?? LLMModelChoice.onDevice.rawValue
            ) ?? .onDevice
            defaultReasoningLevel = LLMReasoningLevel(
                rawValue: UserDefaults.standard.string(forKey: "reasoningLevel") ?? LLMReasoningLevel.moderate.rawValue
            ) ?? .moderate
            defaultToolsEnabled = UserDefaults.standard.object(forKey: "toolsEnabled") as? Bool ?? false
            defaultToolCodeInterpreterEnabled = UserDefaults.standard.object(forKey: "toolCodeInterpreterEnabled") as? Bool ?? true
            defaultToolWebSearchEnabled = UserDefaults.standard.object(forKey: "toolWebSearchEnabled") as? Bool ?? true
            defaultToolWebFetchEnabled = UserDefaults.standard.object(forKey: "toolWebFetchEnabled") as? Bool ?? true
            defaultAppendDateToSystemPrompt = UserDefaults.standard.object(forKey: "appendDateToSystemPrompt") as? Bool ?? true
        }
    }
}

struct ChatRowView: View {
    let chat: Chat
    var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.title)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let snippet = chat.matchingSnippet(for: searchQuery) {
                Text(snippet)
                    .font(.subheadline)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            } else {
                Text("No messages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
} 
