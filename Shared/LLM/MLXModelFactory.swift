import Foundation
import FoundationModels
import os

#if AFM_MLX
import HuggingFace
#if canImport(MLX)
import MLX
#endif
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

nonisolated enum ModelDownloadLog {
    private static let logger = Logger(
        subsystem: "afm-chat",
        category: "ModelDownload"
    )

    nonisolated static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[ModelDownload] \(message)")
    }
}

enum MLXModelFactory {
    #if AFM_MLX
    @available(iOS 27, *)
    static func makeLanguageModel(
        id: String,
        pipelineTag: String? = nil,
        tags: [String] = []
    ) -> MLXLanguageModel {
        // Linking these modules registers LLM/VLM trampoline factories.
        _ = LLMModelFactory.shared
        _ = VLMModelFactory.shared

        let media = HuggingFaceModelCatalog.mediaCapabilities(
            id: id,
            pipelineTag: pipelineTag,
            tags: tags
        )
        // Gemma 4's VLM `gemma4PrepareTextOnly` crashes in Metal Gather/setBytes
        // during text prefill. Load the text backbone through LLMModelFactory.
        let useVLM = media.vision && !HuggingFaceModelCatalog.looksLikeGemma4(id: id)

        var capabilities: [LanguageModelCapabilities.Capability] = [
            .toolCalling,
            .guidedGeneration
        ]
        if useVLM {
            capabilities.append(.vision)
        }
        capabilities.append(.reasoning)

        let configuration = resolvedConfiguration(id: id, preferVision: useVLM)
        let loadWithVLM = useVLM

        configureDeviceMemoryLimits()

        return MLXLanguageModel(
            configuration: configuration,
            capabilities: capabilities,
            weightsLocation: hubWeightsLocation,
            load: { configuration, progressHandler in
                let factory: any ModelFactory =
                    loadWithVLM ? VLMModelFactory.shared : LLMModelFactory.shared
                return try await factory.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { progress in
                        progressHandler(progress)
                        LoadProgressBridge.report(fraction: progress.fractionCompleted)
                    }
                )
            }
        )
    }

    @available(iOS 27, *)
    static func preload(id: String, pipelineTag: String? = nil, tags: [String] = []) async throws {
        try await makeLanguageModel(id: id, pipelineTag: pipelineTag, tags: tags).preload()
    }

    @available(iOS 27, *)
    static func evict(id: String, pipelineTag: String? = nil) async {
        await makeLanguageModel(id: id, pipelineTag: pipelineTag).evict()
        clearGPUBufferCache()
    }

    @available(iOS 27, *)
    static func evictAllResidentWeights() async {
        await MLXLanguageModel.evictAll()
        clearGPUBufferCache()
    }

    private static func clearGPUBufferCache() {
        #if canImport(MLX)
        MLX.Memory.clearCache()
        #endif
    }

    /// iOS jetsam is far below Metal's recommended working set. Keep MLX's
    /// recycled-buffer cache small so load/inference stay under the watermark.
    private static let memoryConfigLock = NSLock()
    nonisolated(unsafe) private static var didConfigureDeviceMemoryLimits = false

    private static func configureDeviceMemoryLimits() {
        memoryConfigLock.lock()
        defer { memoryConfigLock.unlock() }
        guard !didConfigureDeviceMemoryLimits else { return }
        didConfigureDeviceMemoryLimits = true

        #if canImport(MLX) && os(iOS) && !targetEnvironment(macCatalyst)
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let available = os_proc_available_memory()
        if available > 0 {
            MLX.Memory.memoryLimit = Int(Double(available) * 0.9)
        }
        #endif
    }

    /// Loads weights and runs a one-token forward pass so Metal shaders JIT before the first user turn.
    @available(iOS 27, *)
    nonisolated static func warmUp(
        id: String,
        pipelineTag: String? = nil,
        tags: [String] = [],
        displayName: String? = nil,
        onPhase: @escaping @Sendable (ChatGenerationPhase) -> Void
    ) async throws {
        let name = displayName ?? (id.split(separator: "/").last.map(String.init) ?? id)
        onPhase(.loadingModel(name: name, fraction: nil))
        LoadProgressBridge.setHandler { fraction in
            onPhase(.loadingModel(name: name, fraction: fraction < 1 ? fraction : nil))
        }
        defer { LoadProgressBridge.setHandler(nil) }

        let model = await makeLanguageModel(id: id, pipelineTag: pipelineTag, tags: tags)
        try await model.preload()

        onPhase(.compiling(name: name))
        let container = try await model.loadContainer()
        try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [MLXLMCommon.Chat.Message.user("warmup")])
            )
            for await _ in try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 1),
                context: context
            ) {}
        }
    }

    /// Downloads the selected MLX variant into the shared Hub cache without loading weights.
    /// Returns the weights subdirectory (`mlx-4bit`, etc.) when the variant is not at repo root.
    @available(iOS 27, *)
    nonisolated static func downloadWeights(
        id: String,
        onProgress: @escaping @Sendable (Int64, Int64, String?) -> Void
    ) async throws -> String? {
        guard let repo = Repo.ID(rawValue: id) else {
            throw URLError(.badURL)
        }

        HuggingFaceCache.removeStaleLocks(for: id)
        ModelDownloadLog.info("start \(id)")

        let session = makeDownloadSession()
        defer { session.finishTasksAndInvalidate() }
        let client = HubClient(session: session, userAgent: "afm-chat", cache: .default)

        let plan = try await HuggingFaceModelCatalog.downloadPlan(id: id)
        guard plan.files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw URLError(.cannotParseResponse)
        }

        let total = max(plan.totalBytes, 1)
        let alreadyCached = plan.files.filter { HuggingFaceCache.cachedFileExists(id: id, filename: $0.path) }
        let finishedBytes = alreadyCached.reduce(Int64(0)) { $0 + $1.size }
        onProgress(finishedBytes, total, nil)
        ModelDownloadLog.info(
            "plan \(id) files=\(plan.files.count) cached=\(alreadyCached.count) remaining=\(plan.files.count - alreadyCached.count) total=\(total) subpath=\(plan.weightsSubpath ?? "root")"
        )

        let remaining = plan.files.filter { file in
            !alreadyCached.contains(where: { $0.path == file.path })
        }

        if !remaining.isEmpty {
            let progress = DownloadByteProgress(
                finished: finishedBytes,
                total: total,
                queuedBytes: remaining.reduce(Int64(0)) { $0 + $1.size },
                onProgress: onProgress
            )
            let pump = Task.detached(priority: .utility) {
                await pumpSessionProgress(session: session, repoID: id, progress: progress)
            }
            do {
                try await downloadFiles(remaining, repo: repo, client: client, progress: progress)
                pump.cancel()
            } catch {
                pump.cancel()
                throw error
            }
        }

        let configPath = plan.weightsSubpath.map { "\($0)/config.json" } ?? "config.json"
        let hasConfig = HuggingFaceCache.cachedFileExists(id: id, filename: configPath)
        let hasWeights = plan.files.contains {
            $0.path.hasSuffix(".safetensors") && HuggingFaceCache.cachedFileExists(id: id, filename: $0.path)
        }
        guard hasConfig, hasWeights else {
            ModelDownloadLog.info("missing files after download config=\(hasConfig) weights=\(hasWeights)")
            throw URLError(.cannotOpenFile)
        }
        ModelDownloadLog.info("finished \(id)")
        return plan.weightsSubpath
    }

    @available(iOS 27, *)
    nonisolated private static func downloadFiles(
        _ files: [HuggingFaceRepositoryFile],
        repo: Repo.ID,
        client: HubClient,
        progress: DownloadByteProgress
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = files.makeIterator()
            let limit = min(2, files.count)
            for _ in 0..<limit {
                if let file = iterator.next() {
                    group.addTask {
                        try await downloadFileWithRetries(file, repo: repo, client: client, progress: progress)
                    }
                }
            }
            while try await group.next() != nil {
                if let file = iterator.next() {
                    group.addTask {
                        try await downloadFileWithRetries(file, repo: repo, client: client, progress: progress)
                    }
                }
            }
        }
    }

    @available(iOS 27, *)
    nonisolated private static func downloadFileWithRetries(
        _ file: HuggingFaceRepositoryFile,
        repo: Repo.ID,
        client: HubClient,
        progress: DownloadByteProgress
    ) async throws {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for attempt in 1...3 {
            try Task.checkCancellation()
            ModelDownloadLog.info("file \(file.path) attempt=\(attempt) size=\(file.size)")
            do {
                try await downloadSingleFile(file, repo: repo, client: client, progress: progress)
                await progress.finish(file.path, size: file.size)
                ModelDownloadLog.info("file \(file.path) complete")
                return
            } catch is CancellationError {
                try Task.checkCancellation()
                lastError = URLError(.timedOut)
                ModelDownloadLog.info("file \(file.path) cancelled/timed out, retrying")
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            } catch {
                lastError = error
                ModelDownloadLog.info("file \(file.path) error: \(error.localizedDescription)")
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
        }
        throw lastError
    }

    @available(iOS 27, *)
    nonisolated private static func downloadSingleFile(
        _ file: HuggingFaceRepositoryFile,
        repo: Repo.ID,
        client: HubClient,
        progress: DownloadByteProgress
    ) async throws {
        await progress.beginFile(file.path, expected: file.size)
        let fileProgress = FileProgressBox(total: file.size)
        let poll = Task.detached(priority: .utility) {
            var last: Int64 = -1
            var loggedFirstByte = false
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                let bytes = fileProgress.completed
                if bytes != last {
                    last = bytes
                    await progress.setInflight(file.path, bytes: bytes, expected: file.size)
                    if !loggedFirstByte, bytes >= 65_536 {
                        loggedFirstByte = true
                        ModelDownloadLog.info("file \(file.path) first progress byte=\(bytes)")
                    }
                }
            }
        }
        do {
            _ = try await client.downloadFile(
                at: file.path,
                from: repo,
                progress: fileProgress.value,
                transport: .lfs
            )
            poll.cancel()
        } catch {
            poll.cancel()
            throw error
        }
    }

    nonisolated private static func pumpSessionProgress(
        session: URLSession,
        repoID: String,
        progress: DownloadByteProgress
    ) async {
        var lastBytes: Int64 = -1
        var lastLog = Date.distantPast
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            let tasks = await session.allTasks.filter { $0.state == .running }
            let fromCount = tasks.reduce(Int64(0)) { partial, task in
                partial + Int64(task.countOfBytesReceived)
            }
            let fromTaskProgress = tasks.reduce(Int64(0)) { partial, task in
                let value = task.progress.completedUnitCount
                return looksLikeLFSPointer(value) ? partial : partial + value
            }
            let fromDisk = currentDiskDownloadBytes(repoID: repoID)
            let names = tasks.compactMap { task -> String? in
                guard let name = task.originalRequest?.url?.lastPathComponent, !name.isEmpty else {
                    return nil
                }
                return name
            }
            await progress.setObserved(
                sessionBytes: fromCount,
                diskBytes: fromDisk,
                fileNames: names
            )
            let received = max(fromCount, fromDisk)
            let now = Date()
            if received != lastBytes || now.timeIntervalSince(lastLog) >= 2 {
                lastBytes = received
                lastLog = now
                let ui = await progress.publishedBytes()
                ModelDownloadLog.info(
                    "live received=\(received) taskBytes=\(fromCount) taskProgress=\(fromTaskProgress) disk=\(fromDisk) ui=\(ui.completed)/\(ui.total) running=\(tasks.count) files=\(names.joined(separator: ","))"
                )
            }
        }
    }

    nonisolated private static func makeDownloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    nonisolated private static func currentDiskDownloadBytes(repoID: String) -> Int64 {
        currentDiskDownloadSizes(repoID: repoID).values.reduce(0, +)
    }

    nonisolated private static func currentDiskDownloadSizes(repoID: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        let directories = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            HuggingFaceCache.repoDirectory(for: repoID).appendingPathComponent("blobs", isDirectory: true)
        ]
        var seen = Set<String>()
        for directory in directories {
            let path = directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: directory.path),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: []
                  ) else {
                continue
            }
            for url in files {
                let name = url.lastPathComponent
                let isIncomplete = name.hasSuffix(".incomplete") || name.contains("incomplete")
                let looksLikeDownload =
                    name.hasPrefix("CFNetworkDownload")
                    || name.hasSuffix(".download")
                    || isIncomplete
                    || (name.hasSuffix(".tmp") && name.contains("CFNetwork"))
                guard looksLikeDownload else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                guard size > 0 else { continue }
                if isIncomplete {
                    let modified = values?.contentModificationDate ?? .distantPast
                    if modified < Date().addingTimeInterval(-6 * 60 * 60) {
                        continue
                    }
                }
                sizes[url.standardizedFileURL.path] = size
            }
        }
        return sizes
    }

    nonisolated private static func looksLikeLFSPointer(_ bytes: Int64) -> Bool {
        bytes > 0 && bytes < 65_536
    }

    private static func resolvedConfiguration(id: String, preferVision: Bool) -> ModelConfiguration {
        let localDirectory = HuggingFaceCache.weightsDirectory(for: id)
        var configuration: ModelConfiguration
        if HuggingFaceCache.hasModelWeights(id), let localDirectory {
            configuration = ModelConfiguration(directory: localDirectory)
        } else {
            configuration = ModelConfiguration(id: id)
        }
        if let known = knownConfiguration(matching: id, preferVision: preferVision) {
            configuration.extraEOSTokens = known.extraEOSTokens
            configuration.stopStrings = known.stopStrings
            configuration.toolCallFormat = known.toolCallFormat
            configuration.reasoningConfig = known.reasoningConfig
            configuration.messageGenerator = known.messageGenerator
        }
        if HuggingFaceModelCatalog.looksLikeGemma4(id: id) {
            if configuration.extraEOSTokens.isEmpty {
                configuration.extraEOSTokens = ["<turn|>"]
            }
            if configuration.toolCallFormat == nil {
                configuration.toolCallFormat = .gemma4
            }
            if configuration.reasoningConfig == nil {
                configuration.reasoningConfig = Gemma4Chat.reasoningConfig
            }
        }
        return configuration
    }

    private static func knownConfiguration(matching id: String, preferVision: Bool) -> ModelConfiguration? {
        let needle = id.lowercased()
        let registries = preferVision
            ? [VLMRegistry.shared, LLMRegistry.shared]
            : [LLMRegistry.shared, VLMRegistry.shared]
        for registry in registries {
            if let match = registry.models.first(where: { $0.name.lowercased() == needle }) {
                return match
            }
        }
        return nil
    }

    private static func hubWeightsLocation(id: String) -> URL {
        if let directory = HuggingFaceCache.weightsDirectory(for: id) {
            return directory
        }
        let cache = HubCache.default
        guard let repo = Repo.ID(rawValue: id) else {
            return cache.cacheDirectory
        }
        return cache.repoDirectory(repo: repo, kind: .model)
    }
    #endif
}

#if AFM_MLX
/// Gemma 4 thinking is a chat-template flag plus channel delimiters, not `<think>` tags.
enum Gemma4Chat {
    static let reasoningConfig = ReasoningConfig(
        startDelimiter: "<|channel>thought",
        endDelimiter: "<channel|>",
        promptStrategy: .templateFlag(key: "enable_thinking", defaultOn: false),
        isSpecialToken: true,
        implicitEndDelimiters: ["<|tool_call>"]
    )
}
#endif

#if AFM_MLX
private nonisolated enum LoadProgressBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Double) -> Void)?

    static func setHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func report(fraction: Double) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(fraction)
    }
}

nonisolated private final class FileProgressBox: @unchecked Sendable {
    let value: Progress

    init(total: Int64) {
        value = Progress(totalUnitCount: max(total, 1))
    }

    var completed: Int64 {
        max(0, value.completedUnitCount)
    }
}

private actor DownloadByteProgress {
    private var finished: Int64
    private var inflightByFile: [String: Int64] = [:]
    private var expectedByFile: [String: Int64] = [:]
    private var sessionBytes: Int64 = 0
    private var diskBytes: Int64 = 0
    private var queuedBytes: Int64
    private var activeFiles: [String] = []
    private var observedFileNames: [String] = []
    private var latestCompleted: Int64 = 0
    private var latestTotal: Int64 = 0
    private var latestFileName: String?
    private var reportTask: Task<Void, Never>?
    private var lastSpuriousLog = Date.distantPast
    private let estimatedTotal: Int64
    private let onProgress: @Sendable (Int64, Int64, String?) -> Void

    init(
        finished: Int64,
        total: Int64,
        queuedBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64, String?) -> Void
    ) {
        self.finished = finished
        self.estimatedTotal = max(total, 1)
        self.queuedBytes = max(0, queuedBytes)
        self.onProgress = onProgress
        self.latestCompleted = finished
        self.latestTotal = max(total, 1)
    }

    func beginFile(_ path: String, expected: Int64) {
        if !activeFiles.contains(path) {
            activeFiles.append(path)
            queuedBytes = max(0, queuedBytes - max(expected, 0))
        }
        expectedByFile[path] = max(expectedByFile[path] ?? 0, expected, 1)
        inflightByFile[path] = 0
        scheduleReport()
    }

    func setInflight(_ path: String, bytes: Int64, expected: Int64) {
        expectedByFile[path] = max(expectedByFile[path] ?? 0, expected)
        guard !looksLikeLFSPointer(bytes) else { return }
        inflightByFile[path] = max(0, bytes)
        scheduleReport()
    }

    func setObserved(sessionBytes: Int64, diskBytes: Int64, fileNames: [String]) {
        self.sessionBytes = max(0, sessionBytes)
        self.diskBytes = max(0, diskBytes)
        if !fileNames.isEmpty {
            observedFileNames = fileNames
        }
        scheduleReport()
    }

    func publishedBytes() -> (completed: Int64, total: Int64) {
        (latestCompleted, latestTotal)
    }

    func finish(_ path: String, size: Int64) {
        let actual = max(size, expectedByFile[path] ?? 0)
        activeFiles.removeAll { $0 == path }
        inflightByFile[path] = nil
        expectedByFile[path] = nil
        finished += actual
        diskBytes = max(0, diskBytes - actual)
        sessionBytes = 0
        scheduleReport()
    }

    private func scheduleReport() {
        let snapshot = snapshotProgress()
        latestCompleted = snapshot.completed
        latestTotal = snapshot.total
        latestFileName = snapshot.fileName
        guard reportTask == nil else { return }
        reportTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            reportTask = nil
            onProgress(latestCompleted, latestTotal, latestFileName)
        }
    }

    private func snapshotProgress() -> (completed: Int64, total: Int64, fileName: String?) {
        let tracked = inflightByFile.values.reduce(Int64(0)) { partial, value in
            looksLikeLFSPointer(value) ? partial : partial + value
        }
        let physical = max(diskBytes, sessionBytes)
        let trackedLive: Int64
        if isSpurious(tracked: tracked, physical: physical) {
            trackedLive = 0
            let now = Date()
            if now.timeIntervalSince(lastSpuriousLog) >= 5 {
                lastSpuriousLog = now
                ModelDownloadLog.info(
                    "ignoring stuck file progress tracked=\(tracked) session=\(sessionBytes) disk=\(diskBytes)"
                )
            }
        } else {
            trackedLive = tracked
        }
        let live = activeFiles.isEmpty ? 0 : max(trackedLive, physical)
        let current = max(finished + live, finished, 0)
        let expectedActive = expectedByFile.values.reduce(Int64(0), +)
        let remaining = max(0, expectedActive - live) + queuedBytes
        var displayedTotal = max(estimatedTotal, current + remaining)
        if !activeFiles.isEmpty {
            displayedTotal = max(displayedTotal, current + 1)
        }
        let fileName = displayedFileName()
        return (current, displayedTotal, fileName)
    }

    private func isSpurious(tracked: Int64, physical: Int64) -> Bool {
        guard tracked > 1_000_000 else { return false }
        if physical > 65_536 {
            let tolerance = max(32_000_000, tracked / 10)
            return tracked > physical + tolerance
        }
        let expected = expectedByFile.values.reduce(Int64(0), +)
        return expected > 1_000_000 && tracked >= expected * 9 / 10
    }

    private func displayedFileName() -> String? {
        let fromSession = observedFileNames.last { name in
            name.contains(".") && !name.hasPrefix("CFNetwork")
        }
        if let fromSession {
            return fromSession
        }
        if let active = activeFiles.last {
            return URL(fileURLWithPath: active).lastPathComponent
        }
        return observedFileNames.last
    }
}

nonisolated private func looksLikeLFSPointer(_ bytes: Int64) -> Bool {
    bytes > 0 && bytes < 65_536
}
#endif
