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
        .onDisappear {
            generation = UUID()
            if let request { PHImageManager.default().cancelImageRequest(request) }
        }
    }

    private func load() {
        let token = UUID()
        generation = token
        finished = false
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            finished = true
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size * 2, height: size * 2), contentMode: .aspectFit, options: options) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            Task { @MainActor in
                guard generation == token else { return }
                if let result { image = result }
                if !degraded { finished = true }
            }
        }
    }
}
