import Foundation

#if AFM_MLX
import FoundationModels
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
        thinkingBudgetTokens: Int?,
        tools: [any FoundationModels.Tool]
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
                        tools: tools,
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
        tools: [any FoundationModels.Tool],
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let model = await MLXModelFactory.makeLanguageModel(
            id: modelID,
            pipelineTag: DownloadedModelStore.pipelineTag(for: modelID)
        )
        let container = try await model.loadContainer()
        let loadedConfig = await container.configuration.reasoningConfig
        let resolvedReasoning = resolveReasoningConfig(id: modelID, loaded: loadedConfig)
        let reasoningConfig = resolvedReasoning.config
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
        let primedInside = isPrimedInside(
            thinkingEnabled: thinkingOn,
            config: reasoningConfig,
            knownProtocol: resolvedReasoning.knownProtocol
        )
        let toolSpecs = MLXToolBridge.specs(for: tools)
        let state = StreamState(
            emitter: ReasoningEventEmitter(config: reasoningConfig, primedInside: primedInside)
        )

        let chatSession = ChatSession(
            container,
            instructions: instructions,
            history: mlxHistory(from: history, modelID: modelID),
            generateParameters: GenerateParameters(temperature: Float(temperature)),
            components: components,
            additionalContext: additionalContext,
            tools: toolSpecs.isEmpty ? nil : toolSpecs,
            toolDispatch: toolSpecs.isEmpty
                ? nil
                : { @Sendable call in
                    try await dispatchTool(
                        call,
                        tools: tools,
                        state: state,
                        continuation: continuation
                    )
                }
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

        continuation.yield(.generationStarted)

        for try await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let chunk):
                if state.takeNeedsEmitterReset() {
                    state.emitter = ReasoningEventEmitter(
                        config: reasoningConfig,
                        primedInside: primedInside
                    )
                }
                let segments = state.emitter.process(chunk)
                for segment in segments {
                    switch segment {
                    case .reasoning(let text):
                        state.reasoningText += text
                        state.reasoningTokenCount = tokenizer.encode(
                            text: state.reasoningText,
                            addSpecialTokens: false
                        ).count
                        continuation.yield(
                            .reasoningUpdated(
                                content: state.reasoningText,
                                tokenCount: state.reasoningTokenCount
                            )
                        )
                    case .response(let text):
                        state.fullText += text
                        continuation.yield(.contentUpdated(fullText: state.fullText))
                    }
                }
            case .info(let info):
                if !state.reasoningText.isEmpty {
                    state.reasoningTokenCount = min(state.reasoningTokenCount, info.generationTokenCount)
                    continuation.yield(
                        .reasoningUpdated(
                            content: state.reasoningText,
                            tokenCount: state.reasoningTokenCount
                        )
                    )
                }
            case .toolCall(let call):
                state.upsertToolCall(
                    LLMToolCallEvent(
                        transcriptID: call.id ?? UUID().uuidString,
                        toolName: MLXToolBridge.displayName(for: call.function.name),
                        toolDescription: MLXToolBridge.displayName(for: call.function.name),
                        arguments: MLXToolBridge.encodeArguments(call.function.arguments),
                        status: .pending
                    )
                )
                continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
            case .rejectedToolCall:
                break
            }
        }

        let trailing = state.emitter.finalize()
        for segment in trailing {
            switch segment {
            case .reasoning(let text):
                state.reasoningText += text
            case .response(let text):
                state.fullText += text
            }
        }

        if !state.reasoningText.isEmpty {
            state.reasoningTokenCount = tokenizer.encode(
                text: state.reasoningText,
                addSpecialTokens: false
            ).count
            continuation.yield(
                .reasoningUpdated(content: state.reasoningText, tokenCount: state.reasoningTokenCount)
            )
        }
        if !state.fullText.isEmpty {
            continuation.yield(.contentUpdated(fullText: state.fullText))
        }
    }

    private static func dispatchTool(
        _ call: ToolCall,
        tools: [any FoundationModels.Tool],
        state: StreamState,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws -> String {
        let transcriptID = call.id ?? UUID().uuidString
        let displayName = MLXToolBridge.displayName(for: call.function.name)
        let arguments = MLXToolBridge.encodeArguments(call.function.arguments)
        state.upsertToolCall(
            LLMToolCallEvent(
                transcriptID: transcriptID,
                toolName: displayName,
                toolDescription: displayName,
                arguments: arguments,
                status: .executing
            )
        )
        continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
        state.needsEmitterReset = true

        do {
            let result = try await MLXToolBridge.invoke(call, tools: tools)
            state.completeToolCall(transcriptID: transcriptID, result: result)
            continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.failToolCall(transcriptID: transcriptID, error: error.localizedDescription)
            continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
            throw error
        }
    }

    private struct ResolvedReasoning {
        let config: ReasoningConfig
        let knownProtocol: Bool
    }

    private static func resolveReasoningConfig(
        id: String,
        loaded: ReasoningConfig?
    ) -> ResolvedReasoning {
        if let loaded {
            return ResolvedReasoning(config: loaded, knownProtocol: true)
        }
        let modelType = HuggingFaceCache.modelType(for: id) ?? ""
        if let resolved = ChatConventionsRegistry.shared.reasoningConfig(
            modelId: id,
            modelType: modelType
        ) {
            return ResolvedReasoning(config: resolved, knownProtocol: true)
        }
        if HuggingFaceModelCatalog.looksLikeGemma4(id: id) {
            return ResolvedReasoning(config: Gemma4Chat.reasoningConfig, knownProtocol: true)
        }
        if HuggingFaceModelCatalog.looksLikeAlwaysOnReasoning(id: id) {
            return ResolvedReasoning(config: .alwaysOnThinking, knownProtocol: true)
        }
        if HuggingFaceModelCatalog.looksLikeBudgetedReasoning(id: id) {
            return ResolvedReasoning(config: QwenReasoningProtocol.qwen3, knownProtocol: true)
        }
        // Most chat models honor `<think>` tags and/or `enable_thinking`.
        // Unknown families still get the settings; thinking is only shown
        // in chat if the model actually emits it.
        return ResolvedReasoning(config: .thinkTagsWithEnableThinking, knownProtocol: false)
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
        config: ReasoningConfig,
        knownProtocol: Bool
    ) -> Bool {
        guard thinkingEnabled, knownProtocol else { return false }
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
        history.flatMap { entry -> [MLXLMCommon.Chat.Message] in
            let images = entry.attachments.filter { $0.mediaKind == .image }.map { UserInput.Image.url($0.fileURL) }
            let videos = entry.attachments.filter { $0.mediaKind == .video }.map { UserInput.Video.url($0.fileURL) }
            let audios = entry.attachments.filter { $0.mediaKind == .audio }.map { UserInput.Audio.url($0.fileURL) }
            if entry.isUser {
                return [.user(entry.content, images: images, videos: videos, audios: audios)]
            }
            return assistantHistoryMessages(from: entry, modelID: modelID)
        }
    }

    private static func assistantHistoryMessages(
        from entry: LLMHistoryEntry,
        modelID: String
    ) -> [MLXLMCommon.Chat.Message] {
        var messages: [MLXLMCommon.Chat.Message] = []
        if !entry.toolCalls.isEmpty {
            let mlxCalls = entry.toolCalls.map { historyCall in
                ToolCall(
                    function: ToolCall.Function(
                        name: MLXToolBridge.schemaName(for: historyCall.toolName),
                        arguments: MLXToolBridge.decodeArguments(historyCall.argumentsJSON)
                    ),
                    id: historyCall.transcriptID
                )
            }
            messages.append(.assistant("", toolCalls: mlxCalls))
            for historyCall in entry.toolCalls {
                messages.append(
                    .tool(
                        historyCall.result ?? historyCall.error ?? "",
                        id: historyCall.transcriptID,
                        name: MLXToolBridge.schemaName(for: historyCall.toolName)
                    )
                )
            }
        }

        let content = assistantHistoryContent(from: entry, modelID: modelID)
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.assistant(content))
        }
        return messages
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
}

@available(iOS 27, *)
nonisolated private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    var emitter: ReasoningEventEmitter
    var fullText = ""
    var reasoningText = ""
    var reasoningTokenCount = 0
    private var storedToolCalls: [LLMToolCallEvent] = []
    private var storedNeedsEmitterReset = false

    init(emitter: ReasoningEventEmitter) {
        self.emitter = emitter
    }

    var toolCalls: [LLMToolCallEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedToolCalls
    }

    var needsEmitterReset: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedNeedsEmitterReset
        }
        set {
            lock.lock()
            storedNeedsEmitterReset = newValue
            lock.unlock()
        }
    }

    func takeNeedsEmitterReset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = storedNeedsEmitterReset
        storedNeedsEmitterReset = false
        return value
    }

    func upsertToolCall(_ event: LLMToolCallEvent) {
        lock.lock()
        defer { lock.unlock() }
        if let index = storedToolCalls.firstIndex(where: { $0.transcriptID == event.transcriptID }) {
            storedToolCalls[index].status = event.status
            storedToolCalls[index].result = event.result
            storedToolCalls[index].error = event.error
        } else {
            storedToolCalls.append(event)
        }
    }

    func completeToolCall(transcriptID: String, result: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storedToolCalls.firstIndex(where: { $0.transcriptID == transcriptID }) else {
            return
        }
        storedToolCalls[index].status = .completed
        storedToolCalls[index].result = result
        storedToolCalls[index].error = nil
    }

    func failToolCall(transcriptID: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storedToolCalls.firstIndex(where: { $0.transcriptID == transcriptID }) else {
            return
        }
        storedToolCalls[index].status = .failed
        storedToolCalls[index].error = error
    }
}
#endif
