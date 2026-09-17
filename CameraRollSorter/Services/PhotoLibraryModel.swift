import Photos
import Observation
import UIKit

@MainActor @Observable
final class PhotoLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var groups: [PhotoSequence] = []
    var pairs: [SimilarityPair] = []
    var analysisError: String?
    var progress = ""
    var threshold: Float = 0.4
    private var photos: [TimedPhoto] = []
    private let analyzer = SimilarityAnalyzer()
    var isScanning = false
    var hasScanned = false
    var summary = ""
    var revision = UUID()
    private var scanTask: Task<Void, Never>?
    private let scanner = SequenceScanner()
    private var observing = false
    var canRead: Bool { authorization == .authorized || authorization == .limited }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        scanTask?.cancel()
        groups = []
        pairs = []
        photos = []
        analysisError = nil
        progress = "Reading photo dates…"
        revision = UUID()
        hasScanned = false
        isScanning = false
        guard canRead else { summary = ""; return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        isScanning = true
        scanTask = Task {
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            photos = result.photos
            summary = "\(result.count) accessible photos across your library. \(result.missingDates) accessible photos have no capture date and cannot be grouped."
            do {
                let token = revision
                let scores = try await analyzer.analyzeCandidates(result.groups) { [self] completed, total in
                    guard self.revision == token else { return }
                    self.progress = "Comparing photos: \(completed) of \(total) pairs"
                }
                guard !Task.isCancelled else { return }
                pairs = scores.pairs
                summary += " \(scores.unavailable) candidate photos unavailable locally."
                applyThreshold()
            } catch {
                guard !Task.isCancelled else { return }
                analysisError = "Similarity analysis failed: \(error.localizedDescription). Pull to refresh to retry."
            }
            hasScanned = true
            isScanning = false
        }
    }

    func applyThreshold() {
        threshold = Float(UserDefaults.standard.object(forKey: "review.distanceThreshold") as? Double ?? 0.4)
        groups = SimilarityGrouping.groups(photos: photos, pairs: pairs, threshold: threshold)
    }

    func scores(for group: PhotoSequence) -> [SimilarityPair] {
        let ids = Set(group.photos.map(\.id))
        let candidates = pairs.filter { ids.contains($0.first) && ids.contains($0.second) }
        return SimilarityGrouping.minimumSpanningTree(photos: group.photos, pairs: candidates, threshold: threshold)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}

private actor SequenceScanner {
    struct Result: Sendable {
        let groups: [CandidateNeighborhood]
        let photos: [TimedPhoto]
        let count: Int
        let missingDates: Int
    }

    func scan() -> Result {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [TimedPhoto] = []
        var missing = 0
        assets.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate {
                photos.append(TimedPhoto(id: asset.localIdentifier, date: date))
            } else { missing += 1 }
        }
        return Result(groups: SequenceGrouping.groups(photos), photos: photos, count: photos.count, missingDates: missing)
    }
}
