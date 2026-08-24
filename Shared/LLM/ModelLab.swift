import SwiftUI

enum ModelLab: String, CaseIterable, Sendable {
    case openai
    case deepseek
    case zai
    case qwen
    case google
    case kimi
    case mistral
    case meta
    case nvidia

    var stems: [String] {
        switch self {
        case .openai: ["gpt"]
        case .deepseek: ["deepseek"]
        case .zai: ["glm"]
        case .qwen: ["qwen"]
        case .google: ["gemma"]
        case .kimi: ["kimi"]
        case .mistral: ["mistral"]
        case .meta: ["llama", "muse"]
        case .nvidia: ["nemotron"]
        }
    }

    var assetName: String {
        "Lab\(rawValue.prefix(1).uppercased())\(rawValue.dropFirst())"
    }

    var usesTemplateRendering: Bool {
        self == .openai || self == .zai
    }

    static func infer(from strings: String...) -> ModelLab? {
        infer(from: strings)
    }

    static func infer(from strings: [String]) -> ModelLab? {
        let tokens = strings
            .joined(separator: " ")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
        guard !tokens.isEmpty else { return nil }

        for lab in ModelLab.allCases {
            for stem in lab.stems where tokens.contains(where: { tokenMatches($0, stem: stem) }) {
                return lab
            }
        }
        return nil
    }

    private static func tokenMatches(_ token: Substring, stem: String) -> Bool {
        guard token.hasPrefix(stem) else { return false }
        // GPTQ is a quantization method, not OpenAI GPT.
        if stem == "gpt" && token.hasPrefix("gptq") {
            return false
        }
        return true
    }
}

struct ModelLabIcon: View {
    let lab: ModelLab
    var size: CGFloat = 28

    var body: some View {
        Image(lab.assetName)
            .renderingMode(lab.usesTemplateRendering ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AppleIntelligenceIcon: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "apple.intelligence")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Self.bloom)
            .padding(1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static let bloom = LinearGradient(
        colors: [
            Color(red: 0.490, green: 0.757, blue: 0.973),
            Color(red: 0.690, green: 0.549, blue: 1.000),
            Color(red: 0.957, green: 0.494, blue: 0.769)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
