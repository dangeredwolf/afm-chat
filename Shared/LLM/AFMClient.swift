import Foundation
import FoundationModels

// Apple Foundation Models implementation of LLMClient

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
        return AFMSession(session: session, configuration: configuration)
    }
}

private struct TranscriptExtraction {
    var toolCalls: [LLMToolCallEvent]
    var responseContent: String
    var reasoningSnapshot: ReasoningSnapshot
}

private struct ReasoningSnapshot {
    var content: String?
}

private final class AFMSession: LLMSession {
    private let session: LanguageModelSession
    private let configuration: LLMSessionConfiguration
    private let pipeline: AFMSessionPipeline
    private var lastMaxContentLength: Int = 0
    private var lastToolCallsHash: Int = 0
    private var lastReasoningSignature: Int = 0

    init(session: LanguageModelSession, configuration: LLMSessionConfiguration) {
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
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream: LanguageModelSession.ResponseStream<String>
                    switch pipeline {
                    case .legacy:
                        let options = GenerationOptions(temperature: temperature)
                        stream = session.streamResponse(to: prompt.text, options: options)
                    case .profile:
                        if #available(iOS 27, *), !prompt.attachments.isEmpty {
                            let afmPrompt = AFMPromptBuilder.makePrompt(from: prompt)
                            if AFMModelCatalog.supportsReasoning(configuration.model) {
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
                        } else if #available(iOS 27, *), AFMModelCatalog.supportsReasoning(configuration.model) {
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

                    var bestContent = ""
                    for try await response in stream {
                        if response.content.count > lastMaxContentLength {
                            lastMaxContentLength = response.content.count
                            bestContent = response.content
                        }

                        let snapshotEntries: [Transcript.Entry]?
                        if #available(iOS 27, *) {
                            snapshotEntries = Array(response.transcriptEntries)
                        } else {
                            snapshotEntries = nil
                        }

                        let extracted = extractFromTranscript(preferredEntries: snapshotEntries)

                        let fullText: String = extracted.responseContent.count >= bestContent.count
                            ? extracted.responseContent
                            : bestContent
                        continuation.yield(.contentUpdated(fullText: fullText))

                        let callsHash = extracted.toolCalls
                            .map { $0.toolName + $0.arguments + ($0.result ?? "") + ($0.error ?? "") + $0.status.rawValue }
                            .joined()
                            .hashValue
                        if callsHash != lastToolCallsHash {
                            lastToolCallsHash = callsHash
                            continuation.yield(.toolCallsUpdated(calls: extracted.toolCalls))
                        }

                        yieldReasoningUpdate(extracted.reasoningSnapshot, continuation: continuation)
                    }

                    if #available(iOS 27, *) {
                        let finalExtraction = extractFromTranscript(preferredEntries: nil)
                        yieldReasoningUpdate(finalExtraction.reasoningSnapshot, continuation: continuation)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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

    private func yieldReasoningUpdate(
        _ snapshot: ReasoningSnapshot,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        guard let content = snapshot.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let signature = content.hashValue
        guard signature != lastReasoningSignature else { return }

        lastReasoningSignature = signature
        continuation.yield(.reasoningUpdated(content: content))
    }

    private func extractFromTranscript(
        preferredEntries: [Transcript.Entry]?
    ) -> TranscriptExtraction {
        var toolCalls: [LLMToolCallEvent] = []
        var toolOutputs: [String] = []
        var fullContent = ""

        let fullEntries = Array(session.transcript)
        let lastPromptIndex = indexOfLastPrompt(in: fullEntries)

        let responseEntries: [Transcript.Entry]
        if let preferredEntries, !preferredEntries.isEmpty {
            responseEntries = preferredEntries
        } else if lastPromptIndex >= 0, lastPromptIndex < fullEntries.count - 1 {
            responseEntries = Array(fullEntries[(lastPromptIndex + 1)...])
        } else {
            responseEntries = []
        }

        let turnEntries: [Transcript.Entry]
        if lastPromptIndex >= 0, lastPromptIndex < fullEntries.count - 1 {
            turnEntries = Array(fullEntries[(lastPromptIndex + 1)...])
        } else {
            turnEntries = []
        }

        for entry in responseEntries {
            switch entry {
            case .response(let response):
                let responseText = textFromSegments(response.segments)
                if !responseText.isEmpty {
                    if !fullContent.isEmpty {
                        fullContent += "\n\n"
                    }
                    fullContent += responseText
                }
            case .toolCalls(let calls):
                for call in calls {
                    let callEvent = LLMToolCallEvent(
                        transcriptID: call.id,
                        toolName: call.toolName,
                        toolDescription: call.toolName,
                        arguments: call.arguments.jsonString,
                        status: .executing
                    )
                    toolCalls.append(callEvent)
                }
            case .toolOutput(let output):
                toolOutputs.append(textFromSegments(output.segments))
            default:
                break
            }
        }

        let snapshotReasoning: String
        let turnReasoning: String
        if #available(iOS 27, *) {
            snapshotReasoning = preferredEntries.map { extractReasoningText(from: Array($0)) } ?? ""
            turnReasoning = extractReasoningText(from: turnEntries)
        } else {
            snapshotReasoning = ""
            turnReasoning = ""
        }
        let mergedReasoning = preferredBestReasoningText(snapshotReasoning, turnReasoning)

        for i in toolCalls.indices {
            if i < toolOutputs.count {
                toolCalls[i].status = .completed
                toolCalls[i].result = toolOutputs[i]
            }
        }

        return TranscriptExtraction(
            toolCalls: toolCalls,
            responseContent: fullContent,
            reasoningSnapshot: makeReasoningSnapshot(text: mergedReasoning)
        )
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

    private func makeReasoningSnapshot(text: String) -> ReasoningSnapshot {
        let sanitized = sanitizeReasoningText(text)
        return ReasoningSnapshot(
            content: sanitized.isEmpty ? nil : sanitized
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
        var reasoningContent = ""
        for entry in entries {
            guard case .reasoning(let reasoning) = entry else { continue }
            let text = reasoningText(from: reasoning)
            guard !text.isEmpty else { continue }
            if !reasoningContent.isEmpty {
                reasoningContent += "\n\n"
            }
            reasoningContent += text
        }
        return reasoningContent
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
