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

enum AFMTranscriptBuilder {
    static func entries(from history: [LLMHistoryEntry]) -> [Transcript.Entry] {
        history.flatMap { message in
            if message.isUser {
                return [promptEntry(content: message.content, attachments: message.attachments)]
            }
            return assistantEntries(for: message)
        }
    }

    private static func promptEntry(content: String, attachments: [LLMAttachment] = []) -> Transcript.Entry {
        var segments: [Transcript.Segment] = []
        if #available(iOS 27, *) {
            segments.append(contentsOf: AFMPromptBuilder.attachmentSegments(from: attachments))
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(.text(Transcript.TextSegment(content: content)))
        }
        if segments.isEmpty {
            segments.append(.text(Transcript.TextSegment(content: "")))
        }
        let prompt = Transcript.Prompt(segments: segments)
        return .prompt(prompt)
    }

    private static func assistantEntries(for message: LLMHistoryEntry) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []

        let hydratedToolCalls = message.toolCalls.filter { $0.result != nil || $0.error != nil }
        if !hydratedToolCalls.isEmpty {
            let calls = hydratedToolCalls.map { toolCall in
                Transcript.ToolCall(
                    id: toolCall.transcriptID,
                    toolName: toolCall.toolName,
                    arguments: generatedContent(toolName: toolCall.toolName, argumentsJSON: toolCall.argumentsJSON)
                )
            }
            entries.append(.toolCalls(Transcript.ToolCalls(calls)))

            for toolCall in hydratedToolCalls {
                let outputText = toolCall.result ?? toolCall.error ?? ""
                let segment = Transcript.Segment.text(Transcript.TextSegment(content: outputText))
                let output = Transcript.ToolOutput(
                    id: toolCall.transcriptID,
                    toolName: toolCall.toolName,
                    segments: [segment]
                )
                entries.append(.toolOutput(output))
            }
        }

        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let textSegment = Transcript.Segment.text(Transcript.TextSegment(content: message.content))
            let response = Transcript.Response(assetIDs: [], segments: [textSegment])
            entries.append(.response(response))
        }

        return entries
    }

    private static func generatedContent(toolName: String, argumentsJSON: String) -> GeneratedContent {
        if let content = try? GeneratedContent(json: argumentsJSON) {
            return content
        }

        switch toolName {
        case "Web Search":
            if let query = extractPropertyValue(named: "query", from: argumentsJSON) {
                return GeneratedContent(properties: ["query": query])
            }
        case "Code Interpreter":
            if let code = extractPropertyValue(named: "code", from: argumentsJSON) {
                return GeneratedContent(properties: ["code": code])
            }
        default:
            break
        }

        return GeneratedContent(properties: [:])
    }

    private static func extractPropertyValue(named property: String, from text: String) -> String? {
        let patterns = [
            #""\#(property)"\s*:\s*"((?:\\.|[^"\\])*)""#,
            #"\#(property)\s*:\s*"((?:\\.|[^"\\])*)"#,
            #"\#(property)\s*=\s*"((?:\\.|[^"\\])*)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[range])
        }

        return nil
    }
}

enum AFMSessionFactory {
    static func makeSession(
        instructions: String,
        tools: [any Tool],
        configuration: LLMSessionConfiguration
    ) -> LanguageModelSession {
        let resolved = AFMModelCatalog.resolvedConfiguration(configuration)
        let historyEntries = AFMTranscriptBuilder.entries(from: resolved.history)

        if #available(iOS 27, *) {
            return makeProfileSession(
                instructions: instructions,
                tools: tools,
                configuration: resolved,
                history: historyEntries
            )
        } else if historyEntries.isEmpty {
            return LanguageModelSession(
                model: AFMModelCatalog.systemLanguageModel(guardrails: resolved.guardrails),
                tools: tools,
                instructions: instructions
            )
        } else {
            return LanguageModelSession(
                model: AFMModelCatalog.systemLanguageModel(guardrails: resolved.guardrails),
                tools: tools,
                transcript: Transcript(entries: historyEntries)
            )
        }
    }

    @available(iOS 27, *)
    private static func makeProfileSession(
        instructions: String,
        tools: [any Tool],
        configuration: LLMSessionConfiguration,
        history: [Transcript.Entry]
    ) -> LanguageModelSession {
        let model = AFMModelCatalog.languageModel(
            for: configuration.model,
            guardrails: configuration.guardrails
        )

        var profile = LanguageModelSession.Profile {
            ChatSessionInstructions(prompt: instructions, tools: tools)
        }
        .model(model)
        .temperature(configuration.temperature)

        if AFMModelCatalog.supportsReasoning(configuration.model) {
            profile = profile.reasoningLevel(configuration.reasoningLevel.toAFM())
        }

        return LanguageModelSession(profile: profile, history: history)
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

@available(iOS 27, *)
enum AFMPromptBuilder {
    static func makePrompt(from llmPrompt: LLMPrompt) -> Prompt {
        let images = llmPrompt.attachments.filter(\.isImage)
        let imageParts = images.map { Attachment(imageURL: $0.fileURL).label($0.label) }
        let trimmed = llmPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsupported = llmPrompt.attachments.filter { !$0.isImage }.map(\.label)
        let fileNote = unsupported.isEmpty
            ? nil
            : "Attached files (not sent as images): " + unsupported.joined(separator: ", ")

        if imageParts.isEmpty {
            if let fileNote {
                return Prompt(trimmed.isEmpty ? fileNote : "\(trimmed)\n\n\(fileNote)")
            }
            return Prompt(trimmed)
        }

        let imagesPrompt = PromptBuilder.buildArray(imageParts)
        return Prompt {
            imagesPrompt
            if !trimmed.isEmpty {
                trimmed
            }
            if let fileNote {
                fileNote
            }
        }
    }

    static func promptSegments(from llmPrompt: LLMPrompt) -> [Transcript.Segment] {
        var segments = attachmentSegments(from: llmPrompt.attachments)
        let trimmed = llmPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(.text(Transcript.TextSegment(content: llmPrompt.text)))
        }
        return segments
    }

    static func attachmentSegments(from attachments: [LLMAttachment]) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var unsupportedFileLabels: [String] = []

        for attachment in attachments {
            if attachment.isImage {
                let imageAttachment = Transcript.ImageAttachment(imageURL: attachment.fileURL)
                let segment = Transcript.AttachmentSegment(
                    content: .image(imageAttachment),
                    label: attachment.label
                )
                segments.append(.attachment(segment))
            } else {
                unsupportedFileLabels.append(attachment.label)
            }
        }

        if !unsupportedFileLabels.isEmpty {
            let note = "Attached files (not sent as images): " + unsupportedFileLabels.joined(separator: ", ")
            segments.append(.text(Transcript.TextSegment(content: note)))
        }

        return segments
    }
}
