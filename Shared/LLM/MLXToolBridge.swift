import Foundation

#if AFM_MLX
import MLXLMCommon

nonisolated enum MLXToolBridge {
    static func specs(for ids: [AppToolID]) -> [ToolSpec] {
        ids.compactMap { id in
            let definition = id.definition
            guard definition.isAvailable else { return nil }
            return definition.mlxSpec()
        }
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

    static func invoke(
        _ call: ToolCall,
        enabledIDs: Set<AppToolID>,
        attachmentRegistry: AttachmentRegistry?
    ) async -> String {
        await AppToolRuntime.invoke(
            name: call.function.name,
            argumentsJSON: encodeArguments(resolvedArguments(call.function.arguments)),
            enabledIDs: enabledIDs,
            attachmentRegistry: attachmentRegistry
        )
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
}
#endif
