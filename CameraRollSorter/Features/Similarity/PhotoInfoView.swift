import ImageIO
import MapKit
import Photos
import SwiftUI

struct PhotoInfoView: View {
    let identifier: String
    @State private var asset: PHAsset?
    @State private var filename: String?
    @State private var cameraMetadata: CameraMetadata?
    @State private var didLoadCameraMetadata = false

    var body: some View {
        NavigationStack {
            List {
                if let asset {
                    captureHeaderSection(asset)
                    imageSection(asset)
                    if let location = asset.location {
                        locationSection(location)
                    }
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Sections

    /// Photos-style header: date, and a camera row with the model plus a single
    /// photographic settings line (lens · ƒ · ISO · shutter).
    @ViewBuilder
    private func captureHeaderSection(_ asset: PHAsset) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "camera")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    if let cameraMetadata, let camera = cameraMetadata.camera {
                        Text(camera)
                            .font(.body.weight(.semibold))
                    } else {
                        Text("Camera")
                            .font(.body.weight(.semibold))
                    }
                    if let cameraMetadata {
                        if let lens = cameraMetadata.lens {
                            Text(lens)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let settings = cameraMetadata.settingsLine {
                            Text(settings)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if cameraMetadata.isEmpty {
                            Text("No camera information is embedded in this photo.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if didLoadCameraMetadata {
                        Text("Camera information isn’t available locally.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Reading camera information…")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            if let date = asset.creationDate {
                Text(date, format: .dateTime.weekday(.wide).month().day().year())
                    + Text("  ")
                    + Text(date, format: .dateTime.hour().minute())
            } else {
                Text("Capture date unknown")
            }
        }
    }

    @ViewBuilder
    private func imageSection(_ asset: PHAsset) -> some View {
        Section {
            LabeledContent("File name", value: filename ?? "Unknown")
            LabeledContent("Dimensions", value: dimensionsText(asset))
            LabeledContent("Favorite", value: asset.isFavorite ? "Yes" : "No")
            if let date = asset.modificationDate {
                LabeledContent("Modified") {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                }
            }
        }
    }

    @ViewBuilder
    private func locationSection(_ location: CLLocation) -> some View {
        Section {
            Map(initialPosition: .region(mapRegion(for: location.coordinate))) {
                Marker("Photo location", coordinate: location.coordinate)
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(height: 200)
            .accessibilityLabel("Map showing where this photo was taken")
        }
        .listRowInsets(EdgeInsets())
    }

    private func dimensionsText(_ asset: PHAsset) -> String {
        let megapixels = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
        let mp = megapixels >= 0.1 ? String(format: " (%.1f MP)", megapixels) : ""
        return "\(asset.pixelWidth) × \(asset.pixelHeight)\(mp)"
    }

    private func mapRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }

    // MARK: - Metadata loading

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
                continuation.resume(returning: CameraMetadata(properties: properties))
            }
        }
    }
}

// MARK: - Camera metadata model

private struct CameraMetadata {
    let camera: String?
    /// e.g. "24 mm ƒ1.78 · ISO 80 · 1/120 s" — a single Photos-style line.
    let settingsLine: String?
    /// e.g. "iPhone 15 Pro back triple camera 6.86mm ƒ1.78"
    let lens: String?

    var isEmpty: Bool { camera == nil && settingsLine == nil && lens == nil }

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        // Camera make + model, deduplicated (e.g. "Apple iPhone 15 Pro").
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let cameraName = [make, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
                    values.append(value)
                }
            }
            .joined(separator: " ")
        self.camera = cameraName.isEmpty ? nil : cameraName

        self.lens = exif?[kCGImagePropertyExifLensModel] as? String

        // Build the Photos-style settings line piece by piece.
        var parts: [String] = []

        // Focal length (prefer 35mm-equivalent, as Photos shows).
        if let equiv = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, equiv > 0 {
            parts.append("\(equiv) mm")
        } else if let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue, focal > 0 {
            parts.append(CameraMetadata.trimmed(focal) + " mm")
        }

        // Aperture (ƒ-number).
        if let fNumber = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue, fNumber > 0 {
            parts.append("ƒ" + CameraMetadata.trimmed(fNumber))
        }

        // ISO.
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
           let iso = isoArray.first?.intValue, iso > 0 {
            parts.append("ISO \(iso)")
        }

        // Shutter speed (exposure time) as a fraction.
        if let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, exposure > 0 {
            parts.append(CameraMetadata.shutterString(exposure))
        }

        self.settingsLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Trims trailing ".0" so 1.78 stays but 24.0 becomes 24.
    static func trimmed(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.2g", value)
    }

    /// Formats an exposure time as a shutter fraction, e.g. 0.008333 → "1/120 s".
    static func shutterString(_ exposure: Double) -> String {
        if exposure >= 1 {
            return trimmed(exposure) + " s"
        }
        let denominator = Int((1 / exposure).rounded())
        return "1/\(denominator) s"
    }
}
