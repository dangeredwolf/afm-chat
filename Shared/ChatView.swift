//
//  ChatView.swift
//  Shared
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI
import FoundationModels
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject var chatManager: ChatManager
    @FocusState private var isInputFocused: Bool
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var isAttachmentDropTargeted = false
    @State private var speechInputManager: SpeechInputManager?
    
    init(chatManager: ChatManager) {
        _chatManager = StateObject(wrappedValue: chatManager)
    }
    
    var body: some View {
        VStack {
            // Chat messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatManager.currentMessages.isEmpty {
                            // Welcome message for new chats
                            VStack(spacing: 16) {
                                Text("Start a New Conversation")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                // Show current chat settings
                                VStack(spacing: 8) {
                                    Text("Chat Settings")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Model: \(chatManager.currentModel.displayName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if AFMModelCatalog.supportsReasoning(chatManager.currentModel) {
                                        Text("Reasoning: \(chatManager.currentReasoningLevel.displayName)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Text("Temperature: \(chatManager.currentTemperature, specifier: "%.1f")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(12)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                        } else {
                            ForEach(chatManager.currentMessages) { message in
                                ChatBubble(
                                    message: message,
                                    isStreaming: chatManager.isLoading
                                        && !message.isUser
                                        && message.id == chatManager.currentMessages.last(where: { !$0.isUser })?.id,
                                    onEdit: { messageId in
                                        chatManager.editMessage(messageId)
                                        isInputFocused = true
                                    },
                                    onCopy: { messageId in
                                        chatManager.copyMessage(messageId)
                                    },
                                    onRetry: { messageId in
                                        chatManager.retryMessage(messageId)
                                    }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: chatManager.currentMessages.count) { _ in
                    // Auto-scroll to bottom when new messages are added
                    if let lastMessage = chatManager.currentMessages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onTapGesture {
                    // Dismiss keyboard when tapping on chat area
                    isInputFocused = false
                }
            }
            
            // Editing indicator
            if chatManager.editingMessageId != nil {
                HStack {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundColor(.orange)
                    Text("Editing message...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") {
                        chatManager.cancelEditing()
                        isInputFocused = false
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .background(Color.orange.opacity(0.05))
            }
            
            ChatInputBar(
                text: $chatManager.inputText,
                isFocused: $isInputFocused,
                placeholder: chatManager.editingMessageId != nil ? "Edit your message..." : "Type your message...",
                isLoading: chatManager.isLoading,
                isEditing: chatManager.editingMessageId != nil,
                showsAttachmentButton: ChatAttachments.isSupported,
                showsMicButton: SpeechInputSupport.isAvailable,
                isRecording: speechInputManager?.isRecording ?? false,
                isSpeechPreparing: speechInputManager?.isPreparing ?? false,
                pendingAttachments: chatManager.pendingAttachments,
                onSend: {
                    Task {
                        if #available(iOS 26, *), speechInputManager?.isRecording == true {
                            await speechInputManager?.stopRecording()
                        }
                    }
                    chatManager.sendMessage()
                    isInputFocused = false
                },
                onMicTap: {
                    handleMicTap()
                },
                onPickPhoto: {
                    showPhotoPicker = true
                },
                onTakePhoto: {
                    showCamera = true
                },
                onPickFile: {
                    #if targetEnvironment(macCatalyst)
                    DispatchQueue.main.async {
                        MacFilePicker.pickFiles { result in
                            handleImportedFiles(result)
                        }
                    }
                    #else
                    DispatchQueue.main.async {
                        showFileImporter = true
                    }
                    #endif
                },
                onRemoveAttachment: { attachmentId in
                    chatManager.removePendingAttachment(attachmentId)
                }
            )
        }
        .attachmentDropTarget(chatManager: chatManager, isTargeted: $isAttachmentDropTargeted)
        .attachmentDropOverlay(isTargeted: isAttachmentDropTargeted)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 5,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await importSelectedPhotos(newItems)
                selectedPhotoItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker(
                onImagePicked: { image in
                    showCamera = false
                    chatManager.addPendingImageAttachment(image, label: "Photo.jpg")
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
        #if !targetEnvironment(macCatalyst)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImportedFiles(result)
        }
        #endif
        .onAppear {
            if #available(iOS 26, *), speechInputManager == nil {
                speechInputManager = SpeechInputManager()
            }
        }
    }

    private func handleMicTap() {
        guard #available(iOS 26, *) else { return }
        if speechInputManager == nil {
            speechInputManager = SpeechInputManager()
        }
        guard let speechInputManager else { return }

        speechInputManager.toggleRecording(
            currentText: chatManager.inputText,
            onTextUpdate: { updatedText in
                chatManager.inputText = updatedText
            },
            onAutoSend: {
                chatManager.sendMessage()
                isInputFocused = false
            }
        )
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            switch result {
            case .success(let urls):
                importFiles(from: urls)
            case .failure(let error):
                if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                    return
                }
                print("File import failed: \(error)")
            }
        }
    }

    @MainActor
    private func importFiles(from urls: [URL]) {
        for url in urls {
            let label = url.lastPathComponent
            let kind: ChatMessageAttachmentKind = ChatAttachments.isImageAttachment(
                mimeType: ChatAttachments.mimeType(for: url),
                fileURL: url
            ) ? .image : .file
            chatManager.addPendingAttachment(from: url, label: label, kind: kind)
        }
    }

    @MainActor
    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                chatManager.addPendingImageAttachment(image, label: "Photo.jpg")
            }
        }
    }
}
