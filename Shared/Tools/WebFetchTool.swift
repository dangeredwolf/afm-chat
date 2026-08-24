//
//  WebFetchTool.swift
//  Shared
//

import Foundation
import FoundationModels

/// Fetches and extracts readable content from a web page using on-device Readability.js.
struct WebFetchTool: Tool {
    private static let definition = AppToolID.webFetch.definition

    var name: String { Self.definition.displayName }
    var description: String { Self.definition.description }
    var parameters: GenerationSchema { Self.definition.generationSchema() }

    @Generable
    struct Arguments {
        var url: String
        var offset: Int?
        var maxCharacters: Int?
    }

    func call(arguments: Arguments) async throws -> [String] {
        var trackedArguments: [String: String] = ["url": arguments.url]
        if let offset = arguments.offset {
            trackedArguments["offset"] = String(offset)
        }
        if let maxCharacters = arguments.maxCharacters {
            trackedArguments["maxCharacters"] = String(maxCharacters)
        }
        ToolExecutionTracker.begin(toolName: name, arguments: trackedArguments)
        defer { ToolExecutionTracker.end(toolName: name, arguments: trackedArguments) }

        let offset = arguments.offset ?? 0
        let maxCharacters = arguments.maxCharacters ?? ChatAttachmentReader.defaultMaxCharacters

        do {
            let page = try await WebPageExtractor.extract(from: arguments.url)
            let paginated = ChatAttachmentReader.paginateText(
                page.textContent,
                offset: offset,
                maxCharacters: maxCharacters
            )
            return [formatOutput(page: page, result: paginated)]
        } catch let error as WebPageExtractionError {
            return [error.localizedDescription]
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    return ["Error: No internet connection available for web fetch."]
                case .timedOut:
                    return ["Error: Web fetch timed out. Please try again."]
                case .cannotFindHost, .cannotConnectToHost:
                    return ["Error: Cannot reach the requested host."]
                default:
                    return ["Error: Network error during web fetch - \(urlError.localizedDescription)"]
                }
            }
            return ["Error: Failed to fetch web page - \(error.localizedDescription)"]
        }
    }

    private func formatOutput(page: ExtractedPage, result: ChatAttachmentReader.ReadResult) -> String {
        var output = "URL: \(page.url.absoluteString)\n"
        if !page.title.isEmpty {
            output += "Title: \(page.title)\n"
        }
        if let siteName = page.siteName {
            output += "Site: \(siteName)\n"
        }
        if let excerpt = page.excerpt {
            output += "Excerpt: \(excerpt)\n"
        }
        output += "Extraction: \(page.extractionMethod)\n"
        output += "Total characters: \(result.totalCharacters)\n"

        if result.isTruncated {
            let end = result.offset + result.returnedCharacters
            output += "[Showing characters \(result.offset)-\(end) of \(result.totalCharacters). Call again with a higher offset to read more.]\n"
        } else if result.offset > 0 {
            output += "[Showing characters \(result.offset)-\(result.offset + result.returnedCharacters) of \(result.totalCharacters).]\n"
        }

        output += "\n\(result.content)"
        return output
    }
}
