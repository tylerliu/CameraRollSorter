import Photos
import PhotosUI
import SwiftUI

struct ZoomablePhotoView: View {
    let identifier: String
    let onSwipeUp: () -> Void

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var isLivePhoto = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ZStack {
                    PhotoThumbnail(
                        identifier: identifier,
                        size: max(1, min(geometry.size.width, geometry.size.height))
                    )
                    if isLivePhoto {
                        LivePhotoPlayerView(identifier: identifier, targetSize: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(magnificationGesture)
                .simultaneousGesture(dragGesture)
                .onTapGesture(count: 2, perform: resetZoom)

                if isLivePhoto {
                    Label {
                        Text("LIVE")
                    } icon: {
                        Image(uiImage: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
        .task(id: identifier) {
            resetZoom()
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            isLivePhoto = asset?.mediaSubtypes.contains(.photoLive) == true
        }
        .accessibilityLabel(isLivePhoto
            ? "Current Live Photo. Press and hold to play, pinch to zoom, or swipe up for information."
            : "Current photo. Pinch to zoom or swipe up for information.")
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(5, max(1, settledScale * value.magnification))
                if scale == 1 { offset = .zero }
            }
            .onEnded { _ in
                settledScale = scale
                if scale == 1 {
                    offset = .zero
                    settledOffset = .zero
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if scale > 1 {
                    settledOffset = offset
                } else if value.translation.height < -70,
                          abs(value.translation.height) > abs(value.translation.width) {
                    onSwipeUp()
                }
            }
    }

    private func resetZoom() {
        withAnimation(.snappy) {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
        }
    }
}
