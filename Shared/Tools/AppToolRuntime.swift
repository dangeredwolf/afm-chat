import Foundation

nonisolated enum AppToolRuntime {
    static func invoke(
        name: String,
        argumentsJSON: String,
        enabledIDs: Set<AppToolID>,
        attachmentRegistry: AttachmentRegistry?
    ) async -> String {
        guard let definition = AppToolCatalog.resolve(name) else {
            return "Error: unknown tool '\(name)'."
        }
        guard enabledIDs.contains(definition.id), definition.isAvailable else {
            return "Error: \(definition.displayName) is not enabled."
        }

        let arguments = parseObject(argumentsJSON)

        switch definition.id {
        case .codeInterpreter:
            guard let code = stringValue("code", definition: definition, arguments: arguments),
                  !code.isEmpty
            else {
                return "Error: missing required argument 'code'."
            }
            return join(JavaScriptTool.run(code: code))

        case .webSearch:
            guard let query = stringValue("query", definition: definition, arguments: arguments),
                  !query.isEmpty
            else {
                return "Error: missing required argument 'query'."
            }
            return join(await SearchTool.run(query: query))

        case .webFetch:
            guard let url = stringValue("url", definition: definition, arguments: arguments),
                  !url.isEmpty
            else {
                return "Error: missing required argument 'url'."
            }
            return join(
                await WebFetchTool.run(
                    url: url,
                    offset: intValue("offset", definition: definition, arguments: arguments),
                    maxCharacters: intValue("maxCharacters", definition: definition, arguments: arguments)
                )
            )

        case .readAttachment:
            guard let attachmentRegistry else {
                return "Error: \(definition.displayName) is not enabled."
            }
            guard let filename = stringValue("filename", definition: definition, arguments: arguments),
                  !filename.isEmpty
            else {
                return "Error: missing required argument 'filename'."
            }
            return join(
                await ReadAttachmentTool.run(
                    filename: filename,
                    offset: intValue("offset", definition: definition, arguments: arguments),
                    maxCharacters: intValue("maxCharacters", definition: definition, arguments: arguments),
                    registry: attachmentRegistry
                )
            )
        }
    }

    private static func join(_ parts: [String]) -> String {
        parts.joined(separator: "\n")
    }

    private static func parseObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else {
            return [:]
        }
        return flattenedObject(value)
    }

    private static func flattenedObject(_ value: Any) -> [String: Any] {
        if let object = value as? [String: Any] {
            if object.count == 1, let only = object.values.first {
                let nested = flattenedObject(only)
                if !nested.isEmpty {
                    return nested
                }
            }
            return object
        }
        if let string = value as? String {
            return parseObject(string)
        }
        return [:]
    }

    private static func stringValue(
        _ name: String,
        definition: AppToolDefinition,
        arguments: [String: Any]
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
        arguments: [String: Any]
    ) -> Int? {
        for key in definition.argumentKeys(for: name) {
            if let value = intValue(arguments[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
