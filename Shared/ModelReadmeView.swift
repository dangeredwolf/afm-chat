import SwiftUI
import MarkdownUI

struct ModelReadmeView: View {
    let model: HuggingFaceModelSummary

    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var markdown: String?
    @State private var details: HuggingFaceModelDetails?
    @State private var isLoadingReadme = true
    @State private var isLoadingDetails = true
    @State private var errorMessage: String?

    private var resolvedModel: HuggingFaceModelSummary {
        details?.summary ?? model
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataHeader
                readmeBody
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let download = downloads.item(for: model.id) {
                ModelDownloadProgressBlock(item: download)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModelHubDownloadButton(model: resolvedModel)
            }
        }
        .task {
            await loadAll()
        }
    }

    private var metadataHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.id)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if let lastModified = resolvedModel.lastModified {
                    Label(HuggingFaceModelDateFormat.updatedLabel(lastModified), systemImage: "clock")
                }
                if let sizeBytes = resolvedSize, sizeBytes > 0 {
                    Label(DownloadByteFormat.bytes(sizeBytes), systemImage: "internaldrive")
                } else if isLoadingDetails {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let details {
                NavigationLink {
                    ModelTechnicalDetailsView(details: details)
                } label: {
                    Label("Technical Details", systemImage: "info.circle")
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var readmeBody: some View {
        if isLoadingReadme && markdown == nil && errorMessage == nil {
            ProgressView("Loading README…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let errorMessage, markdown == nil {
            ContentUnavailableView {
                Label("Couldn't Load README", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    Task { await loadAll() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let markdown {
            Markdown(markdown)
                .markdownTextStyle(\.text) {
                    ForegroundColor(.primary)
                }
                .markdownTextStyle(\.link) {
                    ForegroundColor(.primary)
                    UnderlineStyle(.single)
                }
                .markdownTextStyle(\.code) {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                    ForegroundColor(.primary)
                    BackgroundColor(.primary.opacity(0.1))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView(
                "No README",
                systemImage: "doc.text",
                description: Text("This model doesn't have a README on Hugging Face.")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var resolvedSize: Int64? {
        if let size = details?.sizeBytes, size > 0 {
            return size
        }
        if let size = model.sizeBytes, size > 0 {
            return size
        }
        return nil
    }

    private func loadAll() async {
        async let readme: Void = loadReadme()
        async let meta: Void = loadDetails()
        _ = await (readme, meta)
    }

    private func loadReadme() async {
        if markdown == nil {
            isLoadingReadme = true
        }
        errorMessage = nil
        do {
            markdown = try await HuggingFaceModelCatalog.readme(id: model.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingReadme = false
    }

    private func loadDetails() async {
        if details == nil {
            isLoadingDetails = true
        }
        do {
            details = try await HuggingFaceModelCatalog.details(id: model.id)
        } catch is CancellationError {
            return
        } catch {
            // Metadata is optional; the README can still render without it.
        }
        isLoadingDetails = false
    }
}
