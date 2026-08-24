import Foundation

#if AFM_MLX
import MLXFoundationModels
import MLXLMCommon

@available(iOS 27, *)
nonisolated enum MLXTokenStream {
    static func events(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt,
        temperature: Double,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await stream(
                        modelID: modelID,
                        instructions: instructions,
                        history: history,
                        prompt: prompt,
                        temperature: temperature,
                        thinkingEnabled: thinkingEnabled,
                        thinkingBudgetTokens: thinkingBudgetTokens,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func stream(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt,
        temperature: Double,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let model = await MLXModelFactory.makeLanguageModel(
            id: modelID,
            pipelineTag: DownloadedModelStore.pipelineTag(for: modelID)
        )
        let container = try await model.loadContainer()
        let loadedConfig = await container.configuration.reasoningConfig
        let reasoningConfig = resolveReasoningConfig(id: modelID, loaded: loadedConfig)
        let thinkingOn = effectiveThinkingEnabled(
            requested: thinkingEnabled,
            config: reasoningConfig
        )
        let additionalContext = thinkingContext(
            enabled: thinkingOn,
            config: reasoningConfig
        )
        let tokenizer = await container.tokenizer
        let components = thinkingComponents(
            budgetTokens: thinkingOn ? thinkingBudgetTokens : nil,
            config: reasoningConfig,
            tokenizer: tokenizer
        )

        let chatSession = ChatSession(
            container,
            instructions: instructions,
            history: mlxHistory(from: history, modelID: modelID),
            generateParameters: GenerateParameters(temperature: Float(temperature)),
            components: components,
            additionalContext: additionalContext
        )

        let images = prompt.attachments.filter { $0.mediaKind == .image }.map { UserInput.Image.url($0.fileURL) }
        let videos = prompt.attachments.filter { $0.mediaKind == .video }.map { UserInput.Video.url($0.fileURL) }
        let audios = prompt.attachments.filter { $0.mediaKind == .audio }.map { UserInput.Audio.url($0.fileURL) }
        let stream: AsyncThrowingStream<Generation, Error>
        if images.isEmpty, videos.isEmpty, audios.isEmpty {
            stream = chatSession.streamDetails(to: prompt.text)
        } else {
            stream = chatSession.streamDetails(
                to: prompt.text,
                images: images,
                videos: videos,
                audios: audios
            )
        }

        var emitter: ReasoningEventEmitter?
        if let reasoningConfig {
            emitter = ReasoningEventEmitter(
                config: reasoningConfig,
                primedInside: isPrimedInside(thinkingEnabled: thinkingOn, config: reasoningConfig)
            )
        }

        var fullText = ""
        var reasoningText = ""
        var reasoningTokenCount = 0
        for try await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let chunk):
                if var liveEmitter = emitter {
                    let segments = liveEmitter.process(chunk)
                    emitter = liveEmitter
                    for segment in segments {
                        switch segment {
                        case .reasoning(let text):
                            reasoningText += text
                            reasoningTokenCount = tokenizer.encode(
                                text: reasoningText,
                                addSpecialTokens: false
                            ).count
                            continuation.yield(
                                .reasoningUpdated(
                                    content: reasoningText,
                                    tokenCount: reasoningTokenCount
                                )
                            )
                        case .response(let text):
                            fullText += text
                            continuation.yield(.contentUpdated(fullText: fullText))
                        }
                    }
                } else {
                    fullText += chunk
                    continuation.yield(.contentUpdated(fullText: fullText))
                }
            case .info(let info):
                if !reasoningText.isEmpty {
                    reasoningTokenCount = min(reasoningTokenCount, info.generationTokenCount)
                    continuation.yield(
                        .reasoningUpdated(
                            content: reasoningText,
                            tokenCount: reasoningTokenCount
                        )
                    )
                }
            case .toolCall(let call):
                continuation.yield(
                    .toolCallsUpdated(
                        calls: [
                            LLMToolCallEvent(
                                transcriptID: call.id ?? UUID().uuidString,
                                toolName: call.function.name,
                                toolDescription: "",
                                arguments: encodeToolArguments(call.function.arguments),
                                status: .pending
                            )
                        ]
                    )
                )
            case .rejectedToolCall:
                break
            }
        }

        if var liveEmitter = emitter {
            let trailing = liveEmitter.finalize()
            for segment in trailing {
                switch segment {
                case .reasoning(let text):
                    reasoningText += text
                case .response(let text):
                    fullText += text
                }
            }
        }

        if !reasoningText.isEmpty {
            reasoningTokenCount = tokenizer.encode(
                text: reasoningText,
                addSpecialTokens: false
            ).count
            continuation.yield(
                .reasoningUpdated(content: reasoningText, tokenCount: reasoningTokenCount)
            )
        }
        if !fullText.isEmpty {
            continuation.yield(.contentUpdated(fullText: fullText))
        }
    }

    private static func resolveReasoningConfig(
        id: String,
        loaded: ReasoningConfig?
    ) -> ReasoningConfig? {
        if let loaded {
            return loaded
        }
        let modelType = HuggingFaceCache.modelType(for: id) ?? ""
        if let resolved = ChatConventionsRegistry.shared.reasoningConfig(
            modelId: id,
            modelType: modelType
        ) {
            return resolved
        }
        if HuggingFaceModelCatalog.looksLikeGemma4(id: id) {
            return Gemma4Chat.reasoningConfig
        }
        if HuggingFaceModelCatalog.looksLikeAlwaysOnReasoning(id: id) {
            return .alwaysOnThinking
        }
        if HuggingFaceModelCatalog.looksLikeBudgetedReasoning(id: id) {
            return QwenReasoningProtocol.qwen3
        }
        if HuggingFaceModelCatalog.looksLikeReasoning(id: id) {
            return .thinkTagsWithEnableThinking
        }
        return nil
    }

    private static func effectiveThinkingEnabled(
        requested: Bool,
        config: ReasoningConfig?
    ) -> Bool {
        guard let config else { return requested }
        switch config.promptStrategy {
        case .templateFlag:
            return requested
        case .alwaysOn, .none:
            return true
        }
    }

    private static func thinkingContext(
        enabled: Bool,
        config: ReasoningConfig?
    ) -> [String: any Sendable]? {
        guard let config else { return nil }
        do {
            return try config.promptStrategy.additionalContext(forThinkingEnabled: enabled)
        } catch {
            return try? config.promptStrategy.additionalContext(forThinkingEnabled: true)
        }
    }

    private static func isPrimedInside(
        thinkingEnabled: Bool,
        config: ReasoningConfig
    ) -> Bool {
        guard thinkingEnabled else { return false }
        switch config.promptStrategy {
        case .alwaysOn, .templateFlag:
            return true
        case .none:
            return false
        }
    }

    private static func thinkingComponents(
        budgetTokens: Int?,
        config: ReasoningConfig?,
        tokenizer: Tokenizer
    ) -> GenerationComponents {
        guard let budgetTokens, budgetTokens > 0, let config, config.budgetTransition != nil else {
            return GenerationComponents()
        }
        do {
            let budget = try ThinkingBudgetConfiguration(maximumTokenCount: budgetTokens)
            return try GenerationComponents().applyingThinkingBudget(
                budget,
                reasoning: config,
                tokenizer: tokenizer
            )
        } catch {
            return GenerationComponents()
        }
    }

    private static func mlxHistory(
        from history: [LLMHistoryEntry],
        modelID: String
    ) -> [MLXLMCommon.Chat.Message] {
        history.compactMap { entry in
            let images = entry.attachments.filter { $0.mediaKind == .image }.map { UserInput.Image.url($0.fileURL) }
            let videos = entry.attachments.filter { $0.mediaKind == .video }.map { UserInput.Video.url($0.fileURL) }
            let audios = entry.attachments.filter { $0.mediaKind == .audio }.map { UserInput.Audio.url($0.fileURL) }
            if entry.isUser {
                return .user(entry.content, images: images, videos: videos, audios: audios)
            }
            let content = assistantHistoryContent(from: entry, modelID: modelID)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return .assistant(content)
        }
    }

    private static func assistantHistoryContent(from entry: LLMHistoryEntry, modelID: String) -> String {
        let answer = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gemma 4 must not see prior thoughts in history, including Qwen-style
        // `<think>` wrappers that its template does not understand.
        if HuggingFaceModelCatalog.looksLikeGemma4(id: modelID) {
            return answer
        }
        let reasoning = entry.reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reasoning.isEmpty {
            return answer
        }
        if answer.isEmpty {
            return "<think>\n\(reasoning)\n</think>"
        }
        return "<think>\n\(reasoning)\n</think>\n\n\(answer)"
    }

    private static func encodeToolArguments(_ arguments: [String: JSONValue]) -> String {
        let object = arguments.mapValues(\.anyValue)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
#endif
