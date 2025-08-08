import FoundationModels
import Foundation

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
        do {
            // Prepare the request to exa.ai search API
            guard let apiURL = URL(string: "https://exa.ai/search/api/search-fast") else {
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
            
            // Make the request
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP response
            guard let httpResponse = response as? HTTPURLResponse else {
                return ["Error: Invalid response from search server"]
            }
            
            guard httpResponse.statusCode == 200 else {
                return ["Error: Search server responded with status code \(httpResponse.statusCode)"]
            }
            
            // Parse the JSON response
            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["Error: Failed to parse search response"]
            }
            
            // Extract results
            guard let results = jsonResponse["results"] as? [[String: Any]] else {
                return ["Error: No search results found for '\(arguments.query)'"]
            }
            
            if results.isEmpty {
                return ["No search results found for '\(arguments.query)'. Try different keywords or phrases."]
            }
            
            // Format the output
            var output = "Here are the search results for \"\(arguments.query)\"\n**Please use the Web Fetch tool to explore the full articles of results relevant to the user's query.** You are permitted to view as many articles as needed to answer the query. Summarize the results in a way that is helpful to the user."
            
            for (index, result) in results.enumerated() {
                let title = result["title"] as? String ?? "No title"
                let url = result["url"] as? String ?? ""
                let author = result["author"] as? String ?? ""
                let publishedDate = result["publishedDate"] as? String ?? ""
                let favicon = result["favicon"] as? String ?? ""
                
                output += "**\(index + 1). \(title)**\n"
                output += "🔗 \(url)\n"
                
                if !author.isEmpty {
                    output += "👤 Author: \(author)\n"
                }
                
                output += "\n"
            }
            
            // Add metadata about the search
            if let requestId = jsonResponse["requestId"] as? String {
                let searchType = jsonResponse["resolvedSearchType"] as? String ?? "unknown"
                output += "---\n*Found \(results.count) result(s) using \(searchType) search (Request ID: \(requestId))*"
            } else {
                output += "---\n*Found \(results.count) result(s)*"
            }
            
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
} 
