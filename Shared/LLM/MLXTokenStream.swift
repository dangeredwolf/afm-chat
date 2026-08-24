import Foundation

#if AFM_MLX
import MLXLMCommon

nonisolated enum MLXTokenStream {
    static func events(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt,
        temperature: Double,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?,
        enabledToolIDs: [AppToolID],
        attachmentRegistry: AttachmentRegistry?
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
                        enabledToolIDs: enabledToolIDs,
                        attachmentRegistry: attachmentRegistry,
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
        enabledToolIDs: [AppToolID],
        attachmentRegistry: AttachmentRegistry?,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let container = try await MLXModelFactory.loadContainer(
            id: modelID,
            pipelineTag: DownloadedModelStore.pipelineTag(for: modelID)
        )
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
            knownProtocol: resolvedReasoning.knownProtocol,
            modelID: modelID
        )
        let toolSpecs = MLXToolBridge.specs(for: enabledToolIDs)
        let enabledIDs = Set(enabledToolIDs)
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
                        enabledIDs: enabledIDs,
                        attachmentRegistry: attachmentRegistry,
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
                let segments = state.emitter.process(
                    normalizeReasoningChunk(chunk, modelID: modelID)
                )
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
                                tokenCount: state.reasoningTokenCount,
                                entryCount: nil
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
                            tokenCount: state.reasoningTokenCount,
                            entryCount: nil
                        )
                    )
                }
            case .toolCall(let call):
                publishToolCall(call, status: .pending, state: state, continuation: continuation)
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
                .reasoningUpdated(
                    content: state.reasoningText,
                    tokenCount: state.reasoningTokenCount,
                    entryCount: nil
                )
            )
        }
        if !state.fullText.isEmpty {
            continuation.yield(.contentUpdated(fullText: state.fullText))
        }
    }

    private static func dispatchTool(
        _ call: ToolCall,
        enabledIDs: Set<AppToolID>,
        attachmentRegistry: AttachmentRegistry?,
        state: StreamState,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws -> String {
        let transcriptID = publishToolCall(
            call,
            status: .executing,
            state: state,
            continuation: continuation
        )
        state.needsEmitterReset = true
        // ChatSession holds Generation.toolCall until dispatch, and some tools
        // (WKWebView fetch) then take the main thread. Flush the in-progress
        // row to SwiftUI before that work starts or the transcript looks frozen.
        await flushToolCallUI()
        try Task.checkCancellation()

        let result = await MLXToolBridge.invoke(
            call,
            enabledIDs: enabledIDs,
            attachmentRegistry: attachmentRegistry
        )
        state.completeToolCall(transcriptID: transcriptID, result: result)
        continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
        return result
    }

    @discardableResult
    private static func publishToolCall(
        _ call: ToolCall,
        status: LLMToolCallStatus,
        state: StreamState,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) -> String {
        let transcriptID = call.id ?? UUID().uuidString
        let displayName = MLXToolBridge.displayName(for: call.function.name)
        state.upsertToolCall(
            LLMToolCallEvent(
                transcriptID: transcriptID,
                toolName: displayName,
                toolDescription: displayName,
                arguments: MLXToolBridge.encodeArguments(call.function.arguments),
                status: status
            )
        )
        continuation.yield(.toolCallsUpdated(calls: state.toolCalls))
        return transcriptID
    }

    private static func flushToolCallUI() async {
        await Task.yield()
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(32))
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
        knownProtocol: Bool,
        modelID: String
    ) -> Bool {
        guard thinkingEnabled, knownProtocol else { return false }
        // Gemma 4 emits `<|channel>thought` itself and, after a tool result,
        // continues with the user-facing answer. Priming would leak the opener
        // into the thought block and swallow that answer as thinking. Qwen-style
        // templates still prefill `<think>` after tools, so they stay primed.
        if HuggingFaceModelCatalog.looksLikeGemma4(id: modelID) {
            return false
        }
        switch config.promptStrategy {
        case .alwaysOn, .templateFlag:
            return true
        case .none:
            return false
        }
    }

    /// Some Gemma 4 tokenizers decode the channel-open token as `<|channel|>`
    /// instead of `<|channel>`, so the start delimiter never matches.
    private static func normalizeReasoningChunk(_ chunk: String, modelID: String) -> String {
        guard HuggingFaceModelCatalog.looksLikeGemma4(id: modelID) else { return chunk }
        return chunk.replacingOccurrences(of: "<|channel|>", with: "<|channel>")
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
        if !entry.transcriptBlocks.isEmpty {
            return interleavedAssistantHistoryMessages(from: entry, modelID: modelID)
        }
        return legacyAssistantHistoryMessages(from: entry, modelID: modelID)
    }

    private static func interleavedAssistantHistoryMessages(
        from entry: LLMHistoryEntry,
        modelID: String
    ) -> [MLXLMCommon.Chat.Message] {
        var messages: [MLXLMCommon.Chat.Message] = []
        var pendingReasoning = ""
        var pendingText = ""
        var pendingTools: [LLMHistoryToolCall] = []
        var toolsByID: [String: LLMHistoryToolCall] = [:]
        for call in entry.toolCalls {
            toolsByID[call.transcriptID] = call
        }

        func flushText() {
            let content = assistantHistoryContent(
                answer: pendingText,
                reasoning: pendingReasoning,
                modelID: modelID
            )
            pendingReasoning = ""
            pendingText = ""
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(.assistant(content))
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            flushText()
            let mlxCalls = pendingTools.map { historyCall in
                ToolCall(
                    function: ToolCall.Function(
                        name: MLXToolBridge.schemaName(for: historyCall.toolName),
                        arguments: MLXToolBridge.decodeArguments(historyCall.argumentsJSON)
                    ),
                    id: historyCall.transcriptID
                )
            }
            messages.append(.assistant("", toolCalls: mlxCalls))
            for historyCall in pendingTools {
                messages.append(
                    .tool(
                        historyCall.result ?? historyCall.error ?? "",
                        id: historyCall.transcriptID,
                        name: MLXToolBridge.schemaName(for: historyCall.toolName)
                    )
                )
            }
            pendingTools = []
        }

        for block in entry.transcriptBlocks {
            switch block {
            case .reasoning(let content):
                flushTools()
                if !pendingReasoning.isEmpty {
                    pendingReasoning += "\n\n"
                }
                pendingReasoning += content
            case .text(let content):
                flushTools()
                if !pendingText.isEmpty {
                    pendingText += "\n\n"
                }
                pendingText += content
            case .tool(let transcriptID):
                if let tool = toolsByID[transcriptID] {
                    pendingTools.append(tool)
                }
            }
        }
        flushTools()
        flushText()
        return messages
    }

    private static func legacyAssistantHistoryMessages(
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

        let content = assistantHistoryContent(
            answer: entry.content,
            reasoning: entry.reasoningContent ?? "",
            modelID: modelID
        )
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.assistant(content))
        }
        return messages
    }

    private static func assistantHistoryContent(answer: String, reasoning: String, modelID: String) -> String {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gemma 4 must not see prior thoughts in history, including Qwen-style
        // `<think>` wrappers that its template does not understand.
        if HuggingFaceModelCatalog.looksLikeGemma4(id: modelID) {
            return answer
        }
        let reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if reasoning.isEmpty {
            return answer
        }
        if answer.isEmpty {
            return "<think>\n\(reasoning)\n</think>"
        }
        return "<think>\n\(reasoning)\n</think>\n\n\(answer)"
    }
}

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
