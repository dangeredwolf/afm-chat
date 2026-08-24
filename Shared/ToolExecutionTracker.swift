import Foundation

enum ToolExecutionTracker {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var activeCalls: [String: ActiveCall] = [:]

        struct ActiveCall {
            let executionID: String
            let toolName: String
            let arguments: String
        }

        func begin(toolName: String, arguments: String) {
            lock.lock()
            defer { lock.unlock() }
            let key = Self.key(toolName: toolName, arguments: arguments)
            activeCalls[key] = ActiveCall(
                executionID: UUID().uuidString,
                toolName: toolName,
                arguments: arguments
            )
        }

        func end(toolName: String, arguments: String) {
            lock.lock()
            defer { lock.unlock() }
            activeCalls.removeValue(forKey: Self.key(toolName: toolName, arguments: arguments))
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            activeCalls.removeAll()
        }

        func activeToolCallEvents() -> [LLMToolCallEvent] {
            lock.lock()
            defer { lock.unlock() }
            return activeCalls.values.map { call in
                LLMToolCallEvent(
                    transcriptID: call.executionID,
                    toolName: call.toolName,
                    toolDescription: call.toolName,
                    arguments: call.arguments,
                    status: .executing
                )
            }
        }

        private static func key(toolName: String, arguments: String) -> String {
            toolName + "\u{1E}" + arguments
        }
    }

    private static let storage = Storage()

    static func reset() {
        storage.reset()
    }

    static func begin(toolName: String, arguments: [String: String]) {
        let json = encodeArguments(arguments)
        storage.begin(toolName: toolName, arguments: json)
    }

    static func end(toolName: String, arguments: [String: String]) {
        let json = encodeArguments(arguments)
        storage.end(toolName: toolName, arguments: json)
    }

    static func activeToolCallEvents() -> [LLMToolCallEvent] {
        storage.activeToolCallEvents()
    }

    private static func encodeArguments(_ arguments: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
