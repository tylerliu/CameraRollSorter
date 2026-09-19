import Photos
import SwiftUI

struct PhotoThumbnail: View {
    let identifier: String
    var size: CGFloat = 100
    /// When true, fills the square by cropping the image (center-crop, like the
    /// Photos grid). When false (default), fits the whole image letterboxed.
    var fill: Bool = false
    /// Corner radius of the clipped tile.
    var cornerRadius: CGFloat = 8
    /// Called on the main actor whenever a non-degraded image is successfully loaded.
    /// The filmstrip and chooser use this to avoid a blank flash when switching photos.
    var onImageLoaded: (@MainActor (UIImage) -> Void)? = nil

    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var generation = UUID()
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else if finished {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .accessibilityLabel("Preview unavailable locally")
            } else { ProgressView() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear(perform: load)
        .onChange(of: identifier) { _, _ in load() }
        .onDisappear(perform: cancelRequest)
    }

    private func load() {
        // Fast path: a finished thumbnail already in the shared cache shows
        // immediately with no spinner — this is what keeps scroll-back smooth.
        if let cached = ThumbnailProvider.shared.cachedImage(id: identifier, size: size, fill: fill) {
            image = cached
            finished = true
            return
        }

        cancelRequest()
        let token = UUID()
        generation = token
        image = nil
        finished = false

        request = ThumbnailProvider.shared.requestThumbnail(
            id: identifier, size: size, fill: fill
        ) { result, isFinal in
            guard generation == token else { return }
            if let result { image = result }
            guard isFinal else { return }   // keep waiting for the final frame
            request = nil
            finished = true
            if let result { onImageLoaded?(result) }
        }
    }

    private func cancelRequest() {
        generation = UUID()
        ThumbnailProvider.shared.cancel(request)
        request = nil
    }
}
