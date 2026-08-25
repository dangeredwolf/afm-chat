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
    let lastModified: Date?
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

    func withSizeBytes(_ sizeBytes: Int64?) -> HuggingFaceModelSummary {
        HuggingFaceModelSummary(
            id: id,
            downloads: downloads,
            likes: likes,
            pipelineTag: pipelineTag,
            tags: tags,
            createdAt: createdAt,
            lastModified: lastModified,
            trendingScore: trendingScore,
            sizeBytes: sizeBytes
        )
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

struct HuggingFaceModelDetails: Hashable, Sendable {
    let summary: HuggingFaceModelSummary
    let libraryName: String?
    let license: String?
    let modelType: String?
    let architectures: [String]
    let parameterCount: Int64?
    let tensorTypes: [String]
    let files: [HuggingFaceRepositoryFile]
    let weightsSubpath: String?

    var sizeBytes: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    var parameterCountText: String? {
        guard let parameterCount, parameterCount > 0 else { return nil }
        return HuggingFaceModelCatalog.formatParameterCount(parameterCount)
    }
}

enum HuggingFaceModelDateFormat {
    static func updatedLabel(_ date: Date) -> String {
        "Updated \(relativeOrAbsolute(date))"
    }

    static func relativeOrAbsolute(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "today"
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday"
        }
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        if let days = calendar.dateComponents([.day], from: start, to: today).day, (2..<7).contains(days) {
            return "\(days) days ago"
        }
        return absolute(date)
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
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
        var video = videoFromType || videoFromID
        var vision = visionFromTag || visionFromType || visionFromID || video || audio
        // Qwen 3.5 text checkpoints (Ornith 1.5, …) reuse `qwen3_5` / `qwen3_5_moe`
        // without `vision_config`. The VLM decoder requires that field.
        if HuggingFaceCache.hasVisionConfig(for: id) == false {
            vision = false
            video = false
        }
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

    /// GPT-OSS Harmony models. They think on the `analysis` channel, not `<think>` tags.
    nonisolated static func looksLikeGptOss(id: String) -> Bool {
        if let modelType = HuggingFaceCache.modelType(for: id)?.lowercased(),
           modelType == "gpt_oss" || modelType == "gpt-oss" {
            return true
        }
        let lowered = id.lowercased()
        return lowered.contains("gpt-oss") || lowered.contains("gpt_oss") || lowered.contains("gptoss")
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
        let payload = try await fetchModelPayload(id: id)
        guard let summary = summary(from: payload, fallbackID: id) else {
            throw URLError(.cannotParseResponse)
        }
        return summary
    }

    static func details(id: String) async throws -> HuggingFaceModelDetails {
        async let payloadTask = fetchModelPayload(id: id)
        async let planTask = optionalDownloadPlan(id: id)
        let payload = try await payloadTask
        let plan = await planTask
        guard let details = details(from: payload, plan: plan, fallbackID: id) else {
            throw URLError(.cannotParseResponse)
        }
        return details
    }

    /// Raw model-card markdown, or `nil` when the repo has no README.
    static func readme(id: String) async throws -> String? {
        guard let url = hubURL(id: id, pathComponents: ["raw", "main", "README.md"]) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("text/markdown, text/plain;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            if !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let markdown = rewriteRelativeMarkdownURLs(stripYAMLFrontMatter(raw), repoID: id)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : markdown
    }

    static func unresolvedSummary(id: String) -> HuggingFaceModelSummary {
        HuggingFaceModelSummary(
            id: id,
            downloads: 0,
            likes: 0,
            pipelineTag: nil,
            tags: [],
            createdAt: nil,
            lastModified: nil,
            trendingScore: nil,
            sizeBytes: nil
        )
    }

    static func formatParameterCount(_ count: Int64) -> String {
        let value = Double(count)
        let billion = 1_000_000_000.0
        let million = 1_000_000.0
        if value >= billion {
            let billions = value / billion
            if billions >= 10 {
                return "\(Int(billions.rounded()))B"
            }
            let tenths = (billions * 10).rounded() / 10
            if tenths == tenths.rounded() {
                return "\(Int(tenths))B"
            }
            return String(format: "%.1fB", tenths)
        }
        if value >= million {
            return "\(Int((value / million).rounded()))M"
        }
        return count.formatted()
    }

    private static func fetchModelPayload(id: String) async throws -> HubModelPayload {
        let url = endpoint.appending(path: id)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("afm-chat", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(HubModelPayload.self, from: data)
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
            lastModified: payload.lastModified.flatMap(parseHubDate),
            trendingScore: payload.trendingScore,
            sizeBytes: nil
        )
    }

    private static func details(
        from payload: HubModelPayload,
        plan: HuggingFaceDownloadPlan?,
        fallbackID: String?
    ) -> HuggingFaceModelDetails? {
        guard let summary = summary(from: payload, fallbackID: fallbackID) else { return nil }
        let files = (plan?.files ?? []).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let sizeBytes = plan.flatMap { $0.totalBytes > 0 ? $0.totalBytes : nil }
        let parameters = payload.safetensors?.parameters ?? [:]
        let parameterTotal = payload.safetensors?.total ?? parameters.values.reduce(0, +)
        return HuggingFaceModelDetails(
            summary: summary.withSizeBytes(sizeBytes),
            libraryName: payload.libraryName,
            license: payload.license,
            modelType: payload.config?.modelType,
            architectures: payload.config?.architectures ?? [],
            parameterCount: parameterTotal > 0 ? parameterTotal : nil,
            tensorTypes: parameters.keys.sorted(),
            files: files,
            weightsSubpath: plan?.weightsSubpath
        )
    }

    nonisolated private static func optionalDownloadPlan(id: String) async -> HuggingFaceDownloadPlan? {
        try? await downloadPlan(id: id)
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

    nonisolated private static func hubURL(id: String, pathComponents: [String]) -> URL? {
        guard var url = URL(string: "https://huggingface.co") else { return nil }
        for part in id.split(separator: "/") {
            guard !part.isEmpty else { continue }
            url.append(path: String(part))
        }
        for part in pathComponents {
            url.append(path: part)
        }
        return url
    }

    nonisolated private static func stripYAMLFrontMatter(_ markdown: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard text.hasPrefix("---") else { return markdown }
        let remainder = text.dropFirst(3)
        guard remainder.first == "\n" || remainder.hasPrefix("\r\n") || remainder.hasPrefix(" ") || remainder.hasPrefix("\t") || remainder.isEmpty else {
            return markdown
        }
        let ns = text as NSString
        let pattern = #"\A(?:\uFEFF)?---[ \t]*\r?\n(?:(?!---).*\r?\n)*---[ \t]*\r?\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.range.length > 0 else {
            return markdown
        }
        return ns.substring(from: match.range.length)
    }

    nonisolated private static func rewriteRelativeMarkdownURLs(_ markdown: String, repoID: String) -> String {
        guard var base = hubURL(id: repoID, pathComponents: ["resolve", "main"]) else {
            return markdown
        }
        if !base.absoluteString.hasSuffix("/") {
            guard let slashed = URL(string: base.absoluteString + "/") else { return markdown }
            base = slashed
        }

        guard let regex = try? NSRegularExpression(pattern: #"\]\(\s*([^)\s]+)([^)]*)\)"#) else {
            return markdown
        }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = ""
        result.reserveCapacity(markdown.count)
        var cursor = 0
        for match in regex.matches(in: markdown, options: [], range: full) {
            let urlRange = match.range(at: 1)
            guard urlRange.location != NSNotFound else { continue }
            if urlRange.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: urlRange.location - cursor))
            }
            let original = ns.substring(with: urlRange)
            result += resolvedMarkdownURL(original, base: base)
            cursor = urlRange.location + urlRange.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    nonisolated private static func resolvedMarkdownURL(_ raw: String, base: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return raw }
        if trimmed.hasPrefix("#") { return raw }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon].lowercased()
            if ["http", "https", "mailto", "tel", "data", "ftp"].contains(scheme) {
                return raw
            }
        }
        var path = trimmed
        if path.hasPrefix("./") {
            path.removeFirst(2)
        }
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return URL(string: path, relativeTo: base)?.absoluteString ?? raw
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
    let lastModified: String?
    let trendingScore: Double?
    let libraryName: String?
    let license: String?
    let config: HubConfig?
    let safetensors: HubSafetensors?

    enum Checkpoint: String, CodingKey {
        case id, modelId, downloads, likes, tags, createdAt, lastModified, trendingScore
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case cardData
        case config
        case safetensors
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
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        trendingScore = try container.decodeIfPresent(Double.self, forKey: .trendingScore)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        license = (try? container.decodeIfPresent(HubCardData.self, forKey: .cardData))?.license
        config = try? container.decodeIfPresent(HubConfig.self, forKey: .config)
        safetensors = try? container.decodeIfPresent(HubSafetensors.self, forKey: .safetensors)
    }
}

private struct HubCardData: Decodable {
    let license: String?

    enum Checkpoint: String, CodingKey {
        case license
        case licenseName = "license_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Checkpoint.self)
        if let value = try? container.decode(String.self, forKey: .license) {
            license = value
        } else if let values = try? container.decode([String].self, forKey: .license) {
            license = values.first
        } else {
            license = try container.decodeIfPresent(String.self, forKey: .licenseName)
        }
    }
}

private struct HubConfig: Decodable {
    let modelType: String?
    let architectures: [String]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case architectures
    }
}

private struct HubSafetensors: Decodable {
    let total: Int64?
    let parameters: [String: Int64]

    enum Checkpoint: String, CodingKey {
        case total
        case parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Checkpoint.self)
        total = Self.decodeInt64(container, forKey: .total)
        if let raw = try? container.decode([String: HubFlexibleInt64].self, forKey: .parameters) {
            parameters = raw.mapValues(\.value)
        } else {
            parameters = [:]
        }
    }

    private static func decodeInt64(_ container: KeyedDecodingContainer<Checkpoint>, forKey key: Checkpoint) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}

private struct HubFlexibleInt64: Decodable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
        } else if let value = try? container.decode(Double.self) {
            self.value = Int64(value)
        } else {
            self.value = 0
        }
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
