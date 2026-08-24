import Foundation
import FoundationModels

enum AFMModelCatalog {
    static func modelOptions() -> [LLMModelOption] {
        var options: [LLMModelOption] = [
            LLMModelOption(
                choice: .onDevice,
                isAvailable: isModelAvailable(.onDevice),
                supportsReasoning: supportsReasoning(.onDevice),
                unavailabilityNote: unavailabilityNote(for: .onDevice)
            )
        ]

        if #available(iOS 27, *) {
            options.append(
                LLMModelOption(
                    choice: .privateCloudCompute,
                    isAvailable: isModelAvailable(.privateCloudCompute),
                    supportsReasoning: supportsReasoning(.privateCloudCompute),
                    unavailabilityNote: unavailabilityNote(for: .privateCloudCompute)
                )
            )

            for model in DownloadedModelStore.storedModels() {
                let choice = LLMModelChoice.mlx(id: model.id)
                options.append(
                    LLMModelOption(
                        choice: choice,
                        isAvailable: isModelAvailable(choice),
                        supportsReasoning: supportsReasoning(choice),
                        unavailabilityNote: unavailabilityNote(for: choice)
                    )
                )
            }
        }

        return options
    }

    static func unavailabilityNote(for choice: LLMModelChoice) -> String? {
        guard !isModelAvailable(choice) else { return nil }

        switch choice {
        case .onDevice:
            return "The on-device model is not available. Enable Apple Intelligence in Settings and wait for the model to download."
        case .privateCloudCompute:
            if !AFMEntitlements.hasPrivateCloudCompute {
                return """
                This app does not have Apple's Private Cloud Compute entitlement yet. \
                An Account Holder must request access in Certificates, Identifiers & Profiles → \
                your App ID → Capability Requests, then add the capability in Xcode.
                """
            }
            if #available(iOS 27, *) {
                switch pccState() {
                case .available:
                    return nil
                case .deviceNotEligible:
                    return "This device does not support Private Cloud Compute."
                case .systemNotReady:
                    return "Private Cloud Compute is not ready. Enable Apple Intelligence and ensure you have a network connection."
                case .unavailable:
                    return "Private Cloud Compute is unavailable on this device."
                }
            }
            return "Private Cloud Compute requires iOS 27 or later."
        case .mlx:
            #if AFM_MLX
            if #available(iOS 27, *) {
                return "This MLX model is not downloaded. Add it from the model picker."
            }
            #endif
            return "Custom MLX models require iOS 27 or later."
        }
    }

    static func supportsReasoning(_ choice: LLMModelChoice) -> Bool {
        switch choice {
        case .onDevice:
            if #available(iOS 27, *) {
                return SystemLanguageModel.default.capabilities.contains(.reasoning)
            }
            return false
        case .privateCloudCompute:
            return AFMEntitlements.hasPrivateCloudCompute
        case .mlx(let id):
            #if AFM_MLX
            let tags = DownloadedModelStore.storedModels().first(where: { $0.id == id }).map { model in
                [model.pipelineTag].compactMap { $0 }
            } ?? []
            return HuggingFaceModelCatalog.looksLikeReasoning(id: id, tags: tags)
            #else
            return false
            #endif
        }
    }

    /// Apple models use Light/Moderate/Deep. MLX models use a thinking toggle.
    static func usesAppleReasoningLevels(_ choice: LLMModelChoice) -> Bool {
        switch choice {
        case .onDevice, .privateCloudCompute:
            return supportsReasoning(choice)
        case .mlx:
            return false
        }
    }

    static func mlxCanDisableThinking(_ choice: LLMModelChoice) -> Bool {
        guard case .mlx(let id) = choice else { return false }
        return HuggingFaceModelCatalog.looksLikeReasoning(id: id)
            && !HuggingFaceModelCatalog.looksLikeAlwaysOnReasoning(id: id)
    }

    static func mlxSupportsThinkingBudget(_ choice: LLMModelChoice) -> Bool {
        guard case .mlx(let id) = choice else { return false }
        return HuggingFaceModelCatalog.looksLikeBudgetedReasoning(id: id)
    }

    static func isModelAvailable(_ choice: LLMModelChoice) -> Bool {
        switch choice {
        case .onDevice:
            return SystemLanguageModel.default.isAvailable
        case .privateCloudCompute:
            guard AFMEntitlements.hasPrivateCloudCompute else { return false }
            if #available(iOS 27, *) {
                return pccState() == .available
            }
            return false
        case .mlx(let id):
            #if AFM_MLX
            if #available(iOS 27, *) {
                // Mirrors MLXLanguageModel.availability == .available (weights on disk).
                return HuggingFaceCache.isDownloaded(id)
            }
            #endif
            return false
        }
    }

    @available(iOS 27, *)
    private enum PCCState {
        case available
        case deviceNotEligible
        case systemNotReady
        case unavailable
    }

    @available(iOS 27, *)
    private static func pccState() -> PCCState {
        if let cached = pccStateCache, Date().timeIntervalSince(cached.at) < 30 {
            return cached.state
        }
        let model = PrivateCloudComputeLanguageModel()
        let state: PCCState
        switch model.availability {
        case .available:
            state = .available
        case .unavailable(.deviceNotEligible):
            state = .deviceNotEligible
        case .unavailable(.systemNotReady):
            state = .systemNotReady
        case .unavailable:
            state = .unavailable
        }
        pccStateCache = (Date(), state)
        return state
    }

    @available(iOS 27, *)
    private static var pccStateCache: (at: Date, state: PCCState)?

    static func resolvedConfiguration(_ configuration: LLMSessionConfiguration) -> LLMSessionConfiguration {
        var resolved = configuration
        if !isModelAvailable(resolved.model) {
            resolved.model = .onDevice
        }
        if !supportsReasoning(resolved.model) {
            resolved.reasoningLevel = .light
        }
        return resolved
    }

    @available(iOS 27, *)
    static func languageModel(
        for choice: LLMModelChoice,
        guardrails: LLMGuardrailsMode = .default
    ) -> any LanguageModel {
        switch choice {
        case .onDevice:
            return systemLanguageModel(guardrails: guardrails)
        case .privateCloudCompute:
            return PrivateCloudComputeLanguageModel()
        case .mlx(let id):
            #if AFM_MLX
            return MLXModelFactory.makeLanguageModel(
                id: id,
                pipelineTag: DownloadedModelStore.pipelineTag(for: id)
            )
            #else
            return systemLanguageModel(guardrails: guardrails)
            #endif
        }
    }

    static func systemLanguageModel(guardrails: LLMGuardrailsMode = .permissiveContentTransformations) -> SystemLanguageModel {
        switch guardrails {
        case .default:
            return SystemLanguageModel.default
        case .permissiveContentTransformations:
            return SystemLanguageModel(guardrails: .permissiveContentTransformations)
        }
    }

    @available(iOS 27, *)
    static func contextSize(for choice: LLMModelChoice) async throws -> Int {
        switch choice {
        case .onDevice:
            return SystemLanguageModel.default.contextSize
        case .privateCloudCompute:
            return try await PrivateCloudComputeLanguageModel().contextSize
        case .mlx(let id):
            if let size = HuggingFaceCache.contextSize(for: id) {
                return size
            }
            return 8192
        }
    }

    @available(iOS 27, *)
    static func allContextSizes() async -> [LLMModelChoice: Int] {
        var sizes: [LLMModelChoice: Int] = [
            .onDevice: SystemLanguageModel.default.contextSize
        ]

        if AFMEntitlements.hasPrivateCloudCompute, isModelAvailable(.privateCloudCompute) {
            if let pccSize = try? await PrivateCloudComputeLanguageModel().contextSize {
                sizes[.privateCloudCompute] = pccSize
            }
        }

        for model in DownloadedModelStore.storedModels() {
            let choice = LLMModelChoice.mlx(id: model.id)
            if let size = try? await contextSize(for: choice) {
                sizes[choice] = size
            }
        }

        return sizes
    }
}
