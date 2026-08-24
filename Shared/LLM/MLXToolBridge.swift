import Foundation

#if AFM_MLX
import FoundationModels
import MLXLMCommon

@available(iOS 27, *)
nonisolated enum MLXToolBridge {
    static func specs(for tools: [any FoundationModels.Tool]) -> [ToolSpec] {
        var specs: [ToolSpec] = []
        for tool in tools {
            if tool is JavaScriptTool {
                specs.append(codeInterpreterSpec)
            } else if tool is SearchTool {
                specs.append(webSearchSpec)
            } else if tool is WebFetchTool {
                specs.append(webFetchSpec)
            } else if tool is ReadAttachmentTool {
                specs.append(readAttachmentSpec)
            }
        }
        return specs
    }

    static func displayName(for rawName: String) -> String {
        switch normalized(rawName) {
        case "code_interpreter", "codeinterpreter", "javascript":
            return "Code Interpreter"
        case "web_search", "websearch":
            return "Web Search"
        case "web_fetch", "webfetch":
            return "Web Fetch"
        case "read_attachment", "readattachment":
            return "Read Attachment"
        default:
            return rawName
        }
    }

    static func schemaName(for rawName: String) -> String {
        switch normalized(rawName) {
        case "code_interpreter", "codeinterpreter", "javascript":
            return "code_interpreter"
        case "web_search", "websearch":
            return "web_search"
        case "web_fetch", "webfetch":
            return "web_fetch"
        case "read_attachment", "readattachment":
            return "read_attachment"
        default:
            return rawName.replacingOccurrences(of: " ", with: "_")
        }
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
        let name = normalized(call.function.name)
        let arguments = resolvedArguments(call.function.arguments)

        switch name {
        case "code_interpreter", "codeinterpreter", "javascript":
            guard let tool = first(JavaScriptTool.self, in: tools) else {
                return "Error: Code Interpreter is not enabled."
            }
            guard let code = stringValue(arguments["code"]), !code.isEmpty else {
                return "Error: missing required argument 'code'."
            }
            return join(try await tool.call(arguments: JavaScriptTool.Arguments(code: code)))

        case "web_search", "websearch":
            guard let tool = first(SearchTool.self, in: tools) else {
                return "Error: Web Search is not enabled."
            }
            guard let query = stringValue(arguments["query"]) ?? stringValue(arguments["q"]),
                  !query.isEmpty
            else {
                return "Error: missing required argument 'query'."
            }
            return join(try await tool.call(arguments: SearchTool.Arguments(query: query)))

        case "web_fetch", "webfetch":
            guard let tool = first(WebFetchTool.self, in: tools) else {
                return "Error: Web Fetch is not enabled."
            }
            guard let url = stringValue(arguments["url"]), !url.isEmpty else {
                return "Error: missing required argument 'url'."
            }
            let args = WebFetchTool.Arguments(
                url: url,
                offset: intValue(arguments["offset"]),
                maxCharacters: intValue(arguments["maxCharacters"]) ?? intValue(arguments["max_characters"])
            )
            return join(try await tool.call(arguments: args))

        case "read_attachment", "readattachment":
            guard let tool = first(ReadAttachmentTool.self, in: tools) else {
                return "Error: Read Attachment is not enabled."
            }
            guard let filename = stringValue(arguments["filename"])
                    ?? stringValue(arguments["file_name"])
                    ?? stringValue(arguments["name"]),
                  !filename.isEmpty
            else {
                return "Error: missing required argument 'filename'."
            }
            let args = ReadAttachmentTool.Arguments(
                filename: filename,
                offset: intValue(arguments["offset"]),
                maxCharacters: intValue(arguments["maxCharacters"]) ?? intValue(arguments["max_characters"])
            )
            return join(try await tool.call(arguments: args))

        default:
            return "Error: unknown tool '\(call.function.name)'."
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

    private static func normalized(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
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

    private static let codeInterpreterSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "code_interpreter",
            "description": "Assist the user by executing JavaScript code to perform advanced calculations, data analysis, web requests, etc.",
            "parameters": [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description": "The JavaScript code to execute",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["code"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    private static let webSearchSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web for information on any topic to retrieve up-to-date information. Returns relevant pages, URLs, and metadata.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search query to find relevant web content",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["query"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    private static let webFetchSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "web_fetch",
            "description": "Fetch and extract the main readable content from a specific HTTPS URL. Use after web_search when you need the full article, not just snippets. Supports pagination for long pages.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The HTTPS URL to fetch and extract readable content from",
                    ] as [String: any Sendable],
                    "offset": [
                        "type": "integer",
                        "description": "Character offset for pagination when reading long pages. Default 0.",
                    ] as [String: any Sendable],
                    "maxCharacters": [
                        "type": "integer",
                        "description": "Maximum characters to return. Default 8000.",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["url"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    private static let readAttachmentSpec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "read_attachment",
            "description": "Read the text content of a file the user attached to this chat. Use when the user asks about attached documents, code, data, or PDFs.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filename": [
                        "type": "string",
                        "description": "Exact filename label shown in the attachment note, e.g. report.pdf",
                    ] as [String: any Sendable],
                    "offset": [
                        "type": "integer",
                        "description": "Character offset for pagination when reading large files. Default 0.",
                    ] as [String: any Sendable],
                    "maxCharacters": [
                        "type": "integer",
                        "description": "Maximum characters to return. Default 8000.",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["filename"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]
}
#endif
