import Foundation

enum RecommendedModelCatalog {
    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/dangeredwolf/afm-chat/main/recommended-models.json"
    )!

    private static let cacheKey = "recommendedMLXModelsJSON"
    private static let requestTimeout: TimeInterval = 8

    static func loadSummaries() async -> [HuggingFaceModelSummary] {
        let ids = await loadIDs()
        guard !ids.isEmpty else { return [] }
        return await hydrate(ids: ids)
    }

    static func loadIDs() async -> [String] {
        if let data = await fetchRemote(), let ids = parse(data) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            return ids
        }
        if let data = UserDefaults.standard.data(forKey: cacheKey), let ids = parse(data) {
            return ids
        }
        if let data = bundledData(), let ids = parse(data) {
            return ids
        }
        return []
    }

    private static func hydrate(ids: [String]) async -> [HuggingFaceModelSummary] {
        await withTaskGroup(of: (Int, HuggingFaceModelSummary).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    if let summary = try? await HuggingFaceModelCatalog.model(id: id) {
                        return (index, summary)
                    }
                    return (index, HuggingFaceModelCatalog.unresolvedSummary(id: id))
                }
            }

            var byIndex: [Int: HuggingFaceModelSummary] = [:]
            for await (index, summary) in group {
                byIndex[index] = summary
            }
            return ids.indices.compactMap { byIndex[$0] }
        }
    }

    private static func fetchRemote() async -> Data? {
        var request = URLRequest(url: remoteURL, timeoutInterval: requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private static func bundledData() -> Data? {
        guard let url = Bundle.main.url(forResource: "recommended-models", withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func parse(_ data: Data) -> [String]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }

        var seen = Set<String>()
        var result: [String] = []
        for raw in payload.models {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.contains("/"), !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private struct Payload: Decodable {
        let models: [String]
    }
}
