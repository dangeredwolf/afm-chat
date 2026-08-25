import Foundation

#if AFM_MLX
import MLXLMCommon

nonisolated final class MLXUsageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var inputTokens = 0
    private var outputTokens = 0
    private var reasoningTokens = 0
    private var hasValue = false

    var hasMeasurement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasValue
    }

    func snapshot(contextLimit: Int, model: LLMModelChoice) -> LLMContextUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard hasValue else { return nil }
        let used = inputTokens + outputTokens
        guard used > 0, contextLimit > 0 else { return nil }
        return LLMContextUsage(
            usedTokens: used,
            contextLimit: contextLimit,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            model: model
        )
    }

    func apply(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let inputTokens {
            self.inputTokens = max(0, inputTokens)
        }
        if let outputTokens {
            self.outputTokens = max(0, outputTokens)
        }
        if let reasoningTokens {
            self.reasoningTokens = max(0, reasoningTokens)
        }
        hasValue = self.inputTokens > 0 || self.outputTokens > 0
    }
}

nonisolated enum MLXTokenStream {
    static func events(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt,
        temperature: Double,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?,
        saveMemory: Bool,
        maxOutputTokens: Int?,
        generationSeed: UInt64?,
        enabledToolIDs: [AppToolID],
        attachmentRegistry: AttachmentRegistry?,
        usage: MLXUsageTracker? = nil
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
                        saveMemory: saveMemory,
                        maxOutputTokens: maxOutputTokens,
                        generationSeed: generationSeed,
                        enabledToolIDs: enabledToolIDs,
                        attachmentRegistry: attachmentRegistry,
                        usage: usage,
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

    static func measurePromptTokens(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt?,
        thinkingEnabled: Bool,
        enabledToolIDs: [AppToolID]
    ) async -> Int? {
        let container = await MLXModelFactory.cachedContainer(id: modelID)
        let tokenizer: Tokenizer
        let generator: any MessageGenerator
        let loadedConfig: ReasoningConfig?
        if let container {
            tokenizer = await container.tokenizer
            generator = await container.configuration.messageGenerator ?? DefaultMessageGenerator()
            loadedConfig = await container.configuration.reasoningConfig
        } else {
            do {
                tokenizer = try await MLXModelFactory.tokenizer(id: modelID)
            } catch {
                return nil
            }
            generator = DefaultMessageGenerator()
            loadedConfig = nil
        }

        return promptTokenCount(
            tokenizer: tokenizer,
            messageGenerator: generator,
            modelID: modelID,
            instructions: instructions,
            history: history,
            prompt: prompt,
            thinkingEnabled: thinkingEnabled,
            loadedConfig: loadedConfig,
            enabledToolIDs: enabledToolIDs
        )
    }

    private static func stream(
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt,
        temperature: Double,
        thinkingEnabled: Bool,
        thinkingBudgetTokens: Int?,
        saveMemory: Bool,
        maxOutputTokens: Int?,
        generationSeed: UInt64?,
        enabledToolIDs: [AppToolID],
        attachmentRegistry: AttachmentRegistry?,
        usage: MLXUsageTracker?,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let container = try await MLXModelFactory.loadContainer(
            id: modelID,
            pipelineTag: DownloadedModelStore.pipelineTag(for: modelID)
        )
        let loadedConfig = await container.configuration.reasoningConfig
        let resolvedReasoning = resolveReasoningConfig(id: modelID, loaded: loadedConfig)
        let reasoningConfig = resolvedReasoning.config
        let isGptOss = HuggingFaceModelCatalog.looksLikeGptOss(id: modelID)
        let thinkingOn = isGptOss
            ? thinkingEnabled
            : effectiveThinkingEnabled(
                requested: thinkingEnabled,
                config: reasoningConfig
            )
        let additionalContext = thinkingContext(
            enabled: thinkingOn,
            config: reasoningConfig,
            modelID: modelID
        )
        let tokenizer = await container.tokenizer
        if let usage {
            let promptTokens = promptTokenCount(
                tokenizer: tokenizer,
                messageGenerator: await container.configuration.messageGenerator ?? DefaultMessageGenerator(),
                modelID: modelID,
                instructions: instructions,
                history: history,
                prompt: prompt,
                thinkingEnabled: thinkingOn,
                loadedConfig: loadedConfig,
                enabledToolIDs: enabledToolIDs
            )
            if let promptTokens {
                usage.apply(inputTokens: promptTokens)
            }
        }
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
            emitter: ReasoningEventEmitter(config: reasoningConfig, primedInside: primedInside),
            usesHarmony: isGptOss
        )

        let chatSession = ChatSession(
            container,
            instructions: instructions,
            history: mlxHistory(from: history, modelID: modelID),
            generateParameters: GenerateParameters(
                maxTokens: maxOutputTokens,
                kvBits: saveMemory ? 4 : nil,
                temperature: Float(temperature),
                seed: generationSeed
            ),
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
                    state.resetHarmony()
                }
                let segments = state.routeChunk(
                    normalizeReasoningChunk(chunk, modelID: modelID)
                )
                for segment in segments {
                    switch segment {
                    case .reasoning(let text):
                        state.reasoningText += text
                        let previousReasoningTokens = state.reasoningTokenCount
                        state.reasoningTokenCount = tokenizer.encode(
                            text: state.reasoningText,
                            addSpecialTokens: false
                        ).count
                        state.outputTokenEstimate += max(0, state.reasoningTokenCount - previousReasoningTokens)
                        continuation.yield(
                            .reasoningUpdated(
                                content: state.reasoningText,
                                tokenCount: state.reasoningTokenCount,
                                entryCount: nil
                            )
                        )
                    case .response(let text):
                        state.fullText += text
                        state.outputTokenEstimate += tokenizer.encode(
                            text: text,
                            addSpecialTokens: false
                        ).count
                        continuation.yield(.contentUpdated(fullText: state.fullText))
                    }
                }
                usage?.apply(
                    outputTokens: state.outputTokenEstimate,
                    reasoningTokens: state.reasoningTokenCount
                )
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
                usage?.apply(
                    inputTokens: info.totalPromptTokenCount,
                    outputTokens: info.generationTokenCount,
                    reasoningTokens: state.reasoningTokenCount
                )
            case .toolCall(let call):
                publishToolCall(call, status: .pending, state: state, continuation: continuation)
            case .rejectedToolCall:
                break
            }
        }

        let trailing = state.finalizeChunks()
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

    private static func promptTokenCount(
        tokenizer: Tokenizer,
        messageGenerator: any MessageGenerator,
        modelID: String,
        instructions: String,
        history: [LLMHistoryEntry],
        prompt: LLMPrompt?,
        thinkingEnabled: Bool,
        loadedConfig: ReasoningConfig?,
        enabledToolIDs: [AppToolID]
    ) -> Int? {
        var messages: [MLXLMCommon.Chat.Message] = []
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.system(instructions))
        }
        messages.append(contentsOf: mlxHistory(from: history, modelID: modelID))
        if let prompt {
            let images = prompt.attachments.filter { $0.mediaKind == .image }.map { UserInput.Image.url($0.fileURL) }
            let videos = prompt.attachments.filter { $0.mediaKind == .video }.map { UserInput.Video.url($0.fileURL) }
            let audios = prompt.attachments.filter { $0.mediaKind == .audio }.map { UserInput.Audio.url($0.fileURL) }
            messages.append(.user(prompt.text, images: images, videos: videos, audios: audios))
        }
        guard !messages.isEmpty else { return nil }

        let resolved = resolveReasoningConfig(id: modelID, loaded: loadedConfig)
        let thinkingOn = HuggingFaceModelCatalog.looksLikeGptOss(id: modelID)
            ? thinkingEnabled
            : effectiveThinkingEnabled(requested: thinkingEnabled, config: resolved.config)
        let additionalContext = thinkingContext(
            enabled: thinkingOn,
            config: resolved.config,
            modelID: modelID
        )
        let tools = MLXToolBridge.specs(for: enabledToolIDs)
        let raw = messageGenerator.generate(messages: messages)
        do {
            return try tokenizer.applyChatTemplate(
                messages: raw,
                tools: tools.isEmpty ? nil : tools,
                additionalContext: additionalContext
            ).count
        } catch {
            let text = messages.map(\.content).joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return tokenizer.encode(text: trimmed, addSpecialTokens: false).count
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
        if HuggingFaceModelCatalog.looksLikeGptOss(id: id) {
            return ResolvedReasoning(config: HarmonyChat.reasoningConfig, knownProtocol: true)
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
        config: ReasoningConfig?,
        modelID: String
    ) -> [String: any Sendable]? {
        if HuggingFaceModelCatalog.looksLikeGptOss(id: modelID) {
            return ["reasoning_effort": enabled ? "medium" : "low"]
        }
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
        if HuggingFaceModelCatalog.looksLikeGemma4(id: modelID)
            || HuggingFaceModelCatalog.looksLikeGptOss(id: modelID) {
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
        if HuggingFaceModelCatalog.looksLikeGemma4(id: modelID)
            || HuggingFaceModelCatalog.looksLikeGptOss(id: modelID) {
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

nonisolated private struct HarmonyChannelEmitter {
    private enum Mode {
        case response
        case reasoning
        case silent
        case header
        case role
    }

    private static let controlTokens = [
        "<|constrain|>", "<|message|>", "<|channel|>", "<|return|>",
        "<|start|>", "<|call|>", "<|end|>"
    ]

    private var mode: Mode = .response
    private var header = ""
    private var pending = ""

    mutating func process(_ chunk: String) -> [ReasoningEventEmitter.Segment] {
        pending += chunk
        var segments: [ReasoningEventEmitter.Segment] = []
        drain(into: &segments, flushing: false)
        return segments
    }

    mutating func finalize() -> [ReasoningEventEmitter.Segment] {
        var segments: [ReasoningEventEmitter.Segment] = []
        drain(into: &segments, flushing: true)
        return segments
    }

    private mutating func drain(
        into segments: inout [ReasoningEventEmitter.Segment],
        flushing: Bool
    ) {
        while true {
            if !flushing, let holdback = Self.partialControlSuffix(pending) {
                let stable = String(pending.dropLast(holdback.count))
                pending = holdback
                emitPayload(stable, into: &segments)
                return
            }

            guard let match = Self.nextControlToken(in: pending) else {
                emitPayload(pending, into: &segments)
                pending = ""
                return
            }

            emitPayload(String(pending[..<match.range.lowerBound]), into: &segments)
            pending = String(pending[match.range.upperBound...])
            apply(match.token)
        }
    }

    private mutating func apply(_ token: String) {
        switch token {
        case "<|start|>":
            mode = .role
            header = ""
        case "<|channel|>":
            mode = .header
            header = ""
        case "<|constrain|>":
            if mode == .header {
                header += token
            }
        case "<|message|>":
            if mode == .header || mode == .role {
                mode = Self.payloadMode(for: header)
                header = ""
            }
        case "<|end|>", "<|return|>", "<|call|>":
            mode = .response
            header = ""
        default:
            break
        }
    }

    private mutating func emitPayload(
        _ text: String,
        into segments: inout [ReasoningEventEmitter.Segment]
    ) {
        guard !text.isEmpty else { return }
        switch mode {
        case .header:
            header += text
        case .role, .silent:
            break
        case .reasoning:
            if let cleaned = Self.cleanedPayload(text) {
                segments.append(.reasoning(cleaned))
            }
        case .response:
            if let cleaned = Self.cleanedPayload(text) {
                segments.append(.response(cleaned))
            }
        }
    }

    private static func payloadMode(for header: String) -> Mode {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = trimmed.split { $0.isWhitespace || $0 == "<" }.first.map(String.init)
        let isTool = trimmed.contains("to=")
        switch channel {
        case "analysis":
            return .reasoning
        case "final":
            return .response
        case "commentary" where isTool:
            return .silent
        case "commentary":
            return .response
        default:
            return trimmed.isEmpty ? .response : .silent
        }
    }

    private static func cleanedPayload(_ text: String) -> String? {
        let stripped = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return stripped.isEmpty ? nil : stripped
    }

    private static func nextControlToken(
        in text: String
    ) -> (token: String, range: Range<String.Index>)? {
        var best: (token: String, range: Range<String.Index>)?
        for token in controlTokens {
            guard let range = text.range(of: token) else { continue }
            if let current = best, range.lowerBound >= current.range.lowerBound {
                continue
            }
            best = (token, range)
        }
        return best
    }

    private static func partialControlSuffix(_ text: String) -> String? {
        guard let start = text.lastIndex(of: "<") else { return nil }
        let suffix = String(text[start...])
        if suffix.hasPrefix("<|"), suffix.hasSuffix("|>") {
            return nil
        }
        guard controlTokens.contains(where: { $0.hasPrefix(suffix) }) else {
            return nil
        }
        return suffix
    }
}

nonisolated private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    var emitter: ReasoningEventEmitter
    private var harmony = HarmonyChannelEmitter()
    private let usesHarmony: Bool
    var fullText = ""
    var reasoningText = ""
    var reasoningTokenCount = 0
    var outputTokenEstimate = 0
    private var storedToolCalls: [LLMToolCallEvent] = []
    private var storedNeedsEmitterReset = false

    init(emitter: ReasoningEventEmitter, usesHarmony: Bool = false) {
        self.emitter = emitter
        self.usesHarmony = usesHarmony
    }

    func routeChunk(_ chunk: String) -> [ReasoningEventEmitter.Segment] {
        usesHarmony ? harmony.process(chunk) : emitter.process(chunk)
    }

    func finalizeChunks() -> [ReasoningEventEmitter.Segment] {
        usesHarmony ? harmony.finalize() : emitter.finalize()
    }

    func resetHarmony() {
        harmony = HarmonyChannelEmitter()
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
