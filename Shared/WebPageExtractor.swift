//
//  WebPageExtractor.swift
//  Shared
//

import Foundation
import WebKit
import UIKit

struct ExtractedPage: Sendable {
    let url: URL
    let title: String
    let excerpt: String?
    let textContent: String
    let siteName: String?
    let extractionMethod: String
}

enum WebPageExtractionError: LocalizedError {
    case invalidURL(String)
    case blockedHost
    case unsupportedContentType(String)
    case httpError(Int)
    case emptyResponse
    case extractionFailed(String)
    case insufficientContent
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let detail):
            return "Invalid URL: \(detail)"
        case .blockedHost:
            return "URL host is not allowed for web fetch."
        case .unsupportedContentType(let type):
            return "Unsupported content type: \(type)"
        case .httpError(let code):
            return "HTTP error \(code) while fetching the page."
        case .emptyResponse:
            return "The page returned no content."
        case .extractionFailed(let detail):
            return "Failed to extract readable content: \(detail)"
        case .insufficientContent:
            return "Could not extract enough readable content from this page. It may not be an article, or the page may require login."
        case .timeout:
            return "Timed out while loading the page."
        }
    }
}

enum WebFetchURLValidator {
    static func validate(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebPageExtractionError.invalidURL("URL is required.")
        }

        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw WebPageExtractionError.invalidURL("Could not parse URL.")
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw WebPageExtractionError.invalidURL("Only HTTPS URLs are supported.")
        }

        if isBlockedHost(host) {
            throw WebPageExtractionError.blockedHost
        }

        return url
    }

    private static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }

        if let bytes = parseIPv4(normalized) {
            return isPrivateIPv4(bytes)
        }

        if normalized.contains(":") {
            let compact = normalized.replacingOccurrences(of: ":", with: "")
            if compact == "1" || compact.hasPrefix("fe80") || compact.hasPrefix("fc") || compact.hasPrefix("fd") {
                return true
            }
        }

        return false
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        if bytes[0] == 10 { return true }
        if bytes[0] == 172 && (16...31).contains(bytes[1]) { return true }
        if bytes[0] == 192 && bytes[1] == 168 { return true }
        if bytes[0] == 127 { return true }
        if bytes[0] == 169 && bytes[1] == 254 { return true }
        if bytes[0] == 0 { return true }
        return false
    }
}

actor WebPageFetchCoordinator {
    static let shared = WebPageFetchCoordinator()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum WebPageExtractor {
    static let minimumContentLength = 200
    static let maxResponseBytes = 5 * 1024 * 1024

    /// Collapses runs of tabs/spaces/newlines so extracted page text uses fewer tokens.
    static func normalizeExtractedText(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                String(line)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

        var collapsed: [String] = []
        var sawBlankLine = false
        for line in lines {
            if line.isEmpty {
                if !sawBlankLine {
                    collapsed.append("")
                    sawBlankLine = true
                }
            } else {
                collapsed.append(line)
                sawBlankLine = false
            }
        }

        return collapsed
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extract(from urlString: String) async throws -> ExtractedPage {
        let url = try WebFetchURLValidator.validate(urlString)
        await WebPageFetchCoordinator.shared.acquire()
        do {
            let result = try await WebViewExtractionSession.shared.extract(url: url)
            await WebPageFetchCoordinator.shared.release()
            return result
        } catch {
            await WebPageFetchCoordinator.shared.release()
            throw error
        }
    }
}

@MainActor
private final class WebViewExtractionSession: NSObject, WKNavigationDelegate {
    static let shared = WebViewExtractionSession()

    private let webView: WKWebView
    private var hostView: UIView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private let readabilityScript: String?
    private let bridgeScript: String?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        readabilityScript = Self.loadBundledScript(named: "readability")
        bridgeScript = Self.loadBundledScript(named: "readability-bridge")
        super.init()
        webView.navigationDelegate = self
        webView.isHidden = true
        attachToWindow()
    }

    func extract(url: URL) async throws -> ExtractedPage {
        webView.stopLoading()

        if !Self.suggestsSPAHeuristic(for: url) {
            do {
                let html = try await Self.fetchHTML(for: url)
                if let page = try await extractFromHTML(html, baseURL: url, method: "fast", timeout: 15) {
                    return page
                }
            } catch let error as WebPageExtractionError {
                switch error {
                case .unsupportedContentType, .blockedHost, .invalidURL:
                    throw error
                default:
                    break
                }
            } catch {
                // Fall back to full navigation for transient network failures.
            }
        }

        guard let page = try await extractViaNavigation(url: url, timeout: 30) else {
            throw WebPageExtractionError.insufficientContent
        }
        return page
    }

    private func extractFromHTML(
        _ html: String,
        baseURL: URL,
        method: String,
        timeout: TimeInterval
    ) async throws -> ExtractedPage? {
        try await loadHTML(html, baseURL: baseURL, timeout: timeout)
        return try await parseReadableContent(url: baseURL, method: method)
    }

    private func extractViaNavigation(url: URL, timeout: TimeInterval) async throws -> ExtractedPage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        webView.load(request)
        try await waitForNavigation(timeout: timeout)
        return try await parseReadableContent(url: webView.url ?? url, method: "navigation")
    }

    private func parseReadableContent(url: URL, method: String) async throws -> ExtractedPage? {
        guard let readabilityScript, let bridgeScript else {
            throw WebPageExtractionError.extractionFailed("Readability scripts are missing from the app bundle.")
        }

        _ = try await webView.evaluateJavaScript(readabilityScript)
        _ = try await webView.evaluateJavaScript(bridgeScript)

        guard let payload = try await webView.evaluateJavaScript("window.__afmExtractReadableContent();") else {
            throw WebPageExtractionError.extractionFailed("Readability returned no result.")
        }

        guard let dictionary = payload as? [String: Any] else {
            throw WebPageExtractionError.extractionFailed("Unexpected Readability result type.")
        }

        let success = dictionary["success"] as? Bool ?? false
        if !success {
            let error = dictionary["error"] as? String ?? "unknown"
            if error == "readability_null" {
                return nil
            }
            throw WebPageExtractionError.extractionFailed(error)
        }

        let textContent = WebPageExtractor.normalizeExtractedText(dictionary["textContent"] as? String ?? "")
        guard textContent.count >= WebPageExtractor.minimumContentLength else {
            return nil
        }

        let title = WebPageExtractor.normalizeExtractedText(dictionary["title"] as? String ?? "")
        let excerpt = WebPageExtractor.normalizeExtractedText(dictionary["excerpt"] as? String ?? "")
        let siteName = WebPageExtractor.normalizeExtractedText(dictionary["siteName"] as? String ?? "")

        return ExtractedPage(
            url: url,
            title: title,
            excerpt: excerpt.isEmpty ? nil : excerpt,
            textContent: textContent,
            siteName: siteName.isEmpty ? nil : siteName,
            extractionMethod: method
        )
    }

    private func loadHTML(_ html: String, baseURL: URL, timeout: TimeInterval) async throws {
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitForNavigation(timeout: timeout)
    }

    private func waitForNavigation(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.navigationContinuation = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebPageExtractionError.timeout
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                webView.stopLoading()
                if let continuation = navigationContinuation {
                    navigationContinuation = nil
                    continuation.resume(throwing: CancellationError())
                }
                group.cancelAll()
                throw error
            }
        }
    }

    private func resumeNavigation(with result: Result<Void, Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            resumeNavigation(with: .success(()))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            resumeNavigation(with: .failure(error))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            resumeNavigation(with: .failure(error))
        }
    }

    private func attachToWindow() {
        guard hostView?.superview == nil else { return }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first,
              let rootView = window.rootViewController?.view else {
            return
        }

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isHidden = true
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.addSubview(webView)
        rootView.addSubview(container)
        hostView = container
    }

    private static func loadBundledScript(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let data = try? Data(contentsOf: url),
              let script = String(data: data, encoding: .utf8) else {
            return nil
        }
        return script
    }

    private static func fetchHTML(for url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebPageExtractionError.extractionFailed("Invalid HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebPageExtractionError.httpError(httpResponse.statusCode)
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("application/pdf") {
                throw WebPageExtractionError.unsupportedContentType("application/pdf")
            }
            if !contentType.contains("text/html") && !contentType.contains("application/xhtml") && !contentType.contains("text/plain") {
                throw WebPageExtractionError.unsupportedContentType(contentType)
            }
        }

        guard !data.isEmpty else {
            throw WebPageExtractionError.emptyResponse
        }

        guard data.count <= WebPageExtractor.maxResponseBytes else {
            throw WebPageExtractionError.extractionFailed("Response exceeds maximum allowed size.")
        }

        if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            if suggestsSPA(html: html) {
                throw WebPageExtractionError.extractionFailed("spa_detected")
            }
            return html
        }

        throw WebPageExtractionError.extractionFailed("Could not decode page as text.")
    }

    private static func suggestsSPAHeuristic(for url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("twitter.com") || host.contains("x.com") || host.contains("instagram.com")
    }

    private static func suggestsSPA(html: String) -> Bool {
        let lower = html.lowercased()
        if lower.contains("__next_data__") { return true }
        if lower.contains("id=\"__next\"") { return true }
        if lower.contains("id=\"root\"") && !lower.contains("<article") { return true }
        if lower.contains("id=\"app\"") && lower.filter({ $0 == "<" }).count < 40 { return true }
        return false
    }
}
