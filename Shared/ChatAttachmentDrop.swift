//
//  ChatAttachmentDrop.swift
//  Shared
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ChatAttachmentDrop {
    static let supportedTypes: [UTType] = [
        .fileURL,
        .image,
        .jpeg,
        .png,
        .heic,
        .gif,
        .movie,
        .mpeg4Movie,
        .quickTimeMovie,
        .video,
        .audiovisualContent,
        .audio,
        .mp3,
        .wav,
        .pdf,
        .plainText,
        .data,
        .item,
    ]

    @MainActor
    static func importProviders(_ providers: [NSItemProvider], into chatManager: ChatManager) async {
        guard ChatAttachments.isSupported, !chatManager.isLoading else { return }

        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                importFileURL(url, into: chatManager)
                continue
            }

            if let image = await loadImage(from: provider) {
                chatManager.addPendingImageAttachment(image, label: "Photo.jpg")
                continue
            }

            if let data = await loadData(from: provider) {
                importData(data, suggestedName: "attachment", into: chatManager)
            }
        }
    }

    @MainActor
    private static func importFileURL(_ url: URL, into chatManager: ChatManager) {
        let label = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
        let kind = ChatAttachments.kind(
            mimeType: ChatAttachments.mimeType(for: url),
            fileURL: url
        )
        chatManager.addPendingAttachment(from: url, label: label, kind: kind)
    }

    @MainActor
    private static func importData(_ data: Data, suggestedName: String, into chatManager: ChatManager) {
        chatManager.addPendingDataAttachment(data, label: "\(suggestedName).dat")
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        let typeIdentifiers = [UTType.fileURL.identifier, UTType.item.identifier]

        for typeIdentifier in typeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let url = await loadFileRepresentation(from: provider, typeIdentifier: typeIdentifier) {
                return url
            }

            if let url = await loadItemURL(from: provider, typeIdentifier: typeIdentifier) {
                return url
            }
        }

        return nil
    }

    private static func loadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)

                do {
                    if FileManager.default.fileExists(atPath: temporaryURL.path) {
                        try FileManager.default.removeItem(at: temporaryURL)
                    }
                    try FileManager.default.copyItem(at: url, to: temporaryURL)
                    continuation.resume(returning: temporaryURL)
                } catch {
                    continuation.resume(returning: url)
                }
            }
        }
    }

    private static func loadItemURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: url(from: item))
            }
        }
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = item as? String, let url = URL(string: string) {
            return url
        }
        return nil
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        if provider.canLoadObject(ofClass: UIImage.self) {
            return await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }

        let imageTypes = [UTType.image, .jpeg, .png, .heic, .gif].map(\.identifier)
        for typeIdentifier in imageTypes where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let data = await loadData(from: provider, typeIdentifier: typeIdentifier),
               let image = UIImage(data: data) {
                return image
            }
        }

        return nil
    }

    private static func loadData(from provider: NSItemProvider) async -> Data? {
        let typeIdentifiers = [UTType.data.identifier, UTType.item.identifier, UTType.content.identifier]
        for typeIdentifier in typeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let data = await loadData(from: provider, typeIdentifier: typeIdentifier) {
                return data
            }
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

private struct AttachmentDropModifier: ViewModifier {
    @ObservedObject var chatManager: ChatManager
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .onDrop(of: ChatAttachmentDrop.supportedTypes, isTargeted: $isTargeted) { providers in
                Task { @MainActor in
                    await ChatAttachmentDrop.importProviders(providers, into: chatManager)
                }
                return true
            }
    }
}

extension View {
    @ViewBuilder
    func attachmentDropTarget(chatManager: ChatManager, isTargeted: Binding<Bool>) -> some View {
        if ChatAttachments.isSupported {
            modifier(AttachmentDropModifier(chatManager: chatManager, isTargeted: isTargeted))
        } else {
            self
        }
    }

    @ViewBuilder
    func attachmentDropOverlay(isTargeted: Bool) -> some View {
        overlay {
            if isTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.title2)
                        Text("Drop to attach")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}
