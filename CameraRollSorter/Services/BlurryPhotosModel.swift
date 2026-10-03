import Foundation
import Observation
import Photos
import Vision

/// A detected low-aesthetic photo. Parallels `LivePhotoItem`; `score` is the
/// Vision overall aesthetics score (higher is better) — a photo is flagged
/// when it is non-utility and its score falls below the active cutoff. The
/// stored score lets a *lowering* sensitivity change re-filter in place.
struct BlurryPhotoItem: Identifiable, Sendable {
    let id: String          // PHAsset.localIdentifier
    let date: Date
    let score: Double        // Vision overall aesthetics score; lower is worse
}

/// Errors surfaced by the blurry-photos deletion flow. Parallels
/// `PhotoLibraryDeletionError`, with user-facing messages.
enum BlurryPhotosError: LocalizedError {
    case writeAccessRequired
    case changeRejected

    var errorDescription: String? {
        switch self {
        case .writeAccessRequired:
            return String(localized: "Photo access does not allow changes. Grant full or limited read-write access and try again.")
        case .changeRejected:
            return String(localized: "Photos did not accept the deletion request.")
        }
    }
}

/// Pure candidate predicate mirroring the scan fetch predicate: an asset is in
/// scope iff it is an image (`.image` media type, which already excludes videos)
/// and is not a screenshot (`PHAssetMediaSubtype.photoScreenshot`). Live Photos
/// are ordinary `.image` assets and are intentionally admitted; they are scored
/// on their still frame. Extracted so scan scope (Requirements 3.1–3.3) can be
/// checked without PhotoKit.
func isScannable(mediaType: PHAssetMediaType, mediaSubtypes: PHAssetMediaSubtype) -> Bool {
    guard mediaType == .image else { return false }
    return !mediaSubtypes.contains(.photoScreenshot)
}

/// Background actor that finds low-aesthetic candidates and classifies them.
/// Mirrors `LivePhotoScanner`: the fetch is metadata-only and fast; the
/// per-batch classification runs Vision's image-aesthetics request per photo.
private actor BlurryPhotoScanner {
    /// Fast metadata-only fetch of every scan candidate (id + date). The
    /// `.image` media type already excludes videos (Requirements 3.1, 3.2), and
    /// the predicate masks out screenshots (Requirement 3.3). Live Photos are
    /// ordinary `.image` assets and are intentionally kept; they are classified
    /// on their still frame later. Assets without a capture date are skipped.
    func fetchCandidates() -> [TimedPhoto] {
        let options = PHFetchOptions()
        // Keep only assets whose subtype does NOT include screenshot.
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) == 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var result: [TimedPhoto] = []
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            result.append(TimedPhoto(id: asset.localIdentifier, date: date))
        }
        return result
    }

    /// Classify a batch of candidates using Vision's image-aesthetics request,
    /// returning only the LOW-aesthetic ones in candidate order: a photo
    /// qualifies when Vision does NOT flag it as "utility" (screenshots,
    /// receipts, documents) AND its overall aesthetics score is below `cutoff`.
    /// Each photo is scored inside its own `autoreleasepool` so decoded buffers
    /// are released promptly across a large batch. The capture date is carried
    /// through from the candidate (already fetched), so there's no extra
    /// per-photo PhotoKit lookup.
    ///
    /// Candidates whose downscaled image can't be loaded locally, and any Vision
    /// can't score (notably the Simulator, where the request throws), are
    /// dropped — the flow simply shows nothing for those rather than fabricating
    /// a score.
    func lowAestheticItems(in candidates: [TimedPhoto], cutoff: Double) async -> [BlurryPhotoItem] {
        guard #available(iOS 18.0, *) else { return [] }
        var items: [BlurryPhotoItem] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let image = await PhotoImageLoading.image(for: candidate.id, targetSize: 512)
            guard !Task.isCancelled else { break }
            autoreleasepool {
                guard let cgImage = image?.platformCGImage else { return }
                guard let score = try? AestheticsRequestRunner.score(for: cgImage) else { return }
                // Non-utility only, and below the low-aesthetic cutoff.
                guard !score.isUtility, Double(score.overall) < cutoff else { return }
                items.append(BlurryPhotoItem(id: candidate.id, date: candidate.date, score: Double(score.overall)))
            }
        }
        return items
    }
}

extension BlurryPhotoItem: ScanItem {}

/// Per-screen scan model for the Low-aesthetic flow. The shared incremental
/// scan lives in `IncrementalScanModel`; this adds aesthetics classification,
/// the sensitivity re-check, and deletion.
final class BlurryPhotosModel: IncrementalScanModel<BlurryPhotoItem> {
    @ObservationIgnored private let scanner = BlurryPhotoScanner()
    // Cutoff in effect for classification. Changed only via `applySensitivity()`
    // so a settings change can't race the batches.
    @ObservationIgnored private var activeCutoff: Double = BlurSensitivity.currentCutoff

    // Fewer per batch than Live→Still: each item does an image decode + a
    // Vision aesthetics request, so smaller batches keep the UI responsive.
    init() {
        super.init(windowPrefix: "blurry", batchSize: 120)
    }

    override func scan() {
        activeCutoff = BlurSensitivity.currentCutoff
        super.scan()
    }

    override func fetchCandidates() async -> [TimedPhoto] {
        await scanner.fetchCandidates()
    }

    override func classify(_ batch: [TimedPhoto]) async -> [BlurryPhotoItem] {
        await scanner.lowAestheticItems(in: batch, cutoff: activeCutoff)
    }

    /// Called when the sensitivity setting changes; no-op when unchanged.
    ///
    /// The flagged decision (score < cutoff) is monotonic, so:
    /// - LOWERING the cutoff yields a subset of current results: re-filter
    ///   `items` in place by stored score (no re-scan, scroll kept). Later
    ///   batches use the new cutoff, so results stay consistent.
    /// - RAISING it can admit photos whose scores were never kept, so the
    ///   window is re-classified from the front.
    func applySensitivity() {
        let newCutoff = BlurSensitivity.currentCutoff
        guard newCutoff != activeCutoff else { return }
        let lowering = newCutoff < activeCutoff
        activeCutoff = newCutoff
        if lowering {
            cancelClassification()
            items = items.filter { BlurSensitivity.isBlurry(variance: $0.score, cutoff: newCutoff) }
        } else {
            restartClassification()
        }
    }

    /// Delete the selected photos in one batched request. There is no in-app
    /// confirmation: the OS Recently Deleted prompt is the only gate. On
    /// failure/cancel `items` is unchanged and the error is rethrown (and
    /// surfaced via `errorMessage` unless the user cancelled).
    @discardableResult
    func deletePhotos(_ identifiers: Set<String>) async throws -> Int {
        guard canRead else {
            errorMessage = BlurryPhotosError.writeAccessRequired.errorDescription
            throw BlurryPhotosError.writeAccessRequired
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return 0 }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: BlurryPhotosError.changeRejected)
                    }
                }
            }
        } catch {
            // Cancelling the system delete prompt isn't an error to surface.
            if !PhotoLibraryErrors.isUserCancelled(error) {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }

        removeFromCurrentResults(Set(assets.map(\.localIdentifier)))
        return assets.count
    }
}
