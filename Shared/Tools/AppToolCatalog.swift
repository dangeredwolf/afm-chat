import Foundation
import FoundationModels

enum AppToolID: String, CaseIterable, Sendable {
    case codeInterpreter
    case webSearch
    case webFetch
    case readAttachment

    /// Flip back to `true` when the backend is working again.
    var isAvailable: Bool {
        switch self {
        case .webSearch:
            false
        default:
            true
        }
    }

    var definition: AppToolDefinition {
        switch self {
        case .codeInterpreter:
            AppToolDefinition(
                id: .codeInterpreter,
                displayName: "Code Interpreter",
                schemaName: "code_interpreter",
                description: "Assist the user by executing JavaScript code to perform advanced calculations, data analysis, web requests, etc.",
                aliases: ["codeinterpreter", "javascript"],
                parameters: [
                    AppToolParameter(
                        name: "code",
                        kind: .string,
                        description: "The JavaScript code to execute",
                        required: true
                    ),
                ],
                userTogglable: true
            )
        case .webSearch:
            AppToolDefinition(
                id: .webSearch,
                displayName: "Web Search",
                schemaName: "web_search",
                description: "Search the web for information on any topic to retrieve up-to-date information. Returns relevant pages, URLs, and metadata.",
                aliases: ["websearch"],
                parameters: [
                    AppToolParameter(
                        name: "query",
                        kind: .string,
                        description: "The search query to find relevant web content",
                        required: true,
                        aliases: ["q"]
                    ),
                ],
                userTogglable: true
            )
        case .webFetch:
            AppToolDefinition(
                id: .webFetch,
                displayName: "Web Fetch",
                schemaName: "web_fetch",
                description: "Fetch and extract the main readable content from a specific HTTPS URL. Use after Web Search when you need the full article, not just snippets. Supports pagination for long pages.",
                aliases: ["webfetch"],
                parameters: [
                    AppToolParameter(
                        name: "url",
                        kind: .string,
                        description: "The HTTPS URL to fetch and extract readable content from",
                        required: true
                    ),
                    AppToolParameter(
                        name: "offset",
                        kind: .integer,
                        description: "Character offset for pagination when reading long pages. Default 0.",
                        required: false
                    ),
                    .paginationMaxCharacters,
                ],
                userTogglable: true
            )
        case .readAttachment:
            AppToolDefinition(
                id: .readAttachment,
                displayName: "Read Attachment",
                schemaName: "read_attachment",
                description: "Read the text content of a file the user attached to this chat. Use when the user asks about attached documents, code, data, or PDFs. Supported formats include plain text, markdown, JSON, CSV, code files, and PDF.",
                aliases: ["readattachment"],
                parameters: [
                    AppToolParameter(
                        name: "filename",
                        kind: .string,
                        description: "Exact filename label shown in the attachment note, e.g. report.pdf",
                        required: true,
                        aliases: ["file_name", "name"]
                    ),
                    AppToolParameter(
                        name: "offset",
                        kind: .integer,
                        description: "Character offset for pagination when reading large files. Default 0.",
                        required: false
                    ),
                    .paginationMaxCharacters,
                ],
                userTogglable: false
            )
        }
    }
}

enum AppToolCatalog {
    static var all: [AppToolDefinition] {
        AppToolID.allCases.map(\.definition)
    }

    static var userTogglable: [AppToolDefinition] {
        all.filter(\.userTogglable)
    }

    static func resolve(_ rawName: String) -> AppToolDefinition? {
        let key = normalized(rawName)
        return all.first { $0.matches(key) }
    }

    static func normalized(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}

struct AppToolParameter: Sendable {
    enum Kind: Sendable {
        case string
        case integer
    }

    let name: String
    let kind: Kind
    let description: String
    let required: Bool
    let aliases: [String]

    init(
        name: String,
        kind: Kind,
        description: String,
        required: Bool,
        aliases: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.aliases = aliases
    }

    var keys: [String] {
        [name] + aliases
    }

    var jsonType: String {
        switch kind {
        case .string: "string"
        case .integer: "integer"
        }
    }

    fileprivate var dynamicValueSchema: DynamicGenerationSchema {
        switch kind {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        }
    }

    fileprivate static let paginationMaxCharacters = AppToolParameter(
        name: "maxCharacters",
        kind: .integer,
        description: "Maximum characters to return. Default 8000.",
        required: false,
        aliases: ["max_characters"]
    )
}

struct AppToolDefinition: Sendable {
    let id: AppToolID
    let displayName: String
    let schemaName: String
    let description: String
    let aliases: [String]
    let parameters: [AppToolParameter]
    let userTogglable: Bool

    var isAvailable: Bool { id.isAvailable }

    func matches(_ normalizedName: String) -> Bool {
        nameKeys.contains(normalizedName)
    }

    func parameter(named name: String) -> AppToolParameter? {
        parameters.first { $0.name == name }
    }

    func argumentKeys(for parameterName: String) -> [String] {
        parameter(named: parameterName)?.keys ?? [parameterName]
    }

    var primaryRequiredStringParameter: AppToolParameter? {
        parameters.first { $0.required && $0.kind == .string }
    }

    func mlxSpec() -> [String: any Sendable] {
        var properties: [String: any Sendable] = [:]
        var required: [String] = []

        for parameter in parameters {
            properties[parameter.name] = [
                "type": parameter.jsonType,
                "description": parameter.description,
            ] as [String: any Sendable]
            if parameter.required {
                required.append(parameter.name)
            }
        }

        return [
            "type": "function",
            "function": [
                "name": schemaName,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    func generationSchema() -> GenerationSchema {
        let properties = parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name,
                description: parameter.description,
                schema: parameter.dynamicValueSchema,
                isOptional: !parameter.required
            )
        }
        let root = DynamicGenerationSchema(
            name: schemaName,
            description: description,
            properties: properties
        )
        do {
            return try GenerationSchema(root: root, dependencies: [])
        } catch {
            preconditionFailure("Invalid tool schema for \(schemaName): \(error)")
        }
    }

    func makeFoundationTool(attachmentRegistry: AttachmentRegistry? = nil) -> any Tool {
        switch id {
        case .codeInterpreter:
            return JavaScriptTool()
        case .webSearch:
            return SearchTool()
        case .webFetch:
            return WebFetchTool()
        case .readAttachment:
            guard let attachmentRegistry else {
                preconditionFailure("Read Attachment requires an attachment registry")
            }
            return ReadAttachmentTool(registry: attachmentRegistry)
        }
    }

    func asLLMTool(attachmentRegistry: AttachmentRegistry? = nil) -> AnyLLMTool {
        AnyLLMTool(
            name: displayName,
            description: description,
            providerPayloads: ["afmTool": makeFoundationTool(attachmentRegistry: attachmentRegistry)]
        )
    }

    private var nameKeys: Set<String> {
        Set(([displayName, schemaName] + aliases).map(AppToolCatalog.normalized))
    }
}
