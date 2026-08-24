import SwiftUI

@available(iOS 27, *)
struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadedStore = DownloadedModelStore.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var sort: HuggingFaceModelSort = .trending
    @State private var searchText = ""
    @State private var models: [HuggingFaceModelSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var sizeCheckID: String?
    @State private var sizeCheckTask: Task<Void, Never>?
    @State private var pendingDownloadWarning: PendingModelDownloadWarning?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && models.isEmpty {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, models.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Models", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await loadModels() } }
                    }
                } else {
                    modelList
                }
            }
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search MLX models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(downloads.hasActiveDownloads ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Sort", selection: $sort) {
                        ForEach(HuggingFaceModelSort.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }
            .confirmationDialog(
                Text(pendingDownloadWarning?.title ?? "This model may not run well"),
                isPresented: Binding(
                    get: { pendingDownloadWarning != nil },
                    set: { if !$0 { pendingDownloadWarning = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Download Anyway") {
                    if let model = pendingDownloadWarning?.model {
                        downloads.enqueue(model)
                    }
                    pendingDownloadWarning = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDownloadWarning = nil
                }
            } message: {
                if let pendingDownloadWarning {
                    Text(pendingDownloadWarning.message)
                }
            }
            .onChange(of: sort) { _, _ in
                Task { await loadModels() }
            }
            .onChange(of: searchText) { _, _ in
                scheduleSearch()
            }
            .task {
                await loadModels()
            }
            .onDisappear {
                sizeCheckTask?.cancel()
            }
        }
    }

    private var modelList: some View {
        List {
            ForEach(models) { model in
                modelRow(model)
            }
        }
        .overlay {
            if !isLoading, models.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .refreshable {
            await loadModels()
        }
    }

    @ViewBuilder
    private func modelRow(_ model: HuggingFaceModelSummary) -> some View {
        let downloaded = downloadedStore.contains(model.id)
        let download = downloads.item(for: model.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let lab = ModelLab.infer(from: model.name, model.id) {
                    ModelLabIcon(lab: lab)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                downloadControl(model: model, downloaded: downloaded, download: download)
            }

            HStack(spacing: 10) {
                if let pipelineTag = model.pipelineTag {
                    Text(pipelineTag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Label(formattedCount(model.downloads), systemImage: "arrow.down.circle")
                Label(formattedCount(model.likes), systemImage: "heart")
                if let sizeBytes = model.sizeBytes, sizeBytes > 0 {
                    Text(DownloadByteFormat.bytes(sizeBytes))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let download {
                ModelDownloadProgressBlock(item: download)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func downloadControl(
        model: HuggingFaceModelSummary,
        downloaded: Bool,
        download: ModelDownloadItem?
    ) -> some View {
        if downloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if let download, download.isInFlight {
            ProgressView()
        } else if sizeCheckID == model.id {
            ProgressView()
        } else if let download, case .failed = download.status {
            Button("Retry") {
                downloads.retry(model.id)
            }
            .buttonStyle(.bordered)
        } else {
            Button("Download") {
                requestDownload(model)
            }
            .buttonStyle(.bordered)
        }
    }

    private func requestDownload(_ model: HuggingFaceModelSummary) {
        sizeCheckTask?.cancel()
        sizeCheckID = model.id
        sizeCheckTask = Task {
            let size = await resolvedSize(for: model)
            guard !Task.isCancelled else { return }
            sizeCheckID = nil
            let resolved = modelWithSize(model, size: size)
            let warnMemory = ModelMemoryFit.shouldWarn(modelBytes: size)
            let warnStorage = ModelStorageFit.shouldWarn(modelBytes: size)
            if warnMemory || warnStorage {
                pendingDownloadWarning = PendingModelDownloadWarning(
                    model: resolved,
                    memory: warnMemory,
                    storage: warnStorage
                )
            } else {
                downloads.enqueue(resolved)
            }
        }
    }

    private func resolvedSize(for model: HuggingFaceModelSummary) async -> Int64? {
        if let size = model.sizeBytes, size > 0 {
            return size
        }
        return await HuggingFaceModelCatalog.repositorySize(id: model.id)
    }

    private func modelWithSize(_ model: HuggingFaceModelSummary, size: Int64?) -> HuggingFaceModelSummary {
        HuggingFaceModelSummary(
            id: model.id,
            downloads: model.downloads,
            likes: model.likes,
            pipelineTag: model.pipelineTag,
            tags: model.tags,
            createdAt: model.createdAt,
            trendingScore: model.trendingScore,
            sizeBytes: size ?? model.sizeBytes
        )
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private func loadModels() async {
        isLoading = models.isEmpty
        errorMessage = nil
        do {
            models = try await HuggingFaceModelCatalog.listModels(
                sort: sort,
                search: searchText
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func formattedCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private struct PendingModelDownloadWarning {
    let model: HuggingFaceModelSummary
    let memory: Bool
    let storage: Bool

    var title: String {
        if storage && memory {
            return "This model may not fit this device"
        }
        if storage {
            return "Not enough storage"
        }
        return "This model may not run well"
    }

    var message: String {
        guard let sizeBytes = model.sizeBytes, sizeBytes > 0 else {
            return "This model may not run well on this device."
        }
        var parts: [String] = []
        if storage {
            parts.append(ModelStorageFit.warningMessage(modelBytes: sizeBytes))
        }
        if memory {
            parts.append(ModelMemoryFit.warningMessage(modelBytes: sizeBytes))
        }
        return parts.joined(separator: "\n\n")
    }
}
