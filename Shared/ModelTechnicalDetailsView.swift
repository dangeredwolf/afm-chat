import SwiftUI

struct ModelTechnicalDetailsView: View {
    let details: HuggingFaceModelDetails

    var body: some View {
        List {
            if hasSummaryRows {
                Section {
                    if let lastModified = details.summary.lastModified {
                        LabeledContent("Updated", value: HuggingFaceModelDateFormat.absolute(lastModified))
                    }
                    if let createdAt = details.summary.createdAt {
                        LabeledContent("Created", value: HuggingFaceModelDateFormat.absolute(createdAt))
                    }
                    if details.sizeBytes > 0 {
                        LabeledContent("Size", value: DownloadByteFormat.bytes(details.sizeBytes))
                    }
                    if let parameterCountText = details.parameterCountText {
                        LabeledContent("Parameters", value: parameterCountText)
                    }
                    if !details.tensorTypes.isEmpty {
                        LabeledContent("Tensor types", value: details.tensorTypes.joined(separator: " · "))
                    }
                    if let modelType = details.modelType, !modelType.isEmpty {
                        LabeledContent("Model type", value: modelType)
                    }
                    if !details.architectures.isEmpty {
                        LabeledContent("Architecture", value: details.architectures.joined(separator: ", "))
                    }
                    if let license = details.license, !license.isEmpty {
                        LabeledContent("License", value: license)
                    }
                    if let pipelineTag = details.summary.pipelineTag, !pipelineTag.isEmpty {
                        LabeledContent("Pipeline", value: pipelineTag)
                    }
                    if let libraryName = details.libraryName, !libraryName.isEmpty {
                        LabeledContent("Library", value: libraryName)
                    }
                }
            }

            if !details.files.isEmpty {
                Section {
                    ForEach(details.files, id: \.path) { file in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(file.path)
                                .font(.subheadline)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(DownloadByteFormat.bytes(file.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Files")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let weightsSubpath = details.weightsSubpath {
                            Text("Using \(weightsSubpath) weights.")
                        }
                        Text("\(details.files.count) files · \(DownloadByteFormat.bytes(details.sizeBytes))")
                    }
                }
            }
        }
        .navigationTitle("Technical Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasSummaryRows: Bool {
        details.summary.lastModified != nil
            || details.summary.createdAt != nil
            || details.sizeBytes > 0
            || details.parameterCountText != nil
            || !details.tensorTypes.isEmpty
            || !(details.modelType ?? "").isEmpty
            || !details.architectures.isEmpty
            || !(details.license ?? "").isEmpty
            || !(details.summary.pipelineTag ?? "").isEmpty
            || !(details.libraryName ?? "").isEmpty
    }
}
