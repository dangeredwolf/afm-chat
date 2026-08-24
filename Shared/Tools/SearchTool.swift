import FoundationModels
import Foundation
import os

private enum ExaAuthError: LocalizedError {
    case invalidResponse
    case tokenIssueFailed(statusCode: Int)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Exa authentication server"
        case .tokenIssueFailed(let statusCode):
            return "Failed to obtain Exa token (status \(statusCode))"
        case .missingToken:
            return "Exa token response did not include a token"
        }
    }
}

/// Manages short-lived bearer tokens for the exa.ai search API.
private actor ExaAuth {
    static let shared = ExaAuth()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "afm-chat", category: "ExaAuth")
    private static let referer = "https://exa.ai/search"
    private static let tokenURL = URL(string: "https://exa.ai/search/api/token/issue")!

    private var cachedToken: String?
    private var expiresAt: Date?

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        print("[ExaAuth] \(message)")
    }

    private func logResponseBody(_ data: Data, label: String) {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        let preview = body.count > 500 ? String(body.prefix(500)) + "…" : body
        log("\(label) body (\(data.count) bytes): \(preview)")
    }

    private func logTokenPreview(_ token: String) {
        let preview = token.count > 24 ? String(token.prefix(24)) + "…" : token
        log("token preview: \(preview) (\(token.count) chars)")
    }

    func authorize(_ request: inout URLRequest) async throws {
        log("authorizing request to \(request.url?.absoluteString ?? "unknown")")
        let token = try await token()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        logTokenPreview(token)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let urlString = request.url?.absoluteString ?? "unknown"
        log("API request: \(request.httpMethod ?? "GET") \(urlString)")

        var authorizedRequest = request
        try await authorize(&authorizedRequest)

        var (data, response) = try await URLSession.shared.data(for: authorizedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            log("API response invalid (not HTTPURLResponse) for \(urlString)")
            throw ExaAuthError.invalidResponse
        }

        log("API response: \(httpResponse.statusCode) for \(urlString)")

        if httpResponse.statusCode == 401 {
            log("API returned 401 — invalidating cached token and retrying once")
            logResponseBody(data, label: "401")
            invalidate()
            try await authorize(&authorizedRequest)
            (data, response) = try await URLSession.shared.data(for: authorizedRequest)
            guard let retryResponse = response as? HTTPURLResponse else {
                log("retry response invalid (not HTTPURLResponse) for \(urlString)")
                throw ExaAuthError.invalidResponse
            }
            log("API retry response: \(retryResponse.statusCode) for \(urlString)")
            if retryResponse.statusCode != 200 {
                logResponseBody(data, label: "retry \(retryResponse.statusCode)")
            }
            return (data, retryResponse)
        }

        if httpResponse.statusCode != 200 {
            logResponseBody(data, label: "error \(httpResponse.statusCode)")
        }

        return (data, httpResponse)
    }

    private func token() async throws -> String {
        if let cachedToken, let expiresAt {
            let remaining = expiresAt.timeIntervalSinceNow
            if remaining > 30 {
                log("using cached token (expires in \(Int(remaining))s)")
                logTokenPreview(cachedToken)
                return cachedToken
            }
            log("cached token expiring soon (\(Int(remaining))s left) — refreshing")
        } else {
            log("no cached token — issuing new one")
        }
        return try await issueToken()
    }

    private func issueToken() async throws -> String {
        log("POST \(Self.tokenURL.absoluteString)")
        log("request headers: Referer=\(Self.referer)")

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log("token issue network error: \(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            log("token issue response invalid (not HTTPURLResponse)")
            throw ExaAuthError.invalidResponse
        }

        log("token issue status: \(httpResponse.statusCode)")
        log("token issue response headers: \(httpResponse.allHeaderFields)")

        guard httpResponse.statusCode == 200 else {
            logResponseBody(data, label: "token issue \(httpResponse.statusCode)")
            throw ExaAuthError.tokenIssueFailed(statusCode: httpResponse.statusCode)
        }

        logResponseBody(data, label: "token issue 200")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("token issue JSON parse failed — not a dictionary")
            throw ExaAuthError.missingToken
        }

        log("token issue JSON keys: \(json.keys.sorted())")

        guard let token = json["token"] as? String else {
            log("token issue JSON missing 'token' string field")
            throw ExaAuthError.missingToken
        }

        cachedToken = token
        logTokenPreview(token)

        if let expiresAtMs = json["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            log("token expiresAt: \(expiresAtMs) → \(expiresAt!.description)")
        } else if let expiresIn = json["expiresIn"] as? Double {
            expiresAt = Date().addingTimeInterval(expiresIn)
            log("token expiresIn: \(expiresIn)s → \(expiresAt!.description)")
        } else {
            log("token response missing expiresAt/expiresIn")
        }

        return token
    }

    private func invalidate() {
        log("invalidating cached token")
        cachedToken = nil
        expiresAt = nil
    }
}

/// A tool that searches the web using the exa.ai search API
struct SearchTool: Tool {
    let name = "Web Search"
    let description = "Search the web for information on any topic to retrieve up-to-date information. Returns relevant pages, URLs, and metadata."
    
    @Generable
    struct Arguments {
        @Guide(description: "The search query to find relevant web content")
        var query: String
    }
    
    func call(arguments: Arguments) async throws -> [String] {
        ToolExecutionTracker.begin(toolName: name, arguments: ["query": arguments.query])
        defer { ToolExecutionTracker.end(toolName: name, arguments: ["query": arguments.query]) }

        do {
            // Prepare the request to exa.ai search API
            guard let apiURL = URL(string: "https://exa.ai/search/api/search") else {
                return ["Error: Failed to create search API URL"]
            }
            
            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("en-CA,en-US;q=0.7,en;q=0.3", forHTTPHeaderField: "Accept-Language")
            request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            
            // Create request body
            let requestBody: [String: Any] = [
                "numResults": 10,
                "text": true,
                "query": arguments.query,
                "fastMode": true
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            request.httpBody = jsonData
            
            let (data, httpResponse) = try await ExaAuth.shared.data(for: request)
            
            guard httpResponse.statusCode == 200 else {
                return ["Error: Search server responded with status code \(httpResponse.statusCode)"]
            }
            
            guard let payload = Self.parseSearchPayload(from: data) else {
                return ["Error: Failed to parse search response"]
            }
            
            let results = payload.results
            
            if results.isEmpty {
                return ["No search results found for '\(arguments.query)'. Try different keywords or phrases."]
            }
            
            // var output = "Here are the search results for \"\(arguments.query)\". Summarize the results in a way that is helpful to the user."
            var output = ""
            for (index, result) in results.enumerated() {
                let title = result["title"] as? String ?? "No title"
                let url = result["url"] as? String ?? ""
                let author = result["author"] as? String ?? ""
                let text = result["text"] as? String ?? ""
                
                output += "**\(index + 1). \(title)**\n"
                output += "🔗 \(url)\n"
                
                if !author.isEmpty {
                    output += "👤 Author: \(author)\n"
                }
                
                if !text.isEmpty {
                    output += "\n\(text)\n"
                }
                
                output += "\n"
            }
            
            if let requestId = payload.requestId {
                let searchType = payload.resolvedSearchType ?? "unknown"
                output += "---\n*Found \(results.count) result(s) using \(searchType) search (Request ID: \(requestId))*"
            } else {
                output += "---\n*Found \(results.count) result(s)*"
            }
            output += "\n*Use Web Fetch to read the full content of a specific URL.*"
            
            return [output]
            
        } catch {
            // Handle different types of errors
            if error is URLError {
                let urlError = error as! URLError
                switch urlError.code {
                case .notConnectedToInternet:
                    return ["Error: No internet connection available for search"]
                case .timedOut:
                    return ["Error: Search request timed out. Please try again"]
                case .cannotFindHost:
                    return ["Error: Cannot reach search server"]
                case .cannotConnectToHost:
                    return ["Error: Cannot connect to search server"]
                default:
                    return ["Error: Network error during search - \(urlError.localizedDescription)"]
                }
            } else {
                return ["Error: Failed to perform web search - \(error.localizedDescription)"]
            }
        }
    }

    private struct SearchPayload {
        let results: [[String: Any]]
        let requestId: String?
        let resolvedSearchType: String?
    }

    /// Parses exa search responses (single JSON object or NDJSON stream).
    private static func parseSearchPayload(from data: Data) -> SearchPayload? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = payload(from: json) else {
                continue
            }
            return payload
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload(from: json)
    }

    private static func payload(from json: [String: Any]) -> SearchPayload? {
        if let results = json["results"] as? [[String: Any]] {
            return SearchPayload(
                results: results,
                requestId: json["requestId"] as? String,
                resolvedSearchType: json["resolvedSearchType"] as? String
            )
        }

        guard let data = json["data"] as? [String: Any],
              let results = data["results"] as? [[String: Any]] else {
            return nil
        }

        let requestParams = data["requestParams"] as? [String: Any]
        return SearchPayload(
            results: results,
            requestId: data["requestId"] as? String,
            resolvedSearchType: requestParams?["resolvedSearchType"] as? String
        )
    }
}
