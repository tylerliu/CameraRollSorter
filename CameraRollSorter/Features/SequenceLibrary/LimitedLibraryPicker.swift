import PhotosUI
import SwiftUI

struct LimitedLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> PickerHost {
        let host = PickerHost()
        return host
    }
    func updateUIViewController(_ host: PickerHost, context: Context) {
        host.onFinished = {
            isPresented = false
            onFinished()
        }
        host.wantsPresentation = isPresented
        // Defer presentation and binding updates until SwiftUI finishes updating.
        Task { @MainActor [weak host] in host?.presentIfNeeded() }
    }

    final class PickerHost: UIViewController {
        var onFinished: (() -> Void)?
        var wantsPresentation = false
        private var isPresentingPicker = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentIfNeeded()
        }

        func presentIfNeeded() {
            guard wantsPresentation, !isPresentingPicker, viewIfLoaded?.window != nil else { return }
            isPresentingPicker = true
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
                finish()
                return
            }
            // This Objective-C category requires PhotosUI to remain linked even
            // though no PhotosUI class is instantiated here.
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        }

        private func finish() {
            wantsPresentation = false
            isPresentingPicker = false
            onFinished?()
        }
    }
}
