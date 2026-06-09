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

public struct LLMSessionConfiguration: Sendable {
    public var model: LLMModelChoice
    public var temperature: Double
    public var reasoningLevel: LLMReasoningLevel

    public init(
        model: LLMModelChoice = .onDevice,
        temperature: Double = 1.0,
        reasoningLevel: LLMReasoningLevel = .moderate
    ) {
        self.model = model
        self.temperature = temperature
        self.reasoningLevel = reasoningLevel
    }
}

public protocol LLMClient {
    var availability: LLMAvailability { get }
    func createSession(instructions: String, tools: [LLMTool], configuration: LLMSessionConfiguration) -> LLMSession
}

public protocol LLMSession {
    func streamResponse(to prompt: String, temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error>
    func respond(to prompt: String, temperature: Double) async throws -> String
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
    public let toolName: String
    public let toolDescription: String
    public let arguments: String
    public var status: LLMToolCallStatus
    public var result: String?
    public var error: String?

    public init(toolName: String,
                toolDescription: String,
                arguments: String,
                status: LLMToolCallStatus,
                result: String? = nil,
                error: String? = nil) {
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
    case reasoningUpdated(content: String?, tokenCount: Int)
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


