import Foundation

// Provider-agnostic LLM abstractions

public protocol LLMClient {
    var availability: LLMAvailability { get }
    func createSession(instructions: String, tools: [LLMTool]) -> LLMSession
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


