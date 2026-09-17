import PhotosUI
import SwiftUI

struct LimitedLibraryPicker: UIViewControllerRepresentable {
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> PickerHost {
        let host = PickerHost()
        host.onFinished = onFinished
        return host
    }
    func updateUIViewController(_ uiViewController: PickerHost, context: Context) {}

    final class PickerHost: UIViewController {
        var onFinished: (() -> Void)?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                self?.onFinished?()
            }
        }
    }
}
