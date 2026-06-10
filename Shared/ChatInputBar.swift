//
//  ChatInputBar.swift
//  Shared
//

import SwiftUI

private struct InputRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 38
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatInputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let placeholder: String
    let isLoading: Bool
    let isEditing: Bool
    let showsAttachmentButton: Bool
    let pendingAttachments: [ChatMessageAttachment]
    let onSend: () -> Void
    let onPickPhoto: () -> Void
    let onTakePhoto: () -> Void
    let onPickFile: () -> Void
    let onRemoveAttachment: (UUID) -> Void

    @State private var rowHeight: CGFloat = 38

    private let sendButtonSize: CGFloat = 30
    private let minRowHeight: CGFloat = 38

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        return (hasText || hasAttachments) && !isLoading
    }

    var body: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            PendingAttachmentChip(
                                attachment: attachment,
                                onRemove: { onRemoveAttachment(attachment.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    if showsAttachmentButton {
                        attachmentButton
                    }

                    HStack(alignment: .center, spacing: 8) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .disabled(isLoading)
                            .focused($isFocused)
                            .onSubmit(onSend)
                            .onKeyPress(keys: [.return]) { press in
                                if press.modifiers == .shift {
                                    text += "\n"
                                    return .handled
                                }
                                return .ignored
                            }

                        sendSlot
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .frame(minHeight: minRowHeight)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: InputRowHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    )
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }
        .onPreferenceChange(InputRowHeightKey.self) { height in
            rowHeight = max(height, minRowHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var attachmentButton: some View {
        Menu {
            Button {
                onPickPhoto()
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                onTakePhoto()
            } label: {
                Label("Take Photo", systemImage: "camera")
            }

            Button {
                onPickFile()
            } label: {
                Label("Choose File", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: rowHeight, height: rowHeight)
        }
        .frame(width: rowHeight, height: rowHeight)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Add attachment")
        .disabled(isLoading)
    }

    @ViewBuilder
    private var sendSlot: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if canSend {
                Button(action: onSend) {
                    Image(systemName: isEditing ? "checkmark" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .background(Circle().fill(.white))
                }
                .accessibilityLabel(isEditing ? "Confirm edit" : "Send message")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: sendButtonSize, height: sendButtonSize)
        .animation(.snappy(duration: 0.2), value: canSend)
        .animation(.snappy(duration: 0.2), value: isLoading)
    }
}

private struct PendingAttachmentChip: View {
    let attachment: ChatMessageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            attachmentThumbnail
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(attachment.label)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var attachmentThumbnail: some View {
        if attachment.isModelSupportedImage,
           let uiImage = UIImage(contentsOfFile: attachment.fileURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "doc.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
