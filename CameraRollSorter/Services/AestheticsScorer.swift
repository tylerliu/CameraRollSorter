import Photos
import UIKit
import Vision

struct AestheticsResult: Sendable {
    /// Measured overall aesthetics score per asset id (higher is better).
    let scores: [String: Float]
    /// Asset ids classified by Vision as "utility" (receipts, screenshots,
    /// documents) — excluded from best-photo suggestions.
    let utilityIDs: Set<String>
    /// Asset ids that could not be scored (unavailable locally, simulator,
    /// or Vision failure). Reported so the UI can distinguish "no suggestion"
    /// from "not yet scored".
    let unscoredIDs: Set<String>
}

/// Dedicated background actor for image-aesthetics scoring. Kept SEPARATE from
/// `SimilarityAnalyzer` so aesthetics work runs concurrently and never
/// serializes behind an in-flight similarity scan.
actor AestheticsScorer {
    /// Scores a small set of assets (typically one open group). Cancellation-
    /// aware; returns whatever was measured. Never throws for individual
    /// failures — those become `unscoredIDs`.
    func score(identifiers: [String]) async -> AestheticsResult {
        var scores: [String: Float] = [:]
        var utility: Set<String> = []
        var unscored: Set<String> = []

        guard #available(iOS 18.0, *) else {
            return AestheticsResult(scores: [:], utilityIDs: [], unscoredIDs: Set(identifiers))
        }

        for id in identifiers {
            if Task.isCancelled { break }
            let outcome = scoreOne(id)
            switch outcome {
            case let .scored(value, isUtility):
                scores[id] = value
                if isUtility { utility.insert(id) }
            case .failed:
                unscored.insert(id)
            }
        }
        return AestheticsResult(scores: scores, utilityIDs: utility, unscoredIDs: unscored)
    }

    private enum Outcome {
        case scored(Float, isUtility: Bool)
        case failed
    }

    @available(iOS 18.0, *)
    private func scoreOne(_ identifier: String) -> Outcome {
        autoreleasepool {
            guard let cgImage = PhotoImageLoading.synchronousImage(for: identifier, targetSize: 512)?.cgImage else {
                return .failed
            }
            do {
                let score = try AestheticsRequestRunner.score(for: cgImage)
                return .scored(score.overall, isUtility: score.isUtility)
            } catch {
                return .failed
            }
        }
    }
}

// MARK: - Best-photo selection

nonisolated enum BestPhotoSelector {
    /// Returns the ids to mark with a "best" dot.
    ///
    /// The margin is DYNAMIC rather than a fixed constant, because raw
    /// aesthetics scores in a burst are often clustered high — a fixed 0.05
    /// margin then marks everything. Instead we mark the top scorer plus only
    /// those photos that are near it *relative to the group's own spread*, and
    /// cap the count so a group never lights up entirely.
    ///
    /// - `tieEpsilon`: absolute score difference treated as a genuine tie even
    ///   when the group is tightly clustered.
    /// - `spreadFraction`: fraction of the group's (max−min) range within which
    ///   a photo still counts as "near the top".
    ///
    /// The cap on marks scales with group size: a third of the candidates,
    /// rounded up — so a 2–3-photo group marks ≤1, a 4–6-photo group ≤2, a
    /// 7–9-photo group ≤3.
    static func bestIDs(
        from result: AestheticsResult,
        tieEpsilon: Float = 0.02,
        spreadFraction: Float = 0.25
    ) -> Set<String> {
        let candidates = result.scores.filter { !result.utilityIDs.contains($0.key) }
        guard candidates.count > 1,
              let top = candidates.values.max(),
              let low = candidates.values.min() else {
            // A single non-utility photo is trivially "the best" — no point in
            // marking it against nothing to compare.
            return []
        }

        // Threshold scales with the group's spread, but never tighter than the
        // absolute tie epsilon (handles clustered high scores).
        let range = max(0, top - low)
        let threshold = max(tieEpsilon, range * spreadFraction)

        // Cap scales with group size: a third of candidates, rounded up.
        let maxMarks = (candidates.count + 2) / 3

        // Rank descending, then take those within the threshold of the top,
        // limited by the cap. Deterministic id tie-break.
        let ranked = candidates.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        var marked: Set<String> = []
        for (id, value) in ranked {
            guard marked.count < maxMarks else { break }
            if top - value <= threshold { marked.insert(id) }
        }
        return marked
    }
}
