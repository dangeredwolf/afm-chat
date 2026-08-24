//
//  ChatAttachmentPickers.swift
//  Shared
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImagePicked: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImagePicked = onImagePicked
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            } else {
                onCancel()
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
enum MacFilePicker {
    private static var activeCoordinator: DocumentPickerCoordinator?

    @MainActor
    static func pickFiles(completion: @escaping (Result<[URL], Error>) -> Void) {
        guard let presenter = topViewController() else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true

        let coordinator = DocumentPickerCoordinator { result in
            activeCoordinator = nil
            completion(result)
        }
        activeCoordinator = coordinator
        picker.delegate = coordinator
        presenter.present(picker, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return nil
        }

        let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene.windows.first?.rootViewController
        guard let root else { return nil }
        return topViewController(from: root)
    }

    @MainActor
    private static func topViewController(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        return controller
    }
}

private final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    let onComplete: (Result<[URL], Error>) -> Void

    init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
        self.onComplete = onComplete
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        onComplete(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
        onComplete(.failure(CocoaError(.userCancelled)))
    }
}
#endif
