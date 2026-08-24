import Foundation

#if AFM_MLX
import FoundationModels
import MLXLMCommon

@available(iOS 27, *)
nonisolated enum MLXToolBridge {
    static func specs(for tools: [any FoundationModels.Tool]) -> [ToolSpec] {
        var specs: [ToolSpec] = []
        for tool in tools {
            if let definition = AppToolCatalog.resolve(tool.name) {
                specs.append(definition.mlxSpec())
            } else {
                assertionFailure("No catalog definition for tool '\(tool.name)'")
            }
        }
        return specs
    }

    static func displayName(for rawName: String) -> String {
        AppToolCatalog.resolve(rawName)?.displayName ?? rawName
    }

    static func schemaName(for rawName: String) -> String {
        AppToolCatalog.resolve(rawName)?.schemaName
            ?? rawName.replacingOccurrences(of: " ", with: "_")
    }

    static func encodeArguments(_ arguments: [String: JSONValue]) -> String {
        let object = arguments.mapValues(\.anyValue)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    static func decodeArguments(_ json: String) -> [String: JSONValue] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return [:]
        }
        return jsonObject(from: value)
    }

    static func invoke(_ call: ToolCall, tools: [any FoundationModels.Tool]) async throws -> String {
        guard let definition = AppToolCatalog.resolve(call.function.name) else {
            return "Error: unknown tool '\(call.function.name)'."
        }
        let arguments = resolvedArguments(call.function.arguments)

        switch definition.id {
        case .codeInterpreter:
            guard let tool = first(JavaScriptTool.self, in: tools) else {
                return "Error: \(definition.displayName) is not enabled."
            }
            guard let code = stringValue("code", definition: definition, arguments: arguments),
                  !code.isEmpty
            else {
                return "Error: missing required argument 'code'."
            }
            return join(try await tool.call(arguments: JavaScriptTool.Arguments(code: code)))

        case .webSearch:
            guard let tool = first(SearchTool.self, in: tools) else {
                return "Error: \(definition.displayName) is not enabled."
            }
            guard let query = stringValue("query", definition: definition, arguments: arguments),
                  !query.isEmpty
            else {
                return "Error: missing required argument 'query'."
            }
            return join(try await tool.call(arguments: SearchTool.Arguments(query: query)))

        case .webFetch:
            guard let tool = first(WebFetchTool.self, in: tools) else {
                return "Error: \(definition.displayName) is not enabled."
            }
            guard let url = stringValue("url", definition: definition, arguments: arguments),
                  !url.isEmpty
            else {
                return "Error: missing required argument 'url'."
            }
            let args = WebFetchTool.Arguments(
                url: url,
                offset: intValue("offset", definition: definition, arguments: arguments),
                maxCharacters: intValue("maxCharacters", definition: definition, arguments: arguments)
            )
            return join(try await tool.call(arguments: args))

        case .readAttachment:
            guard let tool = first(ReadAttachmentTool.self, in: tools) else {
                return "Error: \(definition.displayName) is not enabled."
            }
            guard let filename = stringValue("filename", definition: definition, arguments: arguments),
                  !filename.isEmpty
            else {
                return "Error: missing required argument 'filename'."
            }
            let args = ReadAttachmentTool.Arguments(
                filename: filename,
                offset: intValue("offset", definition: definition, arguments: arguments),
                maxCharacters: intValue("maxCharacters", definition: definition, arguments: arguments)
            )
            return join(try await tool.call(arguments: args))
        }
    }

    private static func first<T>(_ type: T.Type, in tools: [any FoundationModels.Tool]) -> T? {
        for tool in tools {
            if let match = tool as? T {
                return match
            }
        }
        return nil
    }

    private static func join(_ parts: [String]) -> String {
        parts.joined(separator: "\n")
    }

    private static func resolvedArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        if arguments.count == 1, let only = arguments.values.first {
            let nested = jsonObject(from: only)
            if !nested.isEmpty {
                return nested
            }
        }
        return arguments
    }

    private static func jsonObject(from value: JSONValue) -> [String: JSONValue] {
        switch value {
        case .object(let object):
            return object
        case .string(let json):
            return decodeArguments(json)
        default:
            return [:]
        }
    }

    private static func stringValue(
        _ name: String,
        definition: AppToolDefinition,
        arguments: [String: JSONValue]
    ) -> String? {
        for key in definition.argumentKeys(for: name) {
            if let value = stringValue(arguments[key]) {
                return value
            }
        }
        return nil
    }

    private static func intValue(
        _ name: String,
        definition: AppToolDefinition,
        arguments: [String: JSONValue]
    ) -> Int? {
        for key in definition.argumentKeys(for: name) {
            if let value = intValue(arguments[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        default:
            return nil
        }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let int):
            return int
        case .double(let double):
            return Int(double)
        case .string(let string):
            return Int(string)
        default:
            return nil
        }
    }
}
#endif
