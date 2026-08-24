import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var chatManager: ChatManager
    var scope: ChatSettingsScope = .currentChat
    var navigationTitle: String = "Models"

    @ObservedObject private var downloadedStore = DownloadedModelStore.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: ChatSettingsDraft
    @State private var showingAddModel = false
    @State private var cachedOptions: [LLMModelOption] = []
    @State private var modelPendingDelete: DownloadedMLXModel?

    init(
        chatManager: ChatManager,
        scope: ChatSettingsScope = .currentChat,
        navigationTitle: String = "Models"
    ) {
        _chatManager = ObservedObject(wrappedValue: chatManager)
        self.scope = scope
        self.navigationTitle = navigationTitle
        _draft = StateObject(wrappedValue: ChatSettingsDraft(chatManager: chatManager, scope: scope))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ModelSettingsView(chatManager: chatManager, draft: draft)
                    } label: {
                        Label("Model Settings", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        ToolsSettingsView(chatManager: chatManager, draft: draft)
                    } label: {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    if scope == .defaults {
                        Text("These settings will be used when creating new chats.")
                    }
                }

                Section {
                    ForEach(appleOptions) { option in
                        modelRow(for: option)
                    }
                } header: {
                    Text("Apple Intelligence")
                }

                if !downloads.items.isEmpty {
                    Section {
                        ForEach(downloads.items) { item in
                            downloadRow(item)
                        }
                    } header: {
                        Text("Downloading")
                    }
                }

                Section {
                    if downloadedStore.models.isEmpty, downloads.items.isEmpty {
                        Text("Download an open-source MLX model to run it locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(downloadedStore.models) { model in
                            let option = cachedOptions.first {
                                $0.choice.mlxModelID == model.id
                            }
                            downloadedRow(model: model, option: option)
                        }
                    }
                } header: {
                    Text("Downloaded")
                }

                #if AFM_MLX
                Section {
                    Button {
                        showingAddModel = true
                    } label: {
                        Label("Add Model", systemImage: "plus.circle")
                    }
                }
                #endif
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if AFM_MLX
            .sheet(isPresented: $showingAddModel) {
                AddModelView()
            }
            #endif
            .confirmationDialog(
                "Delete \(modelPendingDelete?.displayName ?? "this model")?",
                isPresented: Binding(
                    get: { modelPendingDelete != nil },
                    set: { if !$0 { modelPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Model", role: .destructive) {
                    if let model = modelPendingDelete {
                        deleteDownloaded(model)
                    }
                }
                Button("Cancel", role: .cancel) {
                    modelPendingDelete = nil
                }
            } message: {
                Text("This removes the downloaded weights from this device.")
            }
            .onAppear {
                refreshOptions()
                downloadedStore.refresh()
            }
            .onDisappear {
                draft.persistIfNeeded()
            }
            .onChange(of: downloadedStore.models) { _, _ in
                refreshOptions()
            }
        }
    }

    private var appleOptions: [LLMModelOption] {
        cachedOptions.filter { $0.choice.mlxModelID == nil }
    }

    private var selectedModel: LLMModelChoice {
        draft.model
    }

    private var canChangeModel: Bool {
        draft.isEditable
    }

    private func refreshOptions() {
        cachedOptions = AFMModelCatalog.modelOptions()
    }

    @ViewBuilder
    private func modelRow(for option: LLMModelOption) -> some View {
        Button {
            guard option.isAvailable, canChangeModel else { return }
            draft.applySelectedModel(option.choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                leadingIcon(for: option.choice, displayName: option.displayName)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.displayName)
                        .foregroundStyle(.primary)
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ModelMediaBadges(capabilities: AttachmentMediaSupport.capabilities(for: option.choice))
                    if !option.isAvailable, let note = option.unavailabilityNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if selectedModel == option.choice {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable || !canChangeModel)
    }

    @ViewBuilder
    private func downloadRow(_ item: ModelDownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let lab = ModelLab.infer(from: item.displayName, item.id) {
                    ModelLabIcon(lab: lab)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .foregroundStyle(.primary)
                    Text(item.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ModelMediaBadges(
                        capabilities: HuggingFaceModelCatalog.mediaCapabilities(
                            id: item.id,
                            pipelineTag: item.pipelineTag,
                            tags: item.tags
                        )
                    )
                }
                Spacer()
                if case .failed = item.status {
                    Button("Retry") {
                        downloads.retry(item.id)
                    }
                    .buttonStyle(.bordered)
                } else {
                    ProgressView()
                }
            }
            ModelDownloadProgressBlock(item: item)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                downloads.cancel(item.id)
            } label: {
                Label(item.isInFlight ? "Cancel" : "Dismiss", systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private func downloadedRow(model: DownloadedMLXModel, option: LLMModelOption?) -> some View {
        let choice = LLMModelChoice.mlx(id: model.id)
        let isAvailable = option?.isAvailable ?? HuggingFaceCache.isDownloaded(model.id)

        Button {
            guard isAvailable, canChangeModel else { return }
            draft.applySelectedModel(choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let lab = ModelLab.infer(from: model.displayName, model.id) {
                    ModelLabIcon(lab: lab)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .foregroundStyle(.primary)
                    if !model.author.isEmpty {
                        Text(model.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if let tag = model.pipelineTag {
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ModelMediaBadges(
                            capabilities: HuggingFaceModelCatalog.mediaCapabilities(
                                id: model.id,
                                pipelineTag: model.pipelineTag
                            )
                        )
                    }
                }
                Spacer()
                if selectedModel == choice {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || !canChangeModel)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                modelPendingDelete = model
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func leadingIcon(for choice: LLMModelChoice, displayName: String) -> some View {
        switch choice {
        case .onDevice, .privateCloudCompute:
            AppleIntelligenceIcon()
        case .mlx(let id):
            if let lab = ModelLab.infer(from: displayName, id) {
                ModelLabIcon(lab: lab)
            }
        }
    }

    private func deleteDownloaded(_ model: DownloadedMLXModel) {
        Task {
            await downloadedStore.remove(model.id)
            chatManager.resetChats(usingDeletedModel: model.id)
            if draft.model.mlxModelID == model.id {
                draft.applySelectedModel(AFMModelCatalog.resolvedDefaultModel())
            }
            modelPendingDelete = nil
        }
    }
}
