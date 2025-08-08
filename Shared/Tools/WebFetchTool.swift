import FoundationModels
import Foundation

/// A tool that fetches web content from URLs using the exa.ai API
struct WebFetchTool: Tool {
    let name = "Web Fetch"
    let description = "Fetch and extract content from web pages by providing a URL. Returns the page title, text content, and metadata."
    
    @Generable
    struct Arguments {
        @Guide(description: "The URL of the web page to fetch content from")
        var url: String
    }
    
    func call(arguments: Arguments) async throws -> [String] {
        do {
            // Validate URL format
            guard let url = URL(string: arguments.url) else {
                return ["Error: Invalid URL format. Please provide a valid URL (e.g., https://example.com)"]
            }
            
            // Prepare the request to exa.ai API
            guard let apiURL = URL(string: "https://exa.ai/search/api/contents") else {
                return ["Error: Failed to create API URL"]
            }
            
            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            
            // Create request body
            let requestBody = ["url": arguments.url]
            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            request.httpBody = jsonData
            
            // Make the request
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP response
            guard let httpResponse = response as? HTTPURLResponse else {
                return ["Error: Invalid response from server"]
            }
            
            guard httpResponse.statusCode == 200 else {
                return ["Error: Server responded with status code \(httpResponse.statusCode)"]
            }
            
            // Parse the JSON response
            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["Error: Failed to parse server response"]
            }
            
            // Extract results
            guard let results = jsonResponse["results"] as? [[String: Any]],
                  let firstResult = results.first else {
                return ["Error: No content found for the provided URL"]
            }
            
            // Extract data from the result
            let title = firstResult["title"] as? String ?? "No title"
            let text = firstResult["text"] as? String ?? "No content"
            let author = firstResult["author"] as? String ?? ""
            let publishedDate = firstResult["publishedDate"] as? String ?? ""
            let imageUrl = firstResult["image"] as? String ?? ""
            
            // Format the output
            var output = """
            **\(title)**
            
            URL: \(arguments.url)
            """
            
            if !author.isEmpty {
                output += "\nAuthor: \(author)"
            }
            
            if !publishedDate.isEmpty {
                let cleanDate = publishedDate.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ".000Z", with: " UTC")
                output += "\nPublished: \(cleanDate)"
            }
            
            if !imageUrl.isEmpty {
                output += "\nImage: \(imageUrl)"
            }
            
            output += "\n\n**Content:**\n\(text)"
            
            // Add some metadata about the fetch
            if let requestId = jsonResponse["requestId"] as? String {
                output += "\n\n---\n*Content fetched successfully (Request ID: \(requestId))*"
            } else {
                output += "\n\n---\n*Content fetched successfully*"
            }
            
            return [output]
            
        } catch {
            // Handle different types of errors
            if error is URLError {
                let urlError = error as! URLError
                switch urlError.code {
                case .notConnectedToInternet:
                    return ["Error: No internet connection available"]
                case .timedOut:
                    return ["Error: Request timed out. The server may be slow or unreachable"]
                case .cannotFindHost:
                    return ["Error: Cannot find the server. Please check the URL"]
                case .cannotConnectToHost:
                    return ["Error: Cannot connect to the server"]
                default:
                    return ["Error: Network error - \(urlError.localizedDescription)"]
                }
            } else {
                return ["Error: Failed to fetch web content - \(error.localizedDescription)"]
            }
        }
    }
} 
