import Photos
import PhotosUI
import SwiftUI

struct LivePhotoPlayerView: UIViewRepresentable {
    let identifier: String
    let targetSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.load(
            identifier: identifier,
            targetSize: targetSize,
            into: view
        )
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopPlayback()
        view.livePhoto = nil
    }

    final class Coordinator {
        private var requestID: PHImageRequestID?
        private var loadedIdentifier: String?
        private var loadedSize = CGSize.zero
        private var generation = UUID()

        func load(identifier: String, targetSize: CGSize, into view: PHLivePhotoView) {
            let pixelSize = CGSize(
                width: max(1, targetSize.width * UIScreen.main.scale),
                height: max(1, targetSize.height * UIScreen.main.scale)
            )
            guard loadedIdentifier != identifier || loadedSize != pixelSize else { return }

            cancel()
            let token = UUID()
            generation = token
            loadedIdentifier = identifier
            loadedSize = pixelSize
            view.livePhoto = nil

            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject else { return }

            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: pixelSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self, weak view] livePhoto, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !cancelled, let livePhoto else { return }
                Task { @MainActor [weak self, weak view] in
                    guard self?.generation == token else { return }
                    view?.livePhoto = livePhoto
                }
            }
        }

        func cancel() {
            generation = UUID()
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
            requestID = nil
            loadedIdentifier = nil
            loadedSize = .zero
        }
    }
}
