import Foundation

enum ModelDisplayName {
    static func shortName(fromHubID id: String) -> String {
        let repoName = id.split(separator: "/").last.map(String.init) ?? id
        guard !repoName.isEmpty else { return id }

        var tokens = tokenize(repoName)
        tokens = dropLeadingVendors(tokens)
        guard !tokens.isEmpty else { return capitalizeFirst(repoName) }

        if let formatted = formatKnownFamily(tokens) {
            return formatted
        }
        return formatFallback(tokens, original: repoName)
    }
}

private extension ModelDisplayName {
    enum Family: CaseIterable {
        case gemma, qwen, llama, mistral, deepseek, kimi, nemotron, gptOss, glm, phi

        var stem: String {
            switch self {
            case .gemma: "gemma"
            case .qwen: "qwen"
            case .llama: "llama"
            case .mistral: "mistral"
            case .deepseek: "deepseek"
            case .kimi: "kimi"
            case .nemotron: "nemotron"
            case .gptOss: "gpt"
            case .glm: "glm"
            case .phi: "phi"
            }
        }

        var displayName: String {
            switch self {
            case .gemma: "Gemma"
            case .qwen: "Qwen"
            case .llama: "Llama"
            case .mistral: "Mistral"
            case .deepseek: "DeepSeek"
            case .kimi: "Kimi"
            case .nemotron: "Nemotron"
            case .gptOss: "GPT-OSS"
            case .glm: "GLM"
            case .phi: "Phi"
            }
        }

        static let gluedStems: [String] = Family.allCases
            .filter { $0 != .gptOss }
            .map(\.stem)
            .sorted { $0.count > $1.count }
    }

    static let vendorPrefixes: Set<String> = [
        "nvidia", "muse", "meta", "facebook", "google", "microsoft",
        "huggingface", "unsloth", "lmstudio", "bartowski"
    ]

    static let namedQuants: Set<String> = [
        "mlx", "mlc", "turboquant", "optiq", "dq", "awq", "gptq", "gguf",
        "safetensors", "hqq", "quanto", "compressed", "bnb", "bitsandbytes",
        "snac", "bit"
    ]

    static let sizeClasses: Set<String> = [
        "nano", "mini", "tiny", "small", "medium", "large", "xl", "xxl", "base"
    ]

    static let variants: Set<String> = [
        "flash", "coder", "vl", "vlm", "vision", "omni", "audio",
        "thinking", "r1", "distill", "math"
    ]

    static func tokenize(_ repoName: String) -> [String] {
        let normalized = repoName.replacingOccurrences(
            of: #"(\d+)-bit"#,
            with: "$1bit",
            options: [.regularExpression, .caseInsensitive]
        )
        return normalized
            .split { $0 == "-" || $0 == "_" }
            .map(String.init)
            .flatMap { token -> [String] in
                if isSize(token) || isMoEActive(token) {
                    return [token]
                }
                if let (family, version) = splitGluedFamilyVersion(token) {
                    return [family, version]
                }
                return [token]
            }
            .filter { !$0.isEmpty }
    }

    static func splitGluedFamilyVersion(_ token: String) -> (String, String)? {
        let lower = token.lowercased()
        for stem in Family.gluedStems {
            guard lower.hasPrefix(stem), lower.count > stem.count else { continue }
            let rest = String(token.dropFirst(stem.count))
            if isVersion(rest) {
                return (String(token.prefix(stem.count)), rest)
            }
        }
        return nil
    }

    static func dropLeadingVendors(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while tokens.count > 1, vendorPrefixes.contains(tokens[0].lowercased()) {
            tokens.removeFirst()
        }
        return tokens
    }

    static func formatKnownFamily(_ tokens: [String]) -> String? {
        guard let match = findFamily(in: tokens) else { return nil }

        var version: String?
        var foundVariants: [String] = []
        var size: String?
        var sizeClass: String?

        for (index, token) in tokens.enumerated() where !match.indices.contains(index) {
            if isQuantOrRuntime(token) { continue }
            if isDateOrBuild(token) { continue }

            if version == nil, isVersion(token) {
                version = displayVersion(token)
                continue
            }
            if isSize(token) {
                if size == nil { size = displaySize(token) }
                continue
            }
            if isMoEActive(token) { continue }

            let lower = token.lowercased()
            if sizeClasses.contains(lower) {
                if sizeClass == nil { sizeClass = capitalizeFirst(lower) }
                continue
            }
            if variants.contains(lower) {
                foundVariants.append(displayVariant(lower))
            }
        }

        var parts = [match.family.displayName]
        if let version { parts.append(version) }
        parts.append(contentsOf: foundVariants)
        if let size {
            parts.append(size)
        } else if let sizeClass {
            parts.append(sizeClass)
        }
        return parts.joined(separator: " ")
    }

    static func findFamily(in tokens: [String]) -> (family: Family, indices: Set<Int>)? {
        for index in tokens.indices {
            let lower = tokens[index].lowercased()
            if lower == "gpt" || lower == "gptoss" {
                if lower == "gpt",
                   index + 1 < tokens.count,
                   tokens[index + 1].lowercased() == "oss" {
                    return (.gptOss, [index, index + 1])
                }
                if lower == "gptoss" {
                    return (.gptOss, [index])
                }
            }
        }

        for index in tokens.indices {
            let lower = tokens[index].lowercased()
            for family in Family.allCases where family != .gptOss && lower == family.stem {
                return (family, [index])
            }
        }
        return nil
    }

    static func formatFallback(_ tokens: [String], original: String) -> String {
        let remaining = tokens.filter { !isQuantOrRuntime($0) }
        guard !remaining.isEmpty else { return capitalizeFirst(original) }

        return remaining.enumerated().map { index, token in
            if isSize(token) { return displaySize(token) }
            if index == 0 { return capitalizeFirst(token) }
            return token
        }.joined(separator: " ")
    }

    static func isQuantOrRuntime(_ token: String) -> Bool {
        let lower = token.lowercased()
        if namedQuants.contains(lower) { return true }
        if lower.hasSuffix("bit") {
            let core = lower.dropLast(3)
            if !core.isEmpty, core.allSatisfy(\.isNumber) { return true }
        }
        if lower.hasPrefix("q"),
           let second = lower.dropFirst().first,
           second.isNumber {
            return true
        }
        if lower.hasPrefix("mxfp") || lower.hasPrefix("nvfp") {
            let rest = lower.drop(while: { $0.isLetter })
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
        return lower == "fp16" || lower == "fp8" || lower == "bf16"
            || lower == "int4" || lower == "int8"
    }

    static func isSize(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard lower.hasSuffix("b"), lower.count > 1 else { return false }
        let core = String(lower.dropLast())
        if core.hasPrefix("e") {
            let digits = core.dropFirst()
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        if core.contains("x") {
            let parts = core.split(separator: "x", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
        if core.hasPrefix("a"), core.dropFirst().allSatisfy(\.isNumber), core.count > 1 {
            return false
        }
        return isDecimalNumber(core)
    }

    static func isMoEActive(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard lower.hasPrefix("a"), lower.hasSuffix("b"), lower.count > 2 else { return false }
        return lower.dropFirst().dropLast().allSatisfy(\.isNumber)
    }

    static func isVersion(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.hasPrefix("v"), isVersionNumber(String(lower.dropFirst())) {
            return true
        }
        if lower.hasPrefix("k"), isVersionNumber(String(lower.dropFirst())) {
            return true
        }
        return isVersionNumber(lower)
    }

    static func isVersionNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.contains(".") { return isDecimalNumber(value) }
        guard value.allSatisfy(\.isNumber) else { return false }
        return value.count <= 2
    }

    static func isDateOrBuild(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.count >= 4 && lower.allSatisfy(\.isNumber)
    }

    static func isDecimalNumber(_ value: String) -> Bool {
        guard !value.isEmpty, value.first != ".", value.last != "." else { return false }
        var sawDot = false
        for character in value {
            if character == "." {
                if sawDot { return false }
                sawDot = true
            } else if !character.isNumber {
                return false
            }
        }
        return true
    }

    static func displayVersion(_ token: String) -> String {
        let lower = token.lowercased()
        if lower.hasPrefix("v"), let second = lower.dropFirst().first, second.isNumber {
            return "V" + lower.dropFirst()
        }
        if lower.hasPrefix("k"), let second = lower.dropFirst().first, second.isNumber {
            return "K" + lower.dropFirst()
        }
        return token
    }

    static func displaySize(_ token: String) -> String {
        let lower = token.lowercased()
        guard lower.hasSuffix("b") else { return token }
        let core = lower.dropLast()
        if core.hasPrefix("e") {
            return "E\(core.dropFirst())B"
        }
        return "\(core)B"
    }

    static func displayVariant(_ lower: String) -> String {
        switch lower {
        case "vl", "vlm", "r1": lower.uppercased()
        default: capitalizeFirst(lower)
        }
    }

    static func capitalizeFirst(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
    }
}
