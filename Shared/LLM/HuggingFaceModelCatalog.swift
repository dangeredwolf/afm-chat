import Foundation

enum HuggingFaceModelSort: String, CaseIterable, Identifiable, Sendable {
    case trending
    case downloads

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .downloads: return "Most Downloaded"
        }
    }

    var apiSort: String {
        switch self {
        case .trending: return "trendingScore"
        case .downloads: return "downloads"
        }
    }
}

struct HuggingFaceModelSummary: Identifiable, Hashable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
    let pipelineTag: String?
    let tags: [String]
    let createdAt: Date?
    let trendingScore: Double?
    let sizeBytes: Int64?

    var author: String {
        String(id.split(separator: "/").first ?? "")
    }

    var name: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var isVision: Bool {
        mediaCapabilities.vision
    }

    var mediaCapabilities: LLMMediaCapabilities {
        HuggingFaceModelCatalog.mediaCapabilities(id: id, pipelineTag: pipelineTag, tags: tags)
    }
}

nonisolated struct HuggingFaceRepositoryFile: Sendable, Hashable {
    let path: String
    let size: Int64
}

nonisolated struct HuggingFaceDownloadPlan: Sendable {
    let files: [HuggingFaceRepositoryFile]
    let weightsSubpath: String?

    var totalBytes: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }
}

enum HuggingFaceModelCatalog {
    static let supportedPipelineTags: Set<String> = [
        "text-generation",
        "text2text-generation",
        "image-text-to-text"
    ]

    static let excludedPipelineTags: Set<String> = [
        "text-to-image",
        "image-to-image",
        "unconditional-image-generation",
        "text-to-video",
        "image-to-video",
        "text-to-audio",
        "text-to-speech"
    ]

    private static let endpoint = URL(string: "https://huggingface.co/api/models")!

    static func isSupported(pipelineTag: String?, tags: [String]) -> Bool {
        if let pipelineTag {
            if excludedPipelineTags.contains(pipelineTag) { return false }
            if supportedPipelineTags.contains(pipelineTag) { return true }
        }

        if tags.contains(where: { excludedPipelineTags.contains($0) }) {
            return false
        }

        return tags.contains(where: { supportedPipelineTags.contains($0) })
    }

    static func isVision(pipelineTag: String?, tags: [String]) -> Bool {
        pipelineTag == "image-text-to-text" || tags.contains("image-text-to-text")
    }

    /// Processors in mlx-swift-lm that load through `VLMModelFactory`.
    private static let vlmModelTypes: Set<String> = [
        "paligemma",
        "qwen2_vl",
        "qwen2_5_vl",
        "qwen3_vl",
        "qwen3_vl_moe",
        "qwen3_5",
        "qwen3_5_moe",
        "idefics3",
        "gemma3",
        "gemma4",
        "gemma4_unified",
        "smolvlm",
        "fastvlm",
        "llava_qwen2",
        "pixtral",
        "mistral3",
        "lfm2_vl",
        "lfm2-vl",
        "glm_ocr",
        "muse_glimmer"
    ]

    /// Processors that actually read `UserInput.videos`.
    private static let videoModelTypes: Set<String> = [
        "qwen2_vl",
        "qwen2_5_vl",
        "qwen3_vl",
        "qwen3_vl_moe",
        "smolvlm",
        "gemma4"
    ]

    /// Processors that actually read `UserInput.audios`. Empty until mlx-swift-lm prepares audio.
    private static let audioModelTypes: Set<String> = []

    static func mediaCapabilities(
        id: String,
        pipelineTag: String? = nil,
        tags: [String] = []
    ) -> LLMMediaCapabilities {
        // Gemma 4 VLMs crash in Metal on the text-only prepare path, so this
        // app loads them as text models. Don't advertise native media.
        if looksLikeGemma4(id: id) {
            return .none
        }

        let modelType = HuggingFaceCache.modelType(for: id)?.lowercased()
        let visionFromTag = isVision(pipelineTag: pipelineTag, tags: tags)
        let visionFromType = modelType.map { vlmModelTypes.contains($0) } ?? false
        let visionFromID = looksLikeVisionModel(id: id)
        let videoFromType = modelType.map { videoModelTypes.contains($0) } ?? false
        let videoFromID = looksLikeVideoModel(id: id)
        let audio = modelType.map { audioModelTypes.contains($0) } ?? false
        let video = videoFromType || videoFromID
        let vision = visionFromTag || visionFromType || visionFromID || video || audio
        let isSmol = modelType == "smolvlm" || id.lowercased().contains("smolvlm")
        return LLMMediaCapabilities(
            vision: vision,
            video: video,
            audio: audio,
            singleVideoOnly: isSmol,
            singleMediaType: isSmol
        )
    }

    /// Qwen-VL / SmolVLM ids before `config.json` is on disk.
    nonisolated static func looksLikeVideoModel(id: String) -> Bool {
        let lowered = id.lowercased()
        let needles = [
            "qwen2-vl", "qwen2_vl", "qwen2.5-vl", "qwen2.5_vl", "qwen2vl",
            "qwen3-vl", "qwen3_vl", "qwen3vl",
            "smolvlm", "smol-vlm"
        ]
        return needles.contains(where: { lowered.contains($0) })
    }

    nonisolated static func looksLikeVisionModel(id: String) -> Bool {
        if looksLikeVideoModel(id: id) { return true }
        let lowered = id.lowercased()
        let needles = [
            "paligemma", "pixtral", "llava", "idefics", "fastvlm",
            "glm-ocr", "glm_ocr", "muse-glimmer", "muse_glimmer",
            "lfm2-vl", "lfm2_vl", "-vl-", "_vl_", "-vlm", "_vlm"
        ]
        if needles.contains(where: { lowered.contains($0) }) {
            return true
        }
        return lowered.hasSuffix("-vl") || lowered.hasSuffix("_vl")
            || lowered.hasSuffix("-vlm") || lowered.hasSuffix("_vlm")
            || lowered.contains("vlm")
    }

    /// Hugging Face ids and `model_type` values for the Gemma 4 family.
    nonisolated static func looksLikeGemma4(id: String) -> Bool {
        if let modelType = HuggingFaceCache.modelType(for: id)?.lowercased(),
           modelType.hasPrefix("gemma4") {
            return true
        }
        let lowered = id.lowercased()
        return lowered.contains("gemma-4") || lowered.contains("gemma4")
    }

    /// DeepSeek-R1 and distills cannot turn thinking off.
    nonisolated static func looksLikeAlwaysOnReasoning(id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.contains("deepseek-r1") || lowered.contains("r1-distill")
    }

    /// Qwen3 (not 3.5 / VL / Next) declares a hard thinking-budget transition.
    nonisolated static func looksLikeBudgetedReasoning(id: String) -> Bool {
        let lowered = id.lowercased()
        guard lowered.contains("qwen3") else { return false }
        let excluded = ["qwen3.5", "qwen3-5", "qwen35", "qwen3vl", "qwen3-vl", "qwen3next", "qwen3-next"]
        return !excluded.contains(where: { lowered.contains($0) })
    }

    static func listModels(
        sort: HuggingFaceModelSort,
        search: String = "",
        limit: Int = 50
    ) async throws -> [HuggingFaceModelSummary] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "library", value: "mlx"),
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: sort.apiSort),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            query.append(URLQueryItem(name: "search", value: trimmed))
        }
        components.queryItems = query

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode([HubModelPayload].self, from: data)
        return decoded.compactMap { payload in
            guard let summary = summary(from: payload) else { return nil }
            guard isSupported(pipelineTag: summary.pipelineTag, tags: summary.tags) else {
                return nil
            }
            return summary
        }
    }

    static func model(id: String) async throws -> HuggingFaceModelSummary {
        let url = endpoint.appending(path: id)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(HubModelPayload.self, from: data)
        guard let summary = summary(from: payload, fallbackID: id) else {
            throw URLError(.cannotParseResponse)
        }
        return summary
    }

    static func unresolvedSummary(id: String) -> HuggingFaceModelSummary {
        HuggingFaceModelSummary(
            id: id,
            downloads: 0,
            likes: 0,
            pipelineTag: nil,
            tags: [],
            createdAt: nil,
            trendingScore: nil,
            sizeBytes: nil
        )
    }

    private static func summary(from payload: HubModelPayload, fallbackID: String? = nil) -> HuggingFaceModelSummary? {
        let id = payload.id ?? payload.modelId ?? fallbackID
        guard let id, !id.isEmpty else { return nil }
        return HuggingFaceModelSummary(
            id: id,
            downloads: payload.downloads ?? 0,
            likes: payload.likes ?? 0,
            pipelineTag: payload.pipelineTag,
            tags: payload.tags ?? [],
            createdAt: payload.createdAt.flatMap(parseHubDate),
            trendingScore: payload.trendingScore,
            sizeBytes: nil
        )
    }

    nonisolated static func repositorySize(id: String) async -> Int64? {
        guard let plan = try? await downloadPlan(id: id) else { return nil }
        return plan.totalBytes > 0 ? plan.totalBytes : nil
    }

    nonisolated static func listDownloadableFiles(id: String) async throws -> [HuggingFaceRepositoryFile] {
        try await downloadPlan(id: id).files
    }

    nonisolated static func downloadPlan(id: String) async throws -> HuggingFaceDownloadPlan {
        let entries = try await fetchTreeEntries(id: id)
        let files = entries.compactMap { entry -> HuggingFaceRepositoryFile? in
            guard let path = entry.path, isModelDownloadFile(path) else { return nil }
            if entry.type == "directory" || entry.type == "folder" { return nil }
            return HuggingFaceRepositoryFile(path: path, size: max(entry.fileSize, 1))
        }
        return selectVariant(from: files)
    }

    nonisolated static func isModelDownloadFile(_ path: String) -> Bool {
        let name = fileName(path)
        if name.hasSuffix(".gguf") { return false }
        return name.hasSuffix(".safetensors")
            || name.hasSuffix(".json")
            || name.hasSuffix(".jinja")
            || name.hasSuffix(".tiktoken")
            || name == "tokenizer.model"
            || name == "vocab.json"
            || name == "merges.txt"
    }

    nonisolated static func selectVariant(from files: [HuggingFaceRepositoryFile]) -> HuggingFaceDownloadPlan {
        let subpath = preferredWeightsSubpath(in: files.map(\.path))
        if let subpath {
            let prefix = subpath + "/"
            var selected = files.filter { $0.path.hasPrefix(prefix) }
            if needsRootTokenizerOrConfig(selected) {
                let existingNames = Set(selected.map { fileName($0.path) })
                let extras = files.filter { file in
                    !file.path.contains("/")
                        && isTokenizerOrConfig(file.path)
                        && !existingNames.contains(fileName(file.path))
                }
                selected.append(contentsOf: extras)
            }
            if selected.contains(where: { $0.path.hasSuffix(".safetensors") }) {
                return HuggingFaceDownloadPlan(files: selected, weightsSubpath: subpath)
            }
        }

        let root = files.filter { !$0.path.contains("/") }
        if root.contains(where: { $0.path.hasSuffix(".safetensors") }) {
            return HuggingFaceDownloadPlan(files: root, weightsSubpath: nil)
        }

        return HuggingFaceDownloadPlan(files: files, weightsSubpath: nil)
    }

    nonisolated private static func preferredWeightsSubpath(in paths: [String]) -> String? {
        let prefixes = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return String(parts[0])
        })

        func firstMatch(_ pred: (String) -> Bool) -> String? {
            prefixes
                .filter { pred($0.lowercased()) }
                .sorted { $0.count < $1.count }
                .first
        }

        if let fourBit = firstMatch({
            ($0.hasPrefix("mlx") || $0.contains("4bit") || $0.contains("4-bit"))
                && ($0.contains("4bit") || $0.contains("4-bit"))
        }) {
            return fourBit
        }
        if let eightBit = firstMatch({
            ($0.hasPrefix("mlx") || $0.contains("8bit") || $0.contains("8-bit"))
                && ($0.contains("8bit") || $0.contains("8-bit"))
        }) {
            return eightBit
        }
        if prefixes.contains("mlx") {
            return "mlx"
        }
        if let mlx = firstMatch({ $0 == "mlx" || $0.hasPrefix("mlx-") || $0.hasPrefix("mlx_") }) {
            return mlx
        }
        return nil
    }

    nonisolated private static func needsRootTokenizerOrConfig(_ files: [HuggingFaceRepositoryFile]) -> Bool {
        let names = Set(files.map { fileName($0.path) })
        let hasConfig = names.contains("config.json")
        let hasTokenizer = names.contains(where: {
            $0.hasPrefix("tokenizer") || $0 == "tokenizer.model" || $0.hasSuffix(".jinja")
        })
        return !hasConfig || !hasTokenizer
    }

    nonisolated private static func isTokenizerOrConfig(_ path: String) -> Bool {
        let name = fileName(path)
        return name == "config.json"
            || name == "generation_config.json"
            || name == "special_tokens_map.json"
            || name == "tokenizer.model"
            || name.hasPrefix("tokenizer")
            || name.hasSuffix(".jinja")
            || name.hasSuffix(".tiktoken")
            || name == "vocab.json"
            || name == "merges.txt"
    }

    nonisolated private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
    }

    nonisolated private static func fetchTreeEntries(id: String) async throws -> [HubTreeEntry] {
        var url = URL(string: "https://huggingface.co/api/models")!
            .appending(path: id)
            .appending(path: "tree")
            .appending(path: "main")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        url = components?.url ?? url

        var all: [HubTreeEntry] = []
        var seen = Set<URL>()
        while seen.insert(url).inserted {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            all.append(contentsOf: try JSONDecoder().decode([HubTreeEntry].self, from: data))

            guard let next = nextPageURL(from: response, current: url) else { break }
            url = next
        }
        return all
    }

    nonisolated private static func nextPageURL(from response: URLResponse, current: URL) -> URL? {
        guard let http = response as? HTTPURLResponse,
              let link = http.value(forHTTPHeaderField: "Link") else {
            return nil
        }
        for part in link.split(separator: ",") {
            let bits = part.split(separator: ";")
            guard let urlPart = bits.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  urlPart.hasPrefix("<"), urlPart.hasSuffix(">") else {
                continue
            }
            let rel = bits.dropFirst().joined(separator: ";").lowercased()
            guard rel.contains("rel=\"next\"") || rel.contains("rel=next") else { continue }
            let raw = String(urlPart.dropFirst().dropLast())
            return URL(string: raw, relativeTo: current)?.absoluteURL
        }
        return nil
    }

    private static func parseHubDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct HubModelPayload: Decodable {
    let id: String?
    let modelId: String?
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let tags: [String]?
    let createdAt: String?
    let trendingScore: Double?

    enum Checkpoint: String, CodingKey {
        case id, modelId, downloads, likes, tags, createdAt, trendingScore
        case pipelineTag = "pipeline_tag"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Checkpoint.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try container.decodeIfPresent(Int.self, forKey: .likes)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        trendingScore = try container.decodeIfPresent(Double.self, forKey: .trendingScore)
    }
}

nonisolated private struct HubTreeEntry: Decodable, Sendable {
    let path: String?
    let type: String?
    let size: Int64?
    let lfs: HubLFS?

    var fileSize: Int64 {
        if type == "directory" || type == "folder" { return 0 }
        return lfs?.size ?? size ?? 0
    }
}

nonisolated private struct HubLFS: Decodable, Sendable {
    let size: Int64?
}
