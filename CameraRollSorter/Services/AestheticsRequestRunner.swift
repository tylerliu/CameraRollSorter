import CoreGraphics
import Vision

/// Raw wrapper around Vision's image-aesthetics request. Isolated here so the
/// scoring actor stays focused on orchestration and caching.
///
/// Note: `VNCalculateImageAestheticsScoresRequest` only runs on a physical
/// device — the simulator throws. Callers must treat a thrown error as
/// "no score available" and degrade silently rather than fabricating a value.
nonisolated enum AestheticsRequestRunner {
    struct Score: Sendable {
        let overall: Float
        let isUtility: Bool
    }

    @available(iOS 18.0, *)
    static func score(for image: CGImage) throws -> Score {
        let request = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else {
            throw CocoaError(.coderInvalidValue)
        }
        return Score(overall: observation.overallScore, isUtility: observation.isUtility)
    }
}
