import Foundation
import FoundationModels
import os

// Apple Foundation Models implementation of LLMClient

private enum AFMReasoningProbe {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "afm-chat", category: "AFMReasoning")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[AFMReasoning] \(message)")
    }

    static func preview(_ text: String, limit: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

final class AFMClient: LLMClient {
    var availability: LLMAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.notEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable(let other):
            return .unavailable(.other(String(describing: other)))
        }
    }

    func createSession(instructions: String, tools: [LLMTool], configuration: LLMSessionConfiguration) -> LLMSession {
        #if AFM_MLX
        if let modelID = configuration.model.mlxModelID {
            return MLXSession(
                modelID: modelID,
                instructions: instructions,
                configuration: configuration,
                enabledToolIDs: mlxToolIDs(from: tools),
                attachmentRegistry: mlxAttachmentRegistry(from: tools)
            )
        }
        #endif

        let afmTools: [any Tool] = tools.compactMap { tool in
            if let anyTool = tool as? AnyLLMTool,
               let afmTool = anyTool.providerPayloads["afmTool"] as? any Tool {
                return afmTool
            }
            return nil
        }

        let session = AFMSessionFactory.makeSession(
            instructions: instructions,
            tools: afmTools,
            configuration: configuration
        )
        return AFMSession(
            session: session,
            configuration: configuration
        )
    }

    #if AFM_MLX
    private func mlxToolIDs(from tools: [LLMTool]) -> [AppToolID] {
        tools.compactMap { tool in
            guard let anyTool = tool as? AnyLLMTool,
                  let raw = anyTool.providerPayloads["toolID"] as? String
            else {
                return nil
            }
            return AppToolID(rawValue: raw)
        }
    }

    private func mlxAttachmentRegistry(from tools: [LLMTool]) -> AttachmentRegistry? {
        for tool in tools {
            if let anyTool = tool as? AnyLLMTool,
               let registry = anyTool.providerPayloads["attachmentRegistry"] as? AttachmentRegistry {
                return registry
            }
        }
        return nil
    }
    #endif
}

private struct TranscriptExtraction {
    var toolCalls: [LLMToolCallEvent]
    var responseContent: String
    var reasoningSnapshot: ReasoningSnapshot
}

private struct ReasoningSnapshot {
    var content: String?
    var tokenCount: Int?
    var signatureByteCount: Int?
    var entryCount: Int
}

private actor StreamToolCallEmitter {
    private var lastHash = 0

    func emitIfChanged(
        _ calls: [LLMToolCallEvent],
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        let hash = calls
            .map { $0.transcriptID + $0.toolName + $0.arguments + ($0.result ?? "") + ($0.error ?? "") + $0.status.rawValue }
            .joined()
            .hashValue
        guard hash != lastHash else { return }
        lastHash = hash
        continuation.yield(.toolCallsUpdated(calls: calls))
    }
}

private final class AFMSession: LLMSession {
    private let session: LanguageModelSession
    private let configuration: LLMSessionConfiguration
    private let pipeline: AFMSessionPipeline
    private var lastMaxContentLength: Int = 0
    private var lastReasoningSignature: Int = 0
    private var lastReasoningProbeSignature: Int = 0
    private var lastYieldedReasoningTokenCount: Int?
    private var lastYieldedReasoningEntryCount = 0
    private var didLogReasoningSignatureDump = false
    private var streamChunkIndex: Int = 0

    init(
        session: LanguageModelSession,
        configuration: LLMSessionConfiguration
    ) {
        self.session = session
        self.configuration = configuration
        self.pipeline = AFMSessionPipeline.current
    }

    func respond(to prompt: String, temperature: Double) async throws -> String {
        switch pipeline {
        case .legacy:
            let options = GenerationOptions(temperature: temperature)
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        case .profile:
            let response = try await session.respond(to: prompt)
            return response.content
        }
    }

    func currentContextUsage(contextLimit: Int) -> LLMContextUsage? {
        guard #available(iOS 27, *) else { return nil }
        return makeContextUsage(contextLimit: contextLimit)
    }

    func streamResponse(to prompt: LLMPrompt, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        return streamFoundationResponse(to: prompt, temperature: temperature)
    }

    private func streamFoundationResponse(to prompt: LLMPrompt, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let toolCallEmitter = StreamToolCallEmitter()
                ToolExecutionTracker.reset()
                var pollingTask: Task<Void, Never>?
                defer { pollingTask?.cancel() }

                do {
                    let supportsReasoning = AFMModelCatalog.supportsReasoning(configuration.model)
                    lastMaxContentLength = 0
                    if supportsReasoning {
                        streamChunkIndex = 0
                        lastReasoningProbeSignature = 0
                        lastYieldedReasoningTokenCount = nil
                        lastYieldedReasoningEntryCount = 0
                        didLogReasoningSignatureDump = false
                        AFMReasoningProbe.log(
                            "stream start model=\(configuration.model.rawValue) level=\(configuration.reasoningLevel.rawValue) pipeline=\(self.pipeline)"
                        )
                    }

                    let stream: LanguageModelSession.ResponseStream<String>
                    switch pipeline {
                    case .legacy:
                        let options = GenerationOptions(temperature: temperature)
                        stream = session.streamResponse(to: prompt.text, options: options)
                    case .profile:
                        if #available(iOS 27, *), !prompt.attachments.isEmpty {
                            let afmPrompt = AFMPromptBuilder.makePrompt(from: prompt)
                            if supportsReasoning {
                                let contextOptions = ContextOptions(
                                    reasoningLevel: configuration.reasoningLevel.toAFM()
                                )
                                stream = session.streamResponse(
                                    to: afmPrompt,
                                    options: GenerationOptions(temperature: temperature),
                                    contextOptions: contextOptions
                                )
                            } else {
                                stream = session.streamResponse(
                                    to: afmPrompt,
                                    options: GenerationOptions(temperature: temperature)
                                )
                            }
                        } else if #available(iOS 27, *), supportsReasoning {
                            let contextOptions = ContextOptions(
                                reasoningLevel: configuration.reasoningLevel.toAFM()
                            )
                            stream = session.streamResponse(
                                to: prompt.text,
                                options: GenerationOptions(temperature: temperature),
                                contextOptions: contextOptions
                            )
                        } else {
                            stream = session.streamResponse(
                                to: prompt.text,
                                options: GenerationOptions(temperature: temperature)
                            )
                        }
                    }

                    continuation.yield(.generationStarted)
                    pollingTask = Task {
                        while !Task.isCancelled {
                            let extracted = self.extractFromTranscript(preferredEntries: nil)
                            let fullText = self.resolvedResponseText(
                                transcriptContent: extracted.responseContent,
                                snapshotContent: "",
                                reasoningSnapshot: extracted.reasoningSnapshot
                            )
                            if fullText.count > self.lastMaxContentLength {
                                self.lastMaxContentLength = fullText.count
                                continuation.yield(.contentUpdated(fullText: fullText))
                            }
                            await toolCallEmitter.emitIfChanged(extracted.toolCalls, continuation: continuation)
                            self.yieldReasoningUpdate(extracted.reasoningSnapshot, continuation: continuation)
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }

                    var bestContent = ""
                    for try await response in stream {
                        try Task.checkCancellation()
                        streamChunkIndex += 1
                        if response.content.count > bestContent.count {
                            bestContent = response.content
                        }

                        let snapshotEntries: [Transcript.Entry]?
                        var streamUsageSummary: String?
                        var streamReasoningTokenCount: Int?
                        if #available(iOS 27, *) {
                            snapshotEntries = Array(response.transcriptEntries)
                            if supportsReasoning {
                                let usage = response.usage
                                streamReasoningTokenCount = usage.output.reasoningTokenCount
                                streamUsageSummary =
                                    "usage out=\(usage.output.totalTokenCount) reasoningTokens=\(usage.output.reasoningTokenCount) in=\(usage.input.totalTokenCount)"
                            }
                        } else {
                            snapshotEntries = nil
                        }

                        let extracted = extractFromTranscript(
                            preferredEntries: snapshotEntries,
                            probeStreamChunk: supportsReasoning ? streamChunkIndex : nil,
                            probeUsageSummary: streamUsageSummary,
                            reasoningTokenCount: streamReasoningTokenCount
                        )

                        let fullText = resolvedResponseText(
                            transcriptContent: extracted.responseContent,
                            snapshotContent: bestContent,
                            reasoningSnapshot: extracted.reasoningSnapshot
                        )
                        if fullText.count > lastMaxContentLength {
                            lastMaxContentLength = fullText.count
                        }
                        continuation.yield(.contentUpdated(fullText: fullText))
                        await toolCallEmitter.emitIfChanged(extracted.toolCalls, continuation: continuation)
                        yieldReasoningUpdate(extracted.reasoningSnapshot, continuation: continuation)
                    }

                    pollingTask?.cancel()

                    let finalReasoningTokenCount: Int?
                    if #available(iOS 27, *), supportsReasoning {
                        finalReasoningTokenCount = session.usage.output.reasoningTokenCount
                    } else {
                        finalReasoningTokenCount = nil
                    }
                    let finalExtraction = extractFromTranscript(
                        preferredEntries: nil,
                        probeStreamChunk: supportsReasoning ? -1 : nil,
                        probeUsageSummary: nil,
                        reasoningTokenCount: finalReasoningTokenCount
                    )
                    if #available(iOS 27, *) {
                        if supportsReasoning {
                            let usage = session.usage
                            AFMReasoningProbe.log(
                                "stream end sessionUsage out=\(usage.output.totalTokenCount) reasoningTokens=\(usage.output.reasoningTokenCount) signatureBytes=\(finalExtraction.reasoningSnapshot.signatureByteCount ?? 0) usableReasoningChars=\(finalExtraction.reasoningSnapshot.content?.count ?? 0)"
                            )
                        }
                        yieldReasoningUpdate(finalExtraction.reasoningSnapshot, continuation: continuation)
                    }
                    await toolCallEmitter.emitIfChanged(finalExtraction.toolCalls, continuation: continuation)

                    continuation.finish()
                } catch {
                    pollingTask?.cancel()
                    if AFMModelCatalog.supportsReasoning(configuration.model) {
                        AFMReasoningProbe.log("stream error: \(error)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    @available(iOS 27, *)
    private func makeContextUsage(contextLimit: Int) -> LLMContextUsage {
        let usage = session.usage
        return LLMContextUsage(
            usedTokens: usage.totalTokenCount,
            contextLimit: contextLimit,
            inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount,
            reasoningTokens: usage.output.reasoningTokenCount,
            model: configuration.model
        )
    }

    private func resolvedResponseText(
        transcriptContent: String,
        snapshotContent: String,
        reasoningSnapshot: ReasoningSnapshot
    ) -> String {
        let transcript = transcriptContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            if snapshotContent.count > transcriptContent.count,
               !isReasoningLeak(snapshotContent, reasoningSnapshot: reasoningSnapshot) {
                return snapshotContent
            }
            return transcriptContent
        }

        if isReasoningLeak(snapshotContent, reasoningSnapshot: reasoningSnapshot) {
            return ""
        }
        return snapshotContent
    }

    private func isReasoningLeak(_ text: String, reasoningSnapshot: ReasoningSnapshot) -> Bool {
        let snapshot = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.isEmpty {
            return true
        }
        if isPlaceholderReasoningText(snapshot) {
            return true
        }
        guard let reasoning = reasoningSnapshot.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reasoning.isEmpty else {
            return false
        }
        return snapshot == reasoning || reasoning.hasPrefix(snapshot) || snapshot.hasPrefix(reasoning)
    }

    private func yieldReasoningUpdate(
        _ snapshot: ReasoningSnapshot,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        let content = snapshot.content.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let tokenCount = snapshot.tokenCount
        let entryCount = snapshot.entryCount

        let contentSignature = content?.hashValue ?? 0
        let tokenChanged = tokenCount != lastYieldedReasoningTokenCount
        let contentChanged = content != nil && contentSignature != lastReasoningSignature
        let entriesChanged = entryCount > lastYieldedReasoningEntryCount
        guard contentChanged || tokenChanged || entriesChanged else { return }

        if contentChanged {
            lastReasoningSignature = contentSignature
        }
        if tokenChanged {
            lastYieldedReasoningTokenCount = tokenCount
        }
        if entriesChanged {
            lastYieldedReasoningEntryCount = entryCount
        }

        AFMReasoningProbe.log(
            "yielding reasoningUpdated chars=\(content?.count ?? 0) tokens=\(tokenCount.map(String.init) ?? "nil") entries=\(entryCount) signatureBytes=\(snapshot.signatureByteCount ?? 0)"
                + (content.map { " preview=\(AFMReasoningProbe.preview($0))" } ?? "")
        )
        continuation.yield(.reasoningUpdated(content: content, tokenCount: tokenCount, entryCount: entryCount))
    }

    private func extractFromTranscript(
        preferredEntries: [Transcript.Entry]?,
        probeStreamChunk: Int? = nil,
        probeUsageSummary: String? = nil,
        reasoningTokenCount: Int? = nil
    ) -> TranscriptExtraction {
        var toolCalls: [LLMToolCallEvent] = []
        var fullContent = ""

        let fullEntries = Array(session.transcript)
        let lastPromptIndex = indexOfLastPrompt(in: fullEntries)

        let turnEntries: [Transcript.Entry]
        if lastPromptIndex >= 0, lastPromptIndex < fullEntries.count - 1 {
            turnEntries = Array(fullEntries[(lastPromptIndex + 1)...])
        } else {
            turnEntries = []
        }

        // Streaming snapshots often omit tool-call entries; always read those from the live session transcript.
        let contentEntries: [Transcript.Entry]
        if let preferredEntries, !preferredEntries.isEmpty {
            contentEntries = preferredEntries
        } else {
            contentEntries = turnEntries
        }

        for entry in contentEntries {
            guard case .response(let response) = entry else { continue }
            let responseText = textFromSegments(response.segments)
            if !responseText.isEmpty {
                if !fullContent.isEmpty {
                    fullContent += "\n\n"
                }
                fullContent += responseText
            }
        }

        let toolEntries = mergedToolEntries(preferredEntries: preferredEntries, turnEntries: turnEntries)
        toolCalls = mergeToolCalls(
            transcript: extractToolCalls(from: toolEntries),
            active: ToolExecutionTracker.activeToolCallEvents()
        )

        let snapshotReasoning: String
        let turnReasoning: String
        var snapshotEntryCount = 0
        var turnEntryCount = 0
        var rawProbeDetails: String?
        var probeSignatureData: Data?
        var probeDescribing: String?
        if #available(iOS 27, *) {
            if let preferredEntries {
                let snapshotProbe = extractReasoningProbe(from: Array(preferredEntries), source: "snapshot")
                snapshotReasoning = snapshotProbe.text
                snapshotEntryCount = snapshotProbe.entryCount
                rawProbeDetails = snapshotProbe.details
                probeSignatureData = snapshotProbe.signatureData
                probeDescribing = snapshotProbe.describing
            } else {
                snapshotReasoning = ""
            }
            let turnProbe = extractReasoningProbe(from: turnEntries, source: "turn")
            turnReasoning = turnProbe.text
            turnEntryCount = turnProbe.entryCount
            if rawProbeDetails == nil || turnProbe.text.count > snapshotReasoning.count {
                rawProbeDetails = turnProbe.details
                probeSignatureData = turnProbe.signatureData
                probeDescribing = turnProbe.describing
            }
        } else {
            snapshotReasoning = ""
            turnReasoning = ""
        }
        let mergedReasoning = preferredBestReasoningText(snapshotReasoning, turnReasoning)
        let reasoningSnapshot = makeReasoningSnapshot(
            text: mergedReasoning,
            tokenCount: reasoningTokenCount,
            signatureByteCount: probeSignatureData?.count,
            entryCount: max(snapshotEntryCount, turnEntryCount)
        )

        if let probeStreamChunk {
            logReasoningProbeIfNeeded(
                streamChunk: probeStreamChunk,
                snapshotEntries: preferredEntries,
                turnEntries: turnEntries,
                snapshotReasoning: snapshotReasoning,
                turnReasoning: turnReasoning,
                usableReasoning: reasoningSnapshot.content,
                usageSummary: probeUsageSummary,
                rawDetails: rawProbeDetails,
                signatureData: probeSignatureData,
                describing: probeDescribing
            )
        }

        return TranscriptExtraction(
            toolCalls: toolCalls,
            responseContent: fullContent,
            reasoningSnapshot: reasoningSnapshot
        )
    }

    private func logReasoningProbeIfNeeded(
        streamChunk: Int,
        snapshotEntries: [Transcript.Entry]?,
        turnEntries: [Transcript.Entry],
        snapshotReasoning: String,
        turnReasoning: String,
        usableReasoning: String?,
        usageSummary: String?,
        rawDetails: String?,
        signatureData: Data?,
        describing: String?
    ) {
        let rawBest = turnReasoning.count >= snapshotReasoning.count ? turnReasoning : snapshotReasoning
        // Dedupe on reasoning surface only — ignore per-token usage churn.
        let probeSignature = [
            streamChunk == -1 ? "final" : "chunk",
            entryKindSummary(snapshotEntries ?? []),
            entryKindSummary(turnEntries),
            "snapChars=\(snapshotReasoning.count)",
            "turnChars=\(turnReasoning.count)",
            "usable=\(usableReasoning?.count ?? 0)",
            "placeholder=\(isPlaceholderReasoningText(rawBest.trimmingCharacters(in: .whitespacesAndNewlines)))",
            "sigBytes=\(signatureData?.count ?? 0)"
        ].joined(separator: "|").hashValue

        // Always log the final pass; otherwise only when the probe surface changes.
        guard streamChunk == -1 || probeSignature != lastReasoningProbeSignature else { return }
        lastReasoningProbeSignature = probeSignature

        let label = streamChunk == -1 ? "final" : "chunk#\(streamChunk)"
        let snapshotKinds = entryKindSummary(snapshotEntries ?? [])
        let turnKinds = entryKindSummary(turnEntries)
        let trimmedRaw = rawBest.trimmingCharacters(in: .whitespacesAndNewlines)
        let classification: String
        if trimmedRaw.isEmpty {
            classification = "missing"
        } else if isPlaceholderReasoningText(trimmedRaw) {
            classification = "placeholder"
        } else {
            classification = "readable"
        }

        AFMReasoningProbe.log(
            "\(label) snapshot=[\(snapshotKinds)] turn=[\(turnKinds)] class=\(classification) rawChars=\(trimmedRaw.count) usableChars=\(usableReasoning?.count ?? 0) \(usageSummary ?? "")"
        )
        if let rawDetails, !rawDetails.isEmpty {
            AFMReasoningProbe.log("\(label) details: \(rawDetails)")
        }
        if !trimmedRaw.isEmpty {
            AFMReasoningProbe.log("\(label) rawPreview=\(AFMReasoningProbe.preview(trimmedRaw))")
        }
        if let usableReasoning, !usableReasoning.isEmpty {
            AFMReasoningProbe.log("\(label) usablePreview=\(AFMReasoningProbe.preview(usableReasoning))")
        }
        if let describing, !describing.isEmpty {
            AFMReasoningProbe.log("\(label) describing=\(AFMReasoningProbe.preview(describing, limit: 300))")
        }
        if let signatureData, !signatureData.isEmpty, !didLogReasoningSignatureDump {
            didLogReasoningSignatureDump = true
            let utf8Attempt = String(data: signatureData, encoding: .utf8)
            let hex = signatureData.prefix(64).map { String(format: "%02x", $0) }.joined()
            let hexSuffix = signatureData.count > 64 ? "…" : ""
            AFMReasoningProbe.log(
                "signature dump bytes=\(signatureData.count) utf8=\(utf8Attempt.map { AFMReasoningProbe.preview($0, limit: 120) } ?? "<non-utf8>") hex64=\(hex)\(hexSuffix)"
            )
        }
    }

    private func entryKindSummary(_ entries: [Transcript.Entry]) -> String {
        guard !entries.isEmpty else { return "none" }
        return entries.map { entry in
            if #available(iOS 27, *) {
                switch entry {
                case .instructions: return "instructions"
                case .prompt: return "prompt"
                case .response: return "response"
                case .toolCalls: return "toolCalls"
                case .toolOutput: return "toolOutput"
                case .reasoning: return "reasoning"
                @unknown default: return "other"
                }
            } else {
                switch entry {
                case .instructions: return "instructions"
                case .prompt: return "prompt"
                case .response: return "response"
                case .toolCalls: return "toolCalls"
                case .toolOutput: return "toolOutput"
                @unknown default: return "other"
                }
            }
        }.joined(separator: ",")
    }

    private func mergedToolEntries(
        preferredEntries: [Transcript.Entry]?,
        turnEntries: [Transcript.Entry]
    ) -> [Transcript.Entry] {
        guard let preferredEntries, !preferredEntries.isEmpty else {
            return turnEntries
        }

        var merged = turnEntries
        for entry in preferredEntries {
            switch entry {
            case .toolCalls, .toolOutput:
                merged.append(entry)
            default:
                break
            }
        }
        return merged
    }

    private func extractToolCalls(from entries: [Transcript.Entry]) -> [LLMToolCallEvent] {
        var toolCalls: [LLMToolCallEvent] = []
        var outputsByID: [String: String] = [:]

        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    guard !toolCalls.contains(where: { $0.transcriptID == call.id }) else { continue }
                    toolCalls.append(
                        LLMToolCallEvent(
                            transcriptID: call.id,
                            toolName: call.toolName,
                            toolDescription: call.toolName,
                            arguments: call.arguments.jsonString,
                            status: .executing
                        )
                    )
                }
            case .toolOutput(let output):
                outputsByID[output.id] = textFromSegments(output.segments)
            default:
                break
            }
        }

        for index in toolCalls.indices {
            if let result = outputsByID[toolCalls[index].transcriptID] {
                toolCalls[index].status = .completed
                toolCalls[index].result = result
            }
        }

        return toolCalls
    }

    private func mergeToolCalls(
        transcript: [LLMToolCallEvent],
        active: [LLMToolCallEvent]
    ) -> [LLMToolCallEvent] {
        var merged = transcript
        for activeCall in active {
            let alreadyRepresented = merged.contains { existing in
                guard existing.toolName == activeCall.toolName else { return false }
                if existing.status == .completed || existing.status == .failed {
                    return true
                }
                return normalizedArguments(existing.arguments) == normalizedArguments(activeCall.arguments)
            }
            if !alreadyRepresented {
                merged.append(activeCall)
            }
        }
        return merged
    }

    private func normalizedArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let normalized = object.mapValues { value in
            if let number = value as? NSNumber {
                return String(describing: number)
            }
            return String(describing: value)
        }
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "|")

        return normalized
    }

    private func indexOfLastPrompt(in entries: [Transcript.Entry]) -> Int {
        for (index, entry) in entries.enumerated().reversed() {
            if case .prompt = entry {
                return index
            }
        }
        return -1
    }

    private func preferredBestReasoningText(_ lhs: String, _ rhs: String) -> String {
        let left = sanitizeReasoningText(lhs)
        let right = sanitizeReasoningText(rhs)
        return right.count >= left.count ? right : left
    }

    private func makeReasoningSnapshot(
        text: String,
        tokenCount: Int?,
        signatureByteCount: Int?,
        entryCount: Int
    ) -> ReasoningSnapshot {
        let sanitized = sanitizeReasoningText(text)
        return ReasoningSnapshot(
            content: sanitized.isEmpty ? nil : sanitized,
            tokenCount: tokenCount,
            signatureByteCount: signatureByteCount,
            entryCount: entryCount
        )
    }

    private func sanitizeReasoningText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlaceholderReasoningText(trimmed) else { return "" }
        return trimmed
    }

    private func isPlaceholderReasoningText(_ text: String) -> Bool {
        if text == "Reasoning" {
            return true
        }

        let pattern = #"^\(Reasoning [0-9A-Fa-f-]+\)$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    @available(iOS 27, *)
    private func extractReasoningText(from entries: [Transcript.Entry]) -> String {
        extractReasoningProbe(from: entries, source: "text").text
    }

    @available(iOS 27, *)
    private func extractReasoningProbe(
        from entries: [Transcript.Entry],
        source: String
    ) -> (text: String, details: String, signatureData: Data?, describing: String?, entryCount: Int) {
        var reasoningContent = ""
        var detailParts: [String] = []
        var signatureData: Data?
        var describing: String?
        var entryCount = 0

        for entry in entries {
            guard case .reasoning(let reasoning) = entry else { continue }
            entryCount += 1
            let segmentText = reasoningText(from: reasoning)
            let descriptionText = reasoning.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let describingText = String(describing: reasoning)
            let metadataKeys = reasoning.metadata.keys.sorted().joined(separator: ",")
            let segmentKinds = reasoning.segments.map { segment -> String in
                switch segment {
                case .text: return "text"
                case .structure: return "structure"
                case .attachment: return "attachment"
//                case .custom: return "custom"
                @unknown default: return "other"
                }
            }.joined(separator: "+")

            // Prefer segment text; fall back to description if segments are empty but description looks real.
            let preferredText: String
            if !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preferredText = segmentText
            } else if !descriptionText.isEmpty, !isPlaceholderReasoningText(descriptionText) {
                preferredText = descriptionText
            } else {
                preferredText = segmentText.isEmpty ? descriptionText : segmentText
            }

            if signatureData == nil {
                signatureData = reasoning.signature
            }
            if describing == nil {
                describing = describingText
            }

            detailParts.append(
                "\(source) id=\(reasoning.id) segs=[\(segmentKinds.isEmpty ? "none" : segmentKinds)] segChars=\(segmentText.count) descChars=\(descriptionText.count) describingChars=\(describingText.count) signatureBytes=\(reasoning.signature?.count ?? 0) metaKeys=[\(metadataKeys.isEmpty ? "none" : metadataKeys)] placeholder=\(isPlaceholderReasoningText(preferredText.trimmingCharacters(in: .whitespacesAndNewlines)))"
            )

            guard !preferredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !reasoningContent.isEmpty {
                reasoningContent += "\n\n"
            }
            reasoningContent += preferredText
        }

        return (reasoningContent, detailParts.joined(separator: " || "), signatureData, describing, entryCount)
    }

    private func textFromSegments(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            if case .text(let textSegment) = segment {
                return textSegment.content
            }
            if case .structure(let structuredSegment) = segment {
                return String(describing: structuredSegment.content)
            }
            return nil
        }.joined(separator: "\n")
    }

    @available(iOS 27, *)
    private func reasoningText(from reasoning: Transcript.Reasoning) -> String {
        reasoning.segments.compactMap { segment -> String? in
            guard case .text(let textSegment) = segment else { return nil }
            return textSegment.content
        }.joined(separator: "\n")
    }
}

#if AFM_MLX
private final class MLXSession: LLMSession {
    private let modelID: String
    private let instructions: String
    private let configuration: LLMSessionConfiguration
    private let enabledToolIDs: [AppToolID]
    private let attachmentRegistry: AttachmentRegistry?

    init(
        modelID: String,
        instructions: String,
        configuration: LLMSessionConfiguration,
        enabledToolIDs: [AppToolID],
        attachmentRegistry: AttachmentRegistry?
    ) {
        self.modelID = modelID
        self.instructions = instructions
        self.configuration = configuration
        self.enabledToolIDs = enabledToolIDs
        self.attachmentRegistry = attachmentRegistry
    }

    func respond(to prompt: String, temperature: Double) async throws -> String {
        var text = ""
        for try await event in streamResponse(to: LLMPrompt(text: prompt), temperature: temperature) {
            if case .contentUpdated(let fullText) = event {
                text = fullText
            }
        }
        return text
    }

    func streamResponse(to prompt: LLMPrompt, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        MLXTokenStream.events(
            modelID: modelID,
            instructions: instructions,
            history: configuration.history,
            prompt: prompt,
            temperature: temperature,
            thinkingEnabled: configuration.thinkingEnabled,
            thinkingBudgetTokens: configuration.thinkingBudgetTokens,
            enabledToolIDs: enabledToolIDs,
            attachmentRegistry: attachmentRegistry
        )
    }
}
#endif
