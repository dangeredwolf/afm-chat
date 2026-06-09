import Foundation
import FoundationModels

@available(iOS 27, *)
private struct ChatSessionInstructions: DynamicInstructions {
    let prompt: String
    let tools: [any Tool]

    var body: some DynamicInstructions {
        Instructions {
            prompt
        }
        ForEach(tools, id: \.name) { tool in
            AnyTool(tool)
        }
    }
}

enum AFMSessionFactory {
    static func makeSession(
        instructions: String,
        tools: [any Tool],
        configuration: LLMSessionConfiguration
    ) -> LanguageModelSession {
        let resolved = AFMModelCatalog.resolvedConfiguration(configuration)

        if #available(iOS 27, *) {
            return makeProfileSession(
                instructions: instructions,
                tools: tools,
                configuration: resolved
            )
        } else {
            return LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                instructions: instructions
            )
        }
    }

    @available(iOS 27, *)
    private static func makeProfileSession(
        instructions: String,
        tools: [any Tool],
        configuration: LLMSessionConfiguration
    ) -> LanguageModelSession {
        let model = AFMModelCatalog.languageModel(for: configuration.model)

        var profile = LanguageModelSession.Profile {
            ChatSessionInstructions(prompt: instructions, tools: tools)
        }
        .model(model)
        .temperature(configuration.temperature)

        if AFMModelCatalog.supportsReasoning(configuration.model) {
            profile = profile.reasoningLevel(configuration.reasoningLevel.toAFM())
        }

        return LanguageModelSession(profile: profile)
    }
}

extension LLMReasoningLevel {
    @available(iOS 27, *)
    func toAFM() -> ContextOptions.ReasoningLevel {
        switch self {
        case .light: return .light
        case .moderate: return .moderate
        case .deep: return .deep
        }
    }
}

enum AFMSessionPipeline {
    case legacy
    case profile

    static var current: AFMSessionPipeline {
        if #available(iOS 27, *) {
            return .profile
        } else {
            return .legacy
        }
    }
}
