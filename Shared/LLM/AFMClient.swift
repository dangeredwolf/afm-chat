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
    func createSession(instructions: String, tools: [LLMTool]) -> LLMSession {
        // Bridge tools: expect AnyLLMTool with providerPayloads["afmTool"] as any Tool
        let afmTools: [any Tool] = tools.compactMap { tool in
            if let anyTool = tool as? AnyLLMTool,
               let afmTool = anyTool.providerPayloads["afmTool"] as? any Tool {
                return afmTool
            }
            return nil
        }

        let session = LanguageModelSession(
            tools: afmTools,
            instructions: instructions
        )
        return AFMSession(session: session)
    }
}

private final class AFMSession: LLMSession {
    private let session: LanguageModelSession
    private var lastMaxContentLength: Int = 0
    private var lastToolCallsHash: Int = 0

    init(session: LanguageModelSession) {
        self.session = session
    }

    func respond(to prompt: String, temperature: Double) async throws -> String {
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }

    func streamResponse(to prompt: String, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let options = GenerationOptions(temperature: temperature)
                    let stream = session.streamResponse(to: prompt, options: options)
                    var bestContent = ""
                    for try await response in stream {
                        // Track longest response content we have seen
                        if response.content.count > lastMaxContentLength {
                            lastMaxContentLength = response.content.count
                            bestContent = response.content
                        }

                        // Attempt to extract fuller content and tool calls from transcript
                        let (calls, transcriptContent) = extractToolCallsAndContentFromTranscript()

                        // Prefer transcript content if it's longer
                        let fullText: String = transcriptContent.count >= bestContent.count ? transcriptContent : bestContent
                        continuation.yield(.contentUpdated(fullText: fullText))

                        // Emit tool calls only when they change
                        let callsHash = calls.map { $0.toolName + $0.arguments + ($0.result ?? "") + ($0.error ?? "") + $0.status.rawValue }.joined().hashValue
                        if callsHash != lastToolCallsHash {
                            lastToolCallsHash = callsHash
                            continuation.yield(.toolCallsUpdated(calls: calls))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // Extract tool call information and reconstruct full content from the transcript
    private func extractToolCallsAndContentFromTranscript() -> ([LLMToolCallEvent], String) {
        var toolCalls: [LLMToolCallEvent] = []
        var toolOutputs: [String] = []
        var fullContent = ""

        let transcript = session.transcript
        let entries = Array(transcript)

        // Find the most recent user prompt index
        var lastPromptIndex = -1
        for (index, entry) in entries.enumerated().reversed() {
            if case .prompt(_) = entry {
                lastPromptIndex = index
                break
            }
        }

        // Collect tool calls, outputs, and responses that occurred after the last prompt
        if lastPromptIndex >= 0 && lastPromptIndex < entries.count - 1 {
            let relevantEntries = Array(entries[(lastPromptIndex + 1)...])

            for entry in relevantEntries {
                switch entry {
                case .response(let response):
                    let responseText = response.segments.compactMap { segment in
                        switch segment {
                        case .text(let textSegment):
                            return textSegment.content
                        default:
                            return nil
                        }
                    }.joined(separator: "")
                    if !responseText.isEmpty {
                        if !fullContent.isEmpty {
                            fullContent += "\n\n"
                        }
                        fullContent += responseText
                    }
                case .toolCalls(let calls):
                    for call in calls {
                        let callEvent = LLMToolCallEvent(
                            toolName: call.toolName,
                            toolDescription: call.toolName, // description not available here; UI can map
                            arguments: String(describing: call.arguments),
                            status: .executing
                        )
                        toolCalls.append(callEvent)
                    }
                case .toolOutput(let output):
                    let outputContent = output.segments.compactMap { segment in
                        switch segment {
                        case .text(let textSegment):
                            return textSegment.content
                        case .structure(let structuredSegment):
                            return String(describing: structuredSegment.content)
                        @unknown default:
                            return nil
                        }
                    }.joined(separator: "\n")
                    toolOutputs.append(outputContent)
                default:
                    break
                }
            }

            // Second pass: update tool call statuses by matching order
            for i in toolCalls.indices {
                if i < toolOutputs.count {
                    toolCalls[i].status = .completed
                    toolCalls[i].result = toolOutputs[i]
                }
            }
        }

        return (toolCalls, fullContent)
    }
}


