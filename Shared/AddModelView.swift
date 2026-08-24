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
            .onChange(of: sort) { _, _ in
                Task { await loadModels() }
            }
            .onChange(of: searchText) { _, _ in
                scheduleSearch()
            }
            .task {
                await loadModels()
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
        } else if let download, case .failed = download.status {
            Button("Retry") {
                downloads.retry(model.id)
            }
            .buttonStyle(.bordered)
        } else {
            Button("Download") {
                downloads.enqueue(model)
            }
            .buttonStyle(.bordered)
        }
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
