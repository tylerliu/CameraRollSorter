import Accelerate
import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import UIKit

/// Computes a blur score (variance of the Laplacian) for a photo, entirely
/// on-device. Lower variance = more blur. The score is compared against a
/// sensitivity-derived cutoff by the caller (`BlurSensitivity.isBlurry`).
///
/// Kept as a stateless `enum` — like `AestheticsScorer` is kept separate from
/// `SimilarityAnalyzer` — so scoring can run on a background actor without
/// serializing behind other work, and so a future aesthetics blend has a
/// single place to live. The (expensive) Metal device/queue/pipeline are the
/// only shared state; they are created lazily once and cached behind a lock so
/// concurrent calls from a background actor are safe.
///
/// The scoring pipeline:
/// 1. Load a downscaled, local-only still via `PhotoImageLoading.synchronousImage`.
///    For a Live Photo this returns the still frame (Requirement 3.4).
/// 2. Convert to single-channel grayscale (luminance) in `[0, 255]`.
/// 3. Apply a 3×3 Laplacian kernel: `[0,1,0],[1,-4,1],[0,1,0]`.
/// 4. Return the variance of the Laplacian output: `mean(x²) − mean(x)²`.
///
/// The public API returns a plain `Double` regardless of whether the GPU or
/// CPU path ran, so the model is agnostic to which executed.
///
/// - Note on scale: the GPU path (device) rectifies the Laplacian response into
///   `[0, 255]` while the CPU fallback (Simulator) convolves in signed floats.
///   The two paths therefore produce variances on slightly different absolute
///   scales; the GPU/device path is the reference against which the
///   `BlurSensitivity.varianceCutoff` constants are tuned. Both paths preserve
///   the ordering the metamorphic property depends on (sharper ≥ blurrier).
nonisolated enum BlurClassifier {
    /// Variance of the Laplacian of a grayscale, downscaled still.
    /// Returns `nil` when the image can't be loaded locally (Requirement 2.6).
    static func laplacianVariance(for identifier: String, targetSize: CGFloat = 256) -> Double? {
        autoreleasepool {
            guard let cgImage = PhotoImageLoading.synchronousImage(for: identifier, targetSize: targetSize)?.cgImage else {
                return nil
            }
            guard let gray = GrayscaleBuffer(cgImage: cgImage) else { return nil }

            // Prefer the GPU path; fall back to the CPU (vImage) path when Metal
            // is unavailable (Simulator, older hardware) or the GPU run fails.
            if let variance = MetalContext.shared?.laplacianVariance(of: gray) {
                return variance
            }
            return gray.laplacianVarianceCPU()
        }
    }

    /// Convenience: load + score + compare. `nil` when the image is unavailable
    /// (Requirement 2.6); otherwise `variance < cutoff` (Requirements 2.2, 2.3).
    static func isBlurry(_ identifier: String, cutoff: Double, targetSize: CGFloat = 256) -> Bool? {
        guard let variance = laplacianVariance(for: identifier, targetSize: targetSize) else { return nil }
        return BlurSensitivity.isBlurry(variance: variance, cutoff: cutoff)
    }
}

// MARK: - Grayscale buffer

/// A tightly-packed, single-channel 8-bit luminance buffer decoded from a
/// `CGImage`. Owns its pixel storage so both the GPU and CPU paths can read it.
private nonisolated struct GrayscaleBuffer {
    let width: Int
    let height: Int
    /// Row-major luminance bytes, `width * height` in length (no row padding).
    let pixels: [UInt8]

    /// Renders `cgImage` into a padding-free 8-bit gray context. Returns `nil`
    /// for degenerate (zero-area) images or if the context can't be created.
    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let success: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }

        self.width = width
        self.height = height
        self.pixels = buffer
    }

    /// CPU fallback: 3×3 Laplacian convolution over a `Float` planar buffer via
    /// vImage (which preserves the negative responses a Laplacian produces —
    /// unlike `Planar8`, which would clamp them to zero), then the variance of
    /// the response. Used when Metal is unavailable.
    func laplacianVarianceCPU() -> Double {
        let count = width * height

        // Promote the 8-bit luminance to Float so the convolution keeps signed
        // (negative) Laplacian responses.
        var source = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: pixels, to: &source)

        var destination = [Float](repeating: 0, count: count)

        // Row-major 3×3 Laplacian: [0,1,0],[1,-4,1],[0,1,0].
        let kernel: [Float] = [
            0, 1, 0,
            1, -4, 1,
            0, 1, 0,
        ]

        source.withUnsafeMutableBufferPointer { srcPtr in
            destination.withUnsafeMutableBufferPointer { dstPtr in
                var srcBuffer = vImage_Buffer(
                    data: srcPtr.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride
                )
                var dstBuffer = vImage_Buffer(
                    data: dstPtr.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride
                )
                kernel.withUnsafeBufferPointer { kPtr in
                    _ = vImageConvolve_PlanarF(
                        &srcBuffer,
                        &dstBuffer,
                        nil,
                        0,
                        0,
                        kPtr.baseAddress!,
                        3,
                        3,
                        0,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }

        return Self.variance(of: destination)
    }

    /// Population variance `mean(x²) − mean(x)²` of a Float buffer, guarding
    /// against catastrophic cancellation by clamping tiny negatives to zero.
    static func variance(of values: [Float]) -> Double {
        let count = values.count
        guard count > 0 else { return 0 }
        var mean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(count))
        vDSP_measqv(values, 1, &meanSquare, vDSP_Length(count))
        let variance = Double(meanSquare) - Double(mean) * Double(mean)
        return max(0, variance)
    }
}

// MARK: - Metal context (lazy, cached, thread-safe)

/// Lazily-created, process-wide Metal state for the GPU Laplacian path. The
/// device, command queue, and MPS kernel are expensive to build, so they are
/// created once. `BlurClassifier` is stateless but may be called concurrently
/// from a background actor, so the shared instance is guarded by a lock.
private nonisolated final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let laplacian: MPSImageLaplacian

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.laplacian = MPSImageLaplacian(device: device)
    }

    /// The shared context, or `nil` on platforms without a Metal device (the
    /// Simulator). Resolved exactly once; subsequent calls return the cached
    /// result (including a cached `nil`).
    static var shared: MetalContext? {
        lock.lock()
        defer { lock.unlock() }
        if let resolved = cached {
            return resolved.value
        }
        let context = MetalContext()
        cached = Box(context)
        return context
    }

    private static let lock = NSLock()
    /// `nil` = not yet resolved; `Box(nil)` = resolved to "no Metal device".
    nonisolated(unsafe) private static var cached: Box?

    private struct Box {
        let value: MetalContext?
        init(_ value: MetalContext?) { self.value = value }
    }

    /// Runs `MPSImageLaplacian` on the grayscale buffer, reads the response
    /// back, and reduces to a variance on the CPU. Returns `nil` if any Metal
    /// step fails so the caller can fall back to the CPU path.
    func laplacianVariance(of gray: GrayscaleBuffer) -> Double? {
        let width = gray.width
        let height = gray.height
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let sourceTexture = device.makeTexture(descriptor: descriptor),
              let destinationTexture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        gray.pixels.withUnsafeBytes { raw in
            sourceTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width
            )
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        laplacian.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: destinationTexture)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        // Read the Laplacian response back. `MPSImageLaplacian` writes an
        // unsigned (rectified) magnitude into the r8Unorm texture; taking the
        // variance of that magnitude is the standard Laplacian-variance blur
        // metric (higher = sharper).
        var response = [UInt8](repeating: 0, count: width * height)
        response.withUnsafeMutableBytes { raw in
            destinationTexture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width,
                from: region,
                mipmapLevel: 0
            )
        }

        var floats = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: response, to: &floats)
        return GrayscaleBuffer.variance(of: floats)
    }
}
