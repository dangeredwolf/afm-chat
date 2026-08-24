import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject private var downloadedStore = DownloadedModelStore.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddModel = false
    @State private var cachedOptions: [LLMModelOption] = []
    @State private var modelPendingDelete: DownloadedMLXModel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appleOptions) { option in
                        modelRow(for: option)
                    }
                } header: {
                    Text("Apple Intelligence")
                }

                if #available(iOS 27, *) {
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
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if AFM_MLX
            .sheet(isPresented: $showingAddModel) {
                if #available(iOS 27, *) {
                    AddModelView()
                }
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
            .onChange(of: downloadedStore.models) { _, _ in
                refreshOptions()
            }
        }
    }

    private var appleOptions: [LLMModelOption] {
        cachedOptions.filter { $0.choice.mlxModelID == nil }
    }

    private func refreshOptions() {
        cachedOptions = AFMModelCatalog.modelOptions()
    }

    @ViewBuilder
    private func modelRow(for option: LLMModelOption) -> some View {
        Button {
            guard option.isAvailable, !chatManager.isLoading else { return }
            chatManager.selectModel(option.choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                leadingIcon(for: option.choice, displayName: option.displayName)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.displayName)
                        .foregroundStyle(.primary)
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !option.isAvailable, let note = option.unavailabilityNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if chatManager.currentModel == option.choice {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable || chatManager.isLoading)
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
            guard isAvailable, !chatManager.isLoading else { return }
            chatManager.selectModel(choice)
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
                    if let tag = model.pipelineTag {
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if chatManager.currentModel == choice {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || chatManager.isLoading)
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
            modelPendingDelete = nil
        }
    }
}
