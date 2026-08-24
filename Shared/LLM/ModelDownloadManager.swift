import Foundation
import SwiftUI
internal import Combine

enum ModelDownloadStatus: Equatable {
    case queued
    case downloading
    case loading
    case failed(String)
}

struct ModelDownloadItem: Identifiable, Equatable {
    let id: String
    var displayName: String
    var pipelineTag: String?
    var tags: [String]
    var status: ModelDownloadStatus
    var completedBytes: Int64
    var totalBytes: Int64
    var throughputBytesPerSec: Double?
    var currentFileName: String?

    var isInFlight: Bool {
        switch status {
        case .queued, .downloading, .loading: return true
        case .failed: return false
        }
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        let raw = Double(completedBytes) / Double(totalBytes)
        return min(1, max(0, raw))
    }

    var statusText: String {
        switch status {
        case .queued:
            return "Queued"
        case .downloading:
            var parts: [String] = []
            if let percentText {
                parts.append(percentText)
            }
            if !sizeText.isEmpty {
                parts.append(sizeText)
            }
            if let currentFileName {
                parts.append(currentFileName)
            }
            if parts.isEmpty {
                return "Connecting…"
            }
            return parts.joined(separator: " · ")
        case .loading:
            return "Preparing model…"
        case .failed(let message):
            return message
        }
    }

    var sizeText: String {
        DownloadByteFormat.progress(completed: completedBytes, total: totalBytes, downloading: status == .downloading)
    }

    var percentText: String? {
        guard status == .downloading, totalBytes > 0, completedBytes > 0 else { return nil }
        let percent = Double(completedBytes) / Double(totalBytes) * 100
        if percent < 1 {
            return "<1%"
        }
        if percent >= 99.5, completedBytes < totalBytes {
            return String(format: "%.1f%%", min(99.9, percent))
        }
        return "\(min(99, Int(percent.rounded())))%"
    }

    var speedText: String? {
        guard status == .downloading else { return nil }
        return DownloadByteFormat.speed(throughputBytesPerSec)
    }
}

enum DownloadByteFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        formatter.string(fromByteCount: max(0, value))
    }

    static func progress(completed: Int64, total: Int64, downloading: Bool) -> String {
        if total > 0, completed >= total, downloading {
            return "\(bytes(completed))+ downloaded"
        }
        if total > 0 {
            let remaining = max(0, total - completed)
            let completedText = bytes(completed)
            let totalText = bytes(total)
            if remaining > 0, remaining < 150_000_000 || completedText == totalText {
                return "\(completedText) of \(totalText) · \(bytes(remaining)) left"
            }
            return "\(completedText) of \(totalText)"
        }
        if completed > 0 {
            return "\(bytes(completed)) downloaded"
        }
        return ""
    }

    static func speed(_ bytesPerSec: Double?) -> String? {
        guard let bytesPerSec, bytesPerSec >= 1024 else { return nil }
        return bytes(Int64(bytesPerSec.rounded())) + "/s"
    }
}

enum ModelMemoryFit {
    static let warningRatio = 0.9

    static var deviceMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static func shouldWarn(modelBytes: Int64?) -> Bool {
        guard let modelBytes, modelBytes > 0 else { return false }
        let ram = deviceMemoryBytes
        guard ram > 0 else { return false }
        return Double(modelBytes) > Double(ram) * warningRatio
    }

    static func warningMessage(modelBytes: Int64) -> String {
        let model = DownloadByteFormat.bytes(modelBytes)
        let ram = DownloadByteFormat.bytes(Int64(clamping: deviceMemoryBytes))
        return "This model is about \(model), which is more than 80% of this device's \(ram) of memory. It may run slowly or fail to load."
    }
}

enum ModelStorageFit {
    static var availableBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else {
            return 0
        }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        return 0
    }

    static func shouldWarn(modelBytes: Int64?) -> Bool {
        guard let modelBytes, modelBytes > 0 else { return false }
        let available = availableBytes
        guard available > 0 else { return false }
        return modelBytes > available
    }

    static func warningMessage(modelBytes: Int64) -> String {
        let model = DownloadByteFormat.bytes(modelBytes)
        let available = DownloadByteFormat.bytes(availableBytes)
        return "This model is about \(model), which is larger than this device's \(available) of available storage. The download may fail."
    }
}

@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    @Published private(set) var items: [ModelDownloadItem] = []

    private var tasks: [String: Task<Void, Never>] = [:]
    private var smoother = DownloadProgressSmoother()
    private var activeID: String?
    private var purgeTask: Task<Void, Never>?
    private var purgeToken: DownloadPurgeToken?

    private init() {
        #if AFM_MLX
        schedulePurgeIfIdle()
        #endif
    }

    var hasActiveDownloads: Bool {
        items.contains(where: \.isInFlight)
    }

    var primaryItem: ModelDownloadItem? {
        items.first(where: { $0.status == .downloading || $0.status == .loading })
            ?? items.first(where: { $0.status == .queued })
    }

    func item(for id: String) -> ModelDownloadItem? {
        items.first(where: { $0.id == id })
    }

    func isInFlight(_ id: String) -> Bool {
        item(for: id)?.isInFlight == true
    }

    func enqueue(_ model: HuggingFaceModelSummary) {
        #if AFM_MLX
        guard !DownloadedModelStore.shared.contains(model.id) else { return }
        guard !isInFlight(model.id) else { return }

        items.removeAll { $0.id == model.id }
        items.append(
            ModelDownloadItem(
                id: model.id,
                displayName: model.name,
                pipelineTag: model.pipelineTag,
                tags: model.tags,
                status: .queued,
                completedBytes: 0,
                totalBytes: max(0, model.sizeBytes ?? 0),
                throughputBytesPerSec: nil,
                currentFileName: nil
            )
        )
        resolveExpectedSize(for: model.id, fallback: model.sizeBytes)
        startNextIfNeeded()
        #else
        _ = model
        #endif
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        items.removeAll { $0.id == id }
        if activeID == id {
            activeID = nil
            smoother.reset()
        }
        #if AFM_MLX
        startNextIfNeeded()
        #endif
    }

    func retry(_ id: String) {
        guard let item = item(for: id), case .failed = item.status else { return }
        enqueue(
            HuggingFaceModelSummary(
                id: item.id,
                downloads: 0,
                likes: 0,
                pipelineTag: item.pipelineTag,
                tags: item.tags,
                createdAt: nil,
                trendingScore: nil,
                sizeBytes: item.totalBytes > 0 ? item.totalBytes : nil
            )
        )
    }

    #if AFM_MLX
    private func startNextIfNeeded() {
        guard activeID == nil else { return }
        guard let next = items.first(where: { $0.status == .queued }) else {
            schedulePurgeIfIdle()
            return
        }

        activeID = next.id
        smoother.reset()
        purgeToken?.cancel()
        update(next.id) { item in
            item.status = .downloading
            item.completedBytes = 0
            item.throughputBytesPerSec = nil
            item.currentFileName = nil
        }
        tasks[next.id] = Task { [weak self] in
            await self?.runDownload(next)
        }
    }

    private func runDownload(_ item: ModelDownloadItem) async {
        guard #available(iOS 27, *) else {
            fail(item.id, message: "Custom models require iOS 27 or later.")
            return
        }

        do {
            try Task.checkCancellation()
            let modelID = item.id
            let downloadTask = Task.detached(priority: .utility) {
                try await MLXModelFactory.downloadWeights(id: modelID) { completed, total, fileName in
                    Task { @MainActor in
                        ModelDownloadManager.shared.applyProgress(
                            id: modelID,
                            completed: completed,
                            total: total,
                            fileName: fileName
                        )
                    }
                }
            }
            let weightsSubpath = try await withTaskCancellationHandler {
                try await downloadTask.value
            } onCancel: {
                downloadTask.cancel()
            }
            try Task.checkCancellation()

            let stored = DownloadedMLXModel(
                id: item.id,
                displayName: item.displayName,
                pipelineTag: item.pipelineTag,
                sizeBytes: resolvedSize(for: item.id),
                weightsSubpath: weightsSubpath
            )
            DownloadedModelStore.shared.add(stored)

            finish(item.id)
        } catch is CancellationError {
            if activeID == item.id {
                activeID = nil
            }
            tasks[item.id] = nil
            startNextIfNeeded()
        } catch {
            fail(item.id, message: error.localizedDescription)
        }
    }

    private func finish(_ id: String) {
        items.removeAll { $0.id == id }
        tasks[id] = nil
        if activeID == id {
            activeID = nil
            smoother.reset()
        }
        startNextIfNeeded()
    }

    private func fail(_ id: String, message: String) {
        update(id) { item in
            item.status = .failed(message)
            item.throughputBytesPerSec = nil
        }
        tasks[id] = nil
        if activeID == id {
            activeID = nil
            smoother.reset()
        }
        startNextIfNeeded()
    }

    private func resolveExpectedSize(for id: String, fallback: Int64?) {
        Task { [weak self] in
            let fetched = await HuggingFaceModelCatalog.repositorySize(id: id)
            let size = fetched ?? fallback
            guard let self, let size, size > 0 else { return }
            self.update(id) { item in
                item.totalBytes = max(item.totalBytes, size)
            }
        }
    }

    private func resolvedSize(for id: String) -> Int64? {
        if let item = item(for: id), item.totalBytes > 0 {
            return item.totalBytes
        }
        return HuggingFaceCache.downloadedByteCount(for: id)
    }

    private func schedulePurgeIfIdle() {
        purgeToken?.cancel()
        let token = DownloadPurgeToken()
        purgeToken = token
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, !self.hasActiveDownloads, !token.isCancelled else { return }
            let installed = Set(DownloadedModelStore.shared.models.map(\.id))
            let retainPartial = Set(self.items.map(\.id))
            let reclaimed = await Task.detached(priority: .utility) {
                HuggingFaceCache.purgeUnfinishedDownloads(
                    installedIDs: installed,
                    retainPartialIDs: retainPartial,
                    isCancelled: { token.isCancelled }
                )
            }.value
            guard !token.isCancelled, reclaimed > 0 else { return }
            ModelDownloadLog.info("purged unfinished downloads \(DownloadByteFormat.bytes(reclaimed))")
        }
    }

    func applyProgress(id: String, completed: Int64, total: Int64, fileName: String? = nil) {
        guard id == activeID else { return }
        let snapshot = smoother.ingest(
            completed: completed,
            total: total,
            fraction: total > 0 ? Double(completed) / Double(total) : 0,
            expectedTotal: item(for: id)?.totalBytes
        )
        update(id) { item in
            item.completedBytes = snapshot.completed
            if snapshot.total > 0 {
                item.totalBytes = snapshot.total
            }
            item.throughputBytesPerSec = snapshot.rate
            item.status = .downloading
            if let fileName {
                item.currentFileName = fileName
            }
        }
    }
    #endif

    private func update(_ id: String, mutate: (inout ModelDownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        mutate(&item)
        guard item != items[index] else { return }
        items[index] = item
    }
}

nonisolated private final class DownloadPurgeToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

private struct DownloadProgressSmoother {
    private var maxCompleted: Int64 = 0
    private var maxTotal: Int64 = 0
    private var samples: [(time: Date, bytes: Int64)] = []
    private var lastPositiveRate: Double?
    private var startedAt: Date?

    private let window: TimeInterval = 8

    mutating func reset() {
        maxCompleted = 0
        maxTotal = 0
        samples.removeAll()
        lastPositiveRate = nil
        startedAt = nil
    }

    mutating func ingest(
        completed: Int64,
        total: Int64,
        fraction _: Double,
        expectedTotal: Int64?
    ) -> (completed: Int64, total: Int64, rate: Double?) {
        if startedAt == nil {
            startedAt = Date()
        }

        var nextTotal = max(maxTotal, expectedTotal ?? 0)
        if total > 0 {
            let reportedLooksLikePointers =
                nextTotal > 1_000_000 && total < nextTotal / 50
            if !reportedLooksLikePointers {
                nextTotal = max(nextTotal, total)
            }
        }

        var nextCompleted = max(0, completed)
        if nextCompleted + 1_048_576 < maxCompleted {
            maxCompleted = nextCompleted
            samples.removeAll()
            lastPositiveRate = nil
        } else if nextCompleted >= maxCompleted {
            maxCompleted = nextCompleted
        }
        // Catalog sizes are a lower bound. If observed bytes pass the estimate,
        // grow the total instead of pinning the bar at 100%.
        if maxCompleted > nextTotal {
            nextTotal = maxCompleted
        }
        maxTotal = nextTotal

        let now = Date()
        samples.append((now, maxCompleted))
        let cutoff = now.addingTimeInterval(-window)
        samples.removeAll { $0.time < cutoff }

        var rate: Double?
        if let oldest = samples.first, let newest = samples.last, samples.count >= 2 {
            let dt = newest.time.timeIntervalSince(oldest.time)
            let db = newest.bytes - oldest.bytes
            if dt >= 0.8, db > 0 {
                rate = Double(db) / dt
                lastPositiveRate = rate
            }
        }
        if rate == nil, let lastPositiveRate, lastPositiveRate >= 1024,
           let lastSample = samples.last, now.timeIntervalSince(lastSample.time) < 1.2 {
            rate = lastPositiveRate
        }
        if let current = rate, current < 1024 {
            rate = nil
        }

        return (maxCompleted, maxTotal, rate)
    }
}

struct ModelDownloadProgressBlock: View {
    let item: ModelDownloadItem
    var showsCancel: Bool = true
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.statusText)
                    .foregroundStyle(statusColor)
                Spacer(minLength: 8)
                if let speed = item.speedText {
                    Text(speed)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if showsCancel, item.isInFlight {
                    Button(role: .cancel) {
                        (onCancel ?? { ModelDownloadManager.shared.cancel(item.id) })()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel download")
                }
            }
            .font(.caption2)

            if item.isInFlight {
                ProgressView(value: item.totalBytes > 0 ? item.fractionCompleted : nil)
                    .progressViewStyle(.linear)
            }
        }
    }

    private var statusColor: Color {
        if case .failed = item.status {
            return .orange
        }
        return .secondary
    }
}

struct ModelDownloadBanner: View {
    @ObservedObject private var downloads = ModelDownloadManager.shared
    var onOpen: () -> Void

    var body: some View {
        if let item = downloads.primaryItem {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.tint)
                            Text(item.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if let speed = item.speedText {
                                Text(speed)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else if item.status == .queued {
                                Text("Queued")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if item.isInFlight {
                        Button {
                            downloads.cancel(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel download")
                    }
                }

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 6) {
                        if item.totalBytes > 0 || item.completedBytes > 0 {
                            ProgressView(value: item.totalBytes > 0 ? item.fractionCompleted : nil)
                                .progressViewStyle(.linear)
                        }

                        HStack {
                            Text(item.statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if queuedCount > 0 {
                                Spacer(minLength: 8)
                                Text("\(queuedCount) queued")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Model download")
            .accessibilityValue(item.statusText)
            .accessibilityHint("Opens the model picker")
        }
    }

    private var queuedCount: Int {
        downloads.items.filter { $0.status == .queued }.count
    }
}
