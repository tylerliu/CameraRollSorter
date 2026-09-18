import Photos
import SwiftUI

struct PhotoThumbnail: View {
    let identifier: String
    var size: CGFloat = 100
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var generation = UUID()
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if finished {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .accessibilityLabel("Preview unavailable locally")
            } else { ProgressView() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: load)
        .onChange(of: identifier) { _, _ in load() }
        .onDisappear {
            cancelRequest()
        }
    }

    private func load() {
        cancelRequest()
        let token = UUID()
        generation = token
        image = nil
        finished = false
        requestImage(token: token, attempt: 0)
    }

    private func requestImage(token: UUID, attempt: Int) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            finished = true
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        let dimension = max(1, size * 2)
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: dimension, height: dimension), contentMode: .aspectFit, options: options) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard generation == token else { return }
                if let result { image = result }
                guard !degraded else { return }
                request = nil
                if result == nil, !cancelled, error != nil, attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                    guard generation == token else { return }
                    requestImage(token: token, attempt: attempt + 1)
                } else {
                    finished = true
                }
            }
        }
    }

    private func cancelRequest() {
        generation = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
    }
}
