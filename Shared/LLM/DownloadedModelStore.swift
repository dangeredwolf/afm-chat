import Foundation
internal import Combine

#if AFM_MLX
import HuggingFace
#endif

nonisolated struct DownloadedMLXModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var pipelineTag: String?
    var sizeBytes: Int64?
    var weightsSubpath: String?
    var downloadedAt: Date

    init(
        id: String,
        displayName: String,
        pipelineTag: String? = nil,
        sizeBytes: Int64? = nil,
        weightsSubpath: String? = nil,
        downloadedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.pipelineTag = pipelineTag
        self.sizeBytes = sizeBytes
        self.weightsSubpath = weightsSubpath
        self.downloadedAt = downloadedAt
    }

    var author: String {
        String(id.split(separator: "/").first ?? "")
    }
}

enum HuggingFaceCache {
    nonisolated static var hubDirectory: URL {
        #if AFM_MLX
        return HubCache.default.cacheDirectory
        #else
        var candidates = [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("huggingface/hub", isDirectory: true)
        ]
        #if os(macOS) || targetEnvironment(macCatalyst)
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        )
        #endif
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        return candidates[0]
        #endif
    }

    nonisolated static func repoDirectory(for id: String) -> URL {
        #if AFM_MLX
        if let repo = Repo.ID(rawValue: id) {
            return HubCache.default.repoDirectory(repo: repo, kind: .model)
        }
        #endif
        let folder = "models--" + id.replacingOccurrences(of: "/", with: "--")
        return hubDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    nonisolated static func snapshotDirectory(for id: String) -> URL? {
        #if AFM_MLX
        if let repo = Repo.ID(rawValue: id) {
            let cache = HubCache.default
            if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
               let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit) {
                return snapshot
            }
        }
        #endif
        let snapshots = repoDirectory(for: id).appendingPathComponent("snapshots", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries.first
    }

    nonisolated static func isDownloaded(_ id: String) -> Bool {
        hasModelWeights(id)
    }

    nonisolated static func weightsDirectory(for id: String, preferredSubpath: String? = nil) -> URL? {
        guard let snapshot = snapshotDirectory(for: id) else { return nil }
        if let preferredSubpath, !preferredSubpath.isEmpty {
            return snapshot.appendingPathComponent(preferredSubpath, isDirectory: true)
        }
        if let subpath = resolvedWeightsSubpath(for: id) {
            return snapshot.appendingPathComponent(subpath, isDirectory: true)
        }
        return snapshot
    }

    nonisolated static func resolvedWeightsSubpath(for id: String) -> String? {
        if let stored = DownloadedModelStore.weightsSubpath(for: id), !stored.isEmpty {
            return stored
        }
        guard let snapshot = snapshotDirectory(for: id) else { return nil }
        return inferredWeightsSubpath(in: snapshot)
    }

    nonisolated static func inferredWeightsSubpath(in snapshot: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let dirNames = entries.compactMap { url -> String? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url.lastPathComponent : nil
        }

        func firstMatch(_ pred: (String) -> Bool) -> String? {
            dirNames
                .filter { pred($0.lowercased()) }
                .sorted { $0.count < $1.count }
                .first { directoryHasWeights(snapshot.appendingPathComponent($0, isDirectory: true)) }
        }

        if let fourBit = firstMatch({
            ($0.hasPrefix("mlx") || $0.contains("4bit") || $0.contains("4-bit"))
                && ($0.contains("4bit") || $0.contains("4-bit"))
        }) {
            return fourBit
        }
        if let eightBit = firstMatch({
            ($0.hasPrefix("mlx") || $0.contains("8bit") || $0.contains("8-bit"))
                && ($0.contains("8bit") || $0.contains("8-bit"))
        }) {
            return eightBit
        }
        if dirNames.contains("mlx"),
           directoryHasWeights(snapshot.appendingPathComponent("mlx", isDirectory: true)) {
            return "mlx"
        }
        return firstMatch { $0 == "mlx" || $0.hasPrefix("mlx-") || $0.hasPrefix("mlx_") }
    }

    nonisolated static func directoryHasWeights(_ directory: URL) -> Bool {
        let configExists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path
        )
        guard configExists else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.contains { $0.pathExtension == "safetensors" }
    }

    nonisolated static func modelType(for id: String) -> String? {
        guard let object = configJSON(for: id) else { return nil }
        return object["model_type"] as? String
    }

    nonisolated private static func configJSON(for id: String) -> [String: Any]? {
        guard let directory = weightsDirectory(for: id) else { return nil }
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    nonisolated static func contextSize(for id: String) -> Int? {
        guard let object = configJSON(for: id) else { return nil }

        let keys = [
            "max_position_embeddings",
            "max_sequence_length",
            "model_max_length",
            "max_seq_len"
        ]
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    nonisolated static func remove(_ id: String) throws {
        let directory = repoDirectory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated static func hasModelWeights(_ id: String) -> Bool {
        guard let directory = weightsDirectory(for: id) else { return false }
        return directoryHasWeights(directory)
    }

    nonisolated static func cachedFileExists(id: String, filename: String) -> Bool {
        #if AFM_MLX
        if let repo = Repo.ID(rawValue: id),
           HubCache.default.cachedFilePath(
            repo: repo,
            kind: .model,
            revision: "main",
            filename: filename
           ) != nil {
            return true
        }
        #endif
        guard let snapshot = snapshotDirectory(for: id) else { return false }
        return FileManager.default.fileExists(
            atPath: snapshot.appendingPathComponent(filename).path
        )
    }

    nonisolated static func removeIncompleteBlobs(for id: String) {
        _ = removeMatchingFiles(in: repoDirectory(for: id)) { url in
            isIncompleteDownload(url)
        }
    }

    nonisolated static func removeStaleLocks(for id: String) {
        _ = removeMatchingFiles(in: repoDirectory(for: id)) { url in
            isLockFile(url)
        }
        let lockRoot = hubDirectory
            .appendingPathComponent(".locks", isDirectory: true)
        let folder = "models--" + id.replacingOccurrences(of: "/", with: "--")
        _ = removeMatchingFiles(in: lockRoot.appendingPathComponent(folder, isDirectory: true)) { url in
            isLockFile(url)
        }
    }

    /// Removes leftover transfer files, abandoned repos, and unreferenced blobs.
    /// Call only when no downloads are running. `retainPartialIDs` keeps failed
    /// items so a retry can reuse completed shards.
    nonisolated static func purgeUnfinishedDownloads(
        installedIDs: Set<String>,
        retainPartialIDs: Set<String>,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Int64 {
        var reclaimed: Int64 = 0
        guard !isCancelled() else { return 0 }
        reclaimed += purgeTemporaryDownloads()
        reclaimed += removeMatchingFiles(in: hubDirectory) { url in
            isIncompleteDownload(url) || isLockFile(url)
        }

        let repos = modelRepoDirectories()
        for repoURL in repos {
            if isCancelled() { return reclaimed }
            let folder = repoURL.lastPathComponent
            guard let id = modelID(fromCacheFolder: folder) else { continue }
            if installedIDs.contains(id) {
                reclaimed += pruneUnusedWeightVariants(for: id)
                reclaimed += purgeUnreferencedBlobs(in: repoURL)
                continue
            }
            if retainPartialIDs.contains(id) {
                reclaimed += purgeUnreferencedBlobs(in: repoURL)
                continue
            }
            ModelDownloadLog.info("purging abandoned download \(id)")
            reclaimed += removeItemReclaiming(at: repoURL)
            reclaimed += removeItemReclaiming(
                at: hubDirectory.appendingPathComponent(".locks/\(folder)", isDirectory: true)
            )
            reclaimed += removeItemReclaiming(
                at: hubDirectory.appendingPathComponent(".metadata/\(folder)", isDirectory: true)
            )
        }
        return reclaimed
    }

    nonisolated private static func modelRepoDirectories() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: hubDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        return entries.filter { url in
            url.lastPathComponent.hasPrefix("models--")
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }

    nonisolated private static func modelID(fromCacheFolder name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let rest = String(name.dropFirst("models--".count))
        guard let separator = rest.range(of: "--") else { return nil }
        let namespace = String(rest[..<separator.lowerBound])
        let repo = String(rest[separator.upperBound...])
        guard !namespace.isEmpty, !repo.isEmpty else { return nil }
        return "\(namespace)/\(repo)"
    }

    nonisolated private static func pruneUnusedWeightVariants(for id: String) -> Int64 {
        guard let snapshot = snapshotDirectory(for: id),
              let keepSubpath = resolvedWeightsSubpath(for: id),
              !keepSubpath.isEmpty else {
            return 0
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return 0
        }

        var reclaimed: Int64 = 0
        for url in entries {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard name != keepSubpath else { continue }
                if directoryHasWeights(url) || looksLikeWeightVariantDirectory(name) {
                    ModelDownloadLog.info("purging unused variant \(id)/\(name)")
                    reclaimed += removeItemReclaiming(at: url)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "safetensors" || ext == "gguf" || ext == "bin" {
                reclaimed += removeItemReclaiming(at: url)
            }
        }
        return reclaimed
    }

    nonisolated private static func looksLikeWeightVariantDirectory(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("mlx")
            || lowered.contains("gguf")
            || lowered.contains("4bit")
            || lowered.contains("4-bit")
            || lowered.contains("8bit")
            || lowered.contains("8-bit")
            || lowered.contains("fp16")
            || lowered.contains("bf16")
    }

    nonisolated private static func purgeUnreferencedBlobs(in repoDirectory: URL) -> Int64 {
        let blobs = repoDirectory.appendingPathComponent("blobs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: blobs.path) else { return 0 }
        let referenced = referencedBlobNames(in: repoDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return 0
        }
        var reclaimed: Int64 = 0
        for url in files {
            if referenced.contains(url.lastPathComponent) { continue }
            reclaimed += removeItemReclaiming(at: url)
        }
        return reclaimed
    }

    nonisolated private static func referencedBlobNames(in repoDirectory: URL) -> Set<String> {
        let snapshots = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard FileManager.default.fileExists(atPath: snapshots.path),
              let enumerator = FileManager.default.enumerator(
                at: snapshots,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
              ) else {
            return []
        }
        var names = Set<String>()
        for case let fileURL as URL in enumerator {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) else {
                continue
            }
            let resolved = URL(fileURLWithPath: destination, relativeTo: fileURL.deletingLastPathComponent())
                .standardizedFileURL
            if resolved.path.contains("/blobs/") {
                names.insert(resolved.lastPathComponent)
            }
        }
        return names
    }

    nonisolated private static func purgeTemporaryDownloads() -> Int64 {
        let directories = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]
        var seen = Set<String>()
        var reclaimed: Int64 = 0
        for directory in directories {
            let path = directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []
            ) else {
                continue
            }
            for url in files where isTemporaryDownload(url) {
                reclaimed += removeItemReclaiming(at: url)
            }
        }
        return reclaimed
    }

    nonisolated private static func isTemporaryDownload(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("CFNetworkDownload")
            || name.hasSuffix(".download")
            || (name.hasSuffix(".tmp") && name.contains("CFNetwork"))
    }

    nonisolated private static func isIncompleteDownload(_ url: URL) -> Bool {
        url.pathExtension == "incomplete" || url.lastPathComponent.hasSuffix(".incomplete")
    }

    nonisolated private static func isLockFile(_ url: URL) -> Bool {
        url.pathExtension == "lock" || url.lastPathComponent.hasSuffix(".lock")
    }

    nonisolated private static func removeMatchingFiles(in directory: URL, match: (URL) -> Bool) -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
              ) else {
            return 0
        }
        var reclaimed: Int64 = 0
        for case let fileURL as URL in enumerator where match(fileURL) {
            reclaimed += removeItemReclaiming(at: fileURL)
        }
        return reclaimed
    }

    nonisolated private static func removeItemReclaiming(at url: URL) -> Int64 {
        let size = sizeOfItem(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        do {
            try FileManager.default.removeItem(at: url)
            return size
        } catch {
            ModelDownloadLog.info("purge failed \(url.lastPathComponent): \(error.localizedDescription)")
            return 0
        }
    }

    nonisolated private static func sizeOfItem(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        if values?.isRegularFile == true {
            return Int64(values?.fileSize ?? 0)
        }
        guard values?.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
              ) else {
            return Int64(values?.fileSize ?? 0)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard fileValues?.isRegularFile == true else { continue }
            total += Int64(fileValues?.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func downloadedByteCount(for id: String) -> Int64? {
        let directory = repoDirectory(for: id)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total > 0 ? total : nil
    }
}

@MainActor
final class DownloadedModelStore: ObservableObject {
    static let shared = DownloadedModelStore()

    private static let defaultsKey = "downloadedMLXModels"

    @Published private(set) var models: [DownloadedMLXModel] = []

    private init() {
        models = Self.loadStoredModels().filter { HuggingFaceCache.isDownloaded($0.id) }
        persist()
    }

    nonisolated static func storedModels() -> [DownloadedMLXModel] {
        loadStoredModels().filter { HuggingFaceCache.isDownloaded($0.id) }
    }

    nonisolated static func pipelineTag(for id: String) -> String? {
        storedModels().first(where: { $0.id == id })?.pipelineTag
    }

    nonisolated static func weightsSubpath(for id: String) -> String? {
        loadStoredModels().first(where: { $0.id == id })?.weightsSubpath
    }

    func refresh() {
        models = Self.loadStoredModels().filter { HuggingFaceCache.isDownloaded($0.id) }
        persist()
    }

    func contains(_ id: String) -> Bool {
        models.contains { $0.id == id } && HuggingFaceCache.isDownloaded(id)
    }

    func add(_ model: DownloadedMLXModel) {
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        models.sort { $0.downloadedAt > $1.downloadedAt }
        persist()
    }

    func remove(_ id: String) async {
        ModelDownloadManager.shared.cancel(id)
        #if AFM_MLX
        await MLXRuntime.shared.unload(id)
        #endif
        try? HuggingFaceCache.remove(id)
        models.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    nonisolated private static func loadStoredModels() -> [DownloadedMLXModel] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let models = try? JSONDecoder().decode([DownloadedMLXModel].self, from: data) else {
            return []
        }
        return models
    }
}
