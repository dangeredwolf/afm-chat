import Foundation

nonisolated enum ChatGenerationPhase: Equatable, Sendable {
    case idle
    case loadingModel(name: String, fraction: Double?)
    case compiling(name: String)
    case generating
}

#if AFM_MLX

@available(iOS 27, *)
@MainActor
final class MLXRuntime {
    static let shared = MLXRuntime()

    private var warmedIDs: Set<String> = []
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var residentID: String?
    private var activationEpoch = 0

    private init() {}

    func isWarmed(_ id: String) -> Bool {
        warmedIDs.contains(id)
    }

    /// Drops a single model after it is deleted from disk.
    func unload(_ id: String) async {
        cancelLoad(id)
        warmedIDs.remove(id)
        if residentID == id {
            residentID = nil
        }
        await MLXModelFactory.evict(id: id)
    }

    /// Makes `id` the only MLX model held in GPU memory. Call this when a
    /// generation is about to start, not when browsing chats or picking a
    /// model — rapid activate/evict of weights is unstable. Pass `nil` when
    /// the upcoming turn uses Apple Intelligence.
    func activate(
        id: String?,
        pipelineTag: String?,
        displayName: String,
        onPhase: @escaping @Sendable (ChatGenerationPhase) -> Void = { _ in }
    ) async throws {
        activationEpoch += 1
        let epoch = activationEpoch

        if id != residentID {
            await purgeResidentModels()
            guard epoch == activationEpoch else { throw CancellationError() }
            residentID = id
        }

        guard let id else { return }
        try await ensureReady(
            id: id,
            pipelineTag: pipelineTag,
            displayName: displayName,
            onPhase: onPhase
        )
        guard epoch == activationEpoch else { throw CancellationError() }
    }

    func ensureReady(
        id: String,
        pipelineTag: String?,
        displayName: String,
        onPhase: @escaping @Sendable (ChatGenerationPhase) -> Void
    ) async throws {
        if warmedIDs.contains(id) {
            return
        }
        if let existing = inFlight[id] {
            try await existing.value
            return
        }

        let task = Task.detached {
            try await MLXModelFactory.warmUp(
                id: id,
                pipelineTag: pipelineTag,
                displayName: displayName,
                onPhase: onPhase
            )
        }
        inFlight[id] = task
        do {
            try await task.value
            if residentID == id {
                warmedIDs.insert(id)
            }
            inFlight[id] = nil
        } catch {
            inFlight[id] = nil
            throw error
        }
    }

    private func purgeResidentModels() async {
        for id in Array(inFlight.keys) {
            cancelLoad(id)
        }
        warmedIDs.removeAll()
        // Drop the shared MLX container cache immediately so the next model
        // can load. In-flight warmups are cancelled and cannot re-populate.
        await MLXModelFactory.evictAllResidentWeights()
    }

    private func cancelLoad(_ id: String) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        warmedIDs.remove(id)
    }
}
#endif
