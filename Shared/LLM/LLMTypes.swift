import Foundation

// Provider-agnostic LLM abstractions

public enum LLMReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case moderate
    case deep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .deep: return "Deep"
        }
    }

    public var description: String {
        switch self {
        case .light: return "Quick responses with minimal analysis"
        case .moderate: return "Balanced thinking and response speed"
        case .deep: return "More thorough analysis before responding"
        }
    }
}

public enum LLMModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice
    case privateCloudCompute

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: return "On-Device"
        case .privateCloudCompute: return "Private Cloud Compute"
        }
    }

    public var description: String {
        switch self {
        case .onDevice:
            return "Runs locally on your device. Fast and private, with a smaller context window."
        case .privateCloudCompute:
            return "Uses Apple's Private Cloud Compute for stronger reasoning and a larger context window."
        }
    }
}

public struct LLMModelOption: Identifiable, Sendable {
    public let choice: LLMModelChoice
    public let isAvailable: Bool
    public let supportsReasoning: Bool
    public let unavailabilityNote: String?

    public var id: String { choice.id }
    public var displayName: String { choice.displayName }
    public var description: String { choice.description }
}

public struct LLMContextUsage: Equatable, Sendable {
    public var usedTokens: Int
    public var contextLimit: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var model: LLMModelChoice

    public init(
        usedTokens: Int,
        contextLimit: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        model: LLMModelChoice
    ) {
        self.usedTokens = usedTokens
        self.contextLimit = contextLimit
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.model = model
    }

    public var remainingTokens: Int {
        max(0, contextLimit - usedTokens)
    }

    public var fillFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(usedTokens) / Double(contextLimit))
    }
}

public struct LLMHistoryToolCall: Sendable {
    public let transcriptID: String
    public let toolName: String
    public let argumentsJSON: String
    public let result: String?
    public let error: String?

    public init(
        transcriptID: String,
        toolName: String,
        argumentsJSON: String,
        result: String? = nil,
        error: String? = nil
    ) {
        self.transcriptID = transcriptID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.error = error
    }
}

public struct LLMAttachment: Sendable {
    public let label: String
    public let fileURL: URL
    public let isImage: Bool

    public init(label: String, fileURL: URL, isImage: Bool) {
        self.label = label
        self.fileURL = fileURL
        self.isImage = isImage
    }
}

public struct LLMPrompt: Sendable {
    public let text: String
    public let attachments: [LLMAttachment]

    public init(text: String = "", attachments: [LLMAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

public struct LLMHistoryEntry: Sendable {
    public let isUser: Bool
    public let content: String
    public let attachments: [LLMAttachment]
    public let toolCalls: [LLMHistoryToolCall]

    public init(
        isUser: Bool,
        content: String,
        attachments: [LLMAttachment] = [],
        toolCalls: [LLMHistoryToolCall] = []
    ) {
        self.isUser = isUser
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
    }
}

public enum LLMGuardrailsMode: String, Codable, Sendable {
    case `default`
    case permissiveContentTransformations
}

public struct LLMSessionConfiguration: Sendable {
    public var model: LLMModelChoice
    public var temperature: Double
    public var reasoningLevel: LLMReasoningLevel
    public var history: [LLMHistoryEntry]
    public var guardrails: LLMGuardrailsMode

    public init(
        model: LLMModelChoice = .onDevice,
        temperature: Double = 1.0,
        reasoningLevel: LLMReasoningLevel = .moderate,
        history: [LLMHistoryEntry] = [],
        guardrails: LLMGuardrailsMode = .default
    ) {
        self.model = model
        self.temperature = temperature
        self.reasoningLevel = reasoningLevel
        self.history = history
        self.guardrails = guardrails
    }
}

public protocol LLMClient {
    var availability: LLMAvailability { get }
    func createSession(instructions: String, tools: [LLMTool], configuration: LLMSessionConfiguration) -> LLMSession
}

public protocol LLMSession {
    func streamResponse(to prompt: LLMPrompt, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error>
    func respond(to prompt: String, temperature: Double) async throws -> String
    func currentContextUsage(contextLimit: Int) -> LLMContextUsage?
}

extension LLMSession {
    func streamResponse(to prompt: String, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        streamResponse(to: LLMPrompt(text: prompt), temperature: temperature)
    }
}

extension LLMSession {
    public func currentContextUsage(contextLimit: Int) -> LLMContextUsage? {
        nil
    }
}

public protocol LLMTool {
    var name: String { get }
    var description: String { get }
}

public struct AnyLLMTool: LLMTool {
    public let name: String
    public let description: String
    // Provider-specific payloads, e.g. AFM tool instance under key "afmTool"
    public let providerPayloads: [String: Any]

    public init(name: String, description: String, providerPayloads: [String: Any] = [:]) {
        self.name = name
        self.description = description
        self.providerPayloads = providerPayloads
    }
}

public enum LLMToolCallStatus: String, Codable {
    case pending
    case executing
    case completed
    case failed
}

public struct LLMToolCallEvent: Codable, Identifiable {
    public let id = UUID()
    public let transcriptID: String
    public let toolName: String
    public let toolDescription: String
    public let arguments: String
    public var status: LLMToolCallStatus
    public var result: String?
    public var error: String?

    public init(
        transcriptID: String = UUID().uuidString,
        toolName: String,
        toolDescription: String,
        arguments: String,
        status: LLMToolCallStatus,
        result: String? = nil,
        error: String? = nil
    ) {
        self.transcriptID = transcriptID
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.arguments = arguments
        self.status = status
        self.result = result
        self.error = error
    }
}

public enum LLMStreamEvent {
    case contentUpdated(fullText: String)
    case toolCallsUpdated(calls: [LLMToolCallEvent])
    case reasoningUpdated(content: String?)
}

public enum LLMAvailability: Equatable {
    case available
    case unavailable(LLMUnavailableReason)
}

public enum LLMUnavailableReason: Equatable {
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case other(String)
}

// Simple provider manager to enable switching providers later
public final class LLMProviderManager {
    public static let shared = LLMProviderManager()
    public var client: LLMClient

    private init() {
        // Default to AFM client; can be swapped later by settings
        self.client = AFMClient()
    }
}


