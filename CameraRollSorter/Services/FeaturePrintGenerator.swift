import CoreGraphics
import Vision

nonisolated enum FeaturePrintGenerator {
    static func observation(for image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw CocoaError(.coderInvalidValue)
        }
        return observation
    }
}
