import SwiftUI

struct ContextUsageIndicator: View {
    let usage: LLMContextUsage
    let contextWindowSizes: [LLMModelChoice: Int]
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            ContextUsageRing(fraction: usage.fillFraction)
                .accessibilityLabel("Context usage")
                .accessibilityValue(accessibilityValue)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            ContextUsageDetailsView(
                usage: usage,
                contextWindowSizes: contextWindowSizes
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var accessibilityValue: String {
        "\(usage.usedTokens) of \(usage.contextLimit) tokens used"
    }
}

private struct ContextUsageRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: fraction)
        }
        .frame(width: 22, height: 22)
    }

    private var ringColor: Color {
        if fraction >= 0.95 {
            return .red
        }
        if fraction >= 0.8 {
            return .orange
        }
        return .accentColor
    }
}

private struct ContextUsageDetailsView: View {
    let usage: LLMContextUsage
    let contextWindowSizes: [LLMModelChoice: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Context Usage")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                detailRow("Used", value: formattedTokenCount(usage.usedTokens))
                detailRow("Remaining", value: formattedTokenCount(usage.remainingTokens))
                detailRow("Limit", value: formattedTokenCount(usage.contextLimit))
                detailRow("Model", value: usage.model.displayName)
            }

            if !contextWindowSizes.isEmpty {
                Divider()

                Text("Context Windows")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(sortedContextWindowEntries, id: \.model.id) { entry in
                    HStack {
                        Text(entry.model.displayName)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formattedTokenCount(entry.limit))
                            .fontWeight(entry.model == usage.model ? .semibold : .regular)
                    }
                    .font(.caption)
                }
            }

            if usage.inputTokens > 0 || usage.outputTokens > 0 || usage.reasoningTokens > 0 {
                Divider()

                Text("Breakdown")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 6) {
                    if usage.inputTokens > 0 {
                        detailRow("Input", value: formattedTokenCount(usage.inputTokens), compact: true)
                    }
                    if usage.outputTokens > 0 {
                        detailRow("Output", value: formattedTokenCount(usage.outputTokens), compact: true)
                    }
                    if usage.reasoningTokens > 0 {
                        detailRow("Reasoning", value: formattedTokenCount(usage.reasoningTokens), compact: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 240)
    }

    private var sortedContextWindowEntries: [(model: LLMModelChoice, limit: Int)] {
        contextWindowSizes
            .map { (model: $0.key, limit: $0.value) }
            .sorted { lhs, rhs in
                if lhs.model == .onDevice { return true }
                if rhs.model == .onDevice { return false }
                return lhs.model.displayName < rhs.model.displayName
            }
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String, compact: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(compact ? .regular : .medium)
        }
        .font(compact ? .caption : .subheadline)
    }

    private func formattedTokenCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }
}
