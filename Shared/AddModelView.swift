import SwiftUI

struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var sort: HuggingFaceModelSort = .trending
    @State private var searchText = ""
    @State private var models: [HuggingFaceModelSummary] = []
    @State private var recommended: [HuggingFaceModelSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && models.isEmpty && (isSearching || visibleRecommended.isEmpty) {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, models.isEmpty, isSearching || visibleRecommended.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Models", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await reloadAll() } }
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
                await reloadAll()
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleRecommended: [HuggingFaceModelSummary] {
        isSearching ? [] : recommended
    }

    private var hubModels: [HuggingFaceModelSummary] {
        guard !isSearching else { return models }
        let recommendedIDs = Set(recommended.map(\.id))
        return models.filter { !recommendedIDs.contains($0.id) }
    }

    private var modelList: some View {
        List {
            if !visibleRecommended.isEmpty {
                Section("Recommended") {
                    ForEach(visibleRecommended) { model in
                        modelRow(model)
                    }
                }
            }
            if !hubModels.isEmpty {
                Section {
                    ForEach(hubModels) { model in
                        modelRow(model)
                    }
                }
            }
        }
        .overlay {
            if !isLoading, models.isEmpty, isSearching || visibleRecommended.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .refreshable {
            await reloadAll()
        }
    }

    private func modelRow(_ model: HuggingFaceModelSummary) -> some View {
        NavigationLink {
            ModelReadmeView(model: model)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                modelRowLabel(model)
                ModelHubDownloadButton(model: model)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint("Opens the model README")
    }

    private func modelRowLabel(_ model: HuggingFaceModelSummary) -> some View {
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
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if let pipelineTag = model.pipelineTag {
                    Text(pipelineTag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                ModelMediaBadges(capabilities: model.mediaCapabilities)
                Label(formattedCount(model.downloads), systemImage: "arrow.down.circle")
                Label(formattedCount(model.likes), systemImage: "heart")
                if let sizeBytes = model.sizeBytes, sizeBytes > 0 {
                    Text(DownloadByteFormat.bytes(sizeBytes))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let download = downloads.item(for: model.id) {
                ModelDownloadProgressBlock(item: download)
            }
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

    private func reloadAll() async {
        async let hub: Void = loadModels()
        async let rec: Void = loadRecommended()
        _ = await (hub, rec)
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

    private func loadRecommended() async {
        recommended = await RecommendedModelCatalog.loadSummaries()
    }

    private func formattedCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
