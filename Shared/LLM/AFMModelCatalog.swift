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
                switch PrivateCloudComputeLanguageModel().availability {
                case .available:
                    return nil
                case .unavailable(.deviceNotEligible):
                    return "This device does not support Private Cloud Compute."
                case .unavailable(.systemNotReady):
                    return "Private Cloud Compute is not ready. Enable Apple Intelligence and ensure you have a network connection."
                case .unavailable:
                    return "Private Cloud Compute is unavailable on this device."
                }
            }
            return "Private Cloud Compute requires iOS 27 or later."
        }
    }

    static func supportsReasoning(_ choice: LLMModelChoice) -> Bool {
        if #available(iOS 27, *) {
            return languageModel(for: choice).capabilities.contains(.reasoning)
        }
        return false
    }

    static func isModelAvailable(_ choice: LLMModelChoice) -> Bool {
        switch choice {
        case .onDevice:
            return SystemLanguageModel.default.isAvailable
        case .privateCloudCompute:
            guard AFMEntitlements.hasPrivateCloudCompute else { return false }
            if #available(iOS 27, *) {
                let model = PrivateCloudComputeLanguageModel()
                guard model.isAvailable else { return false }
                if case .available = model.availability {
                    return true
                }
            }
            return false
        }
    }

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
        }
    }

    static func systemLanguageModel(guardrails: LLMGuardrailsMode = .default) -> SystemLanguageModel {
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

        return sizes
    }
}
