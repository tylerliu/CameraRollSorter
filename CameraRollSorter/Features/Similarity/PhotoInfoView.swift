import ImageIO
import MapKit
import Photos
import SwiftUI

struct PhotoInfoView: View {
    let identifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var asset: PHAsset?
    @State private var filename: String?
    @State private var cameraMetadata: CameraMetadata?
    @State private var didLoadCameraMetadata = false

    var body: some View {
        NavigationStack {
            List {
                if let asset {
                    Section("Captured") {
                        LabeledContent("Date") {
                            if let date = asset.creationDate {
                                Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            } else {
                                Text("Unknown")
                            }
                        }
                    }
                    Section("Image") {
                        LabeledContent("Filename", value: filename ?? "Unknown")
                        LabeledContent("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                        LabeledContent("Favorite", value: asset.isFavorite ? "Yes" : "No")
                        if let date = asset.modificationDate {
                            LabeledContent("Modified") {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                            }
                        }
                    }
                    Section("Camera") {
                        if let cameraMetadata {
                            if let camera = cameraMetadata.camera {
                                LabeledContent("Camera", value: camera)
                            }
                            if let lens = cameraMetadata.lens {
                                LabeledContent("Lens", value: lens)
                            }
                            if let focalLength = cameraMetadata.focalLength {
                                LabeledContent("35mm equivalent", value: focalLength)
                            }
                            if cameraMetadata.isEmpty {
                                Text("No camera or lens information is embedded in this photo.")
                                    .foregroundStyle(.secondary)
                            }
                        } else if didLoadCameraMetadata {
                            Text("Camera information isn’t available locally.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                ProgressView()
                                Text("Reading camera information…")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let location = asset.location {
                        Section("Location") {
                            Map(initialPosition: .region(mapRegion(for: location.coordinate))) {
                                Marker("Photo location", coordinate: location.coordinate)
                            }
                            .mapStyle(.standard(elevation: .realistic))
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Map showing where this photo was taken")
                        }
                        .listRowInsets(EdgeInsets())
                    }
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                }
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: identifier) {
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            filename = asset.flatMap { PHAssetResource.assetResources(for: $0).first?.originalFilename }
            cameraMetadata = nil
            didLoadCameraMetadata = false
            if let asset {
                cameraMetadata = await loadCameraMetadata(for: asset)
            }
            didLoadCameraMetadata = true
        }
    }

    private func mapRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }

    private func loadCameraMetadata(for asset: PHAsset) async -> CameraMetadata? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                guard let data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any] else {
                    continuation.resume(returning: nil)
                    return
                }

                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let make = tiff?[kCGImagePropertyTIFFMake] as? String
                let model = tiff?[kCGImagePropertyTIFFModel] as? String
                let camera = [make, model]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { values, value in
                        if !values.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
                            values.append(value)
                        }
                    }
                    .joined(separator: " ")
                let lens = exif?[kCGImagePropertyExifLensModel] as? String
                let focalLength = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)
                    .map { "\($0.intValue) mm" }

                continuation.resume(returning: CameraMetadata(
                    camera: camera.isEmpty ? nil : camera,
                    lens: lens,
                    focalLength: focalLength
                ))
            }
        }
    }
}

private struct CameraMetadata {
    let camera: String?
    let lens: String?
    let focalLength: String?

    var isEmpty: Bool { camera == nil && lens == nil && focalLength == nil }
}
