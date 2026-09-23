import CoreGraphics
import Foundation

// Standalone check harness for the blurry-photo-detection feature, matching the
// project's existing `Tests/main.swift` style (plain `swiftc` + assertions, no
// XCTest target). It exercises the PURE surfaces the design extracted so they
// can be verified without PhotoKit / Metal / SwiftUI:
//
//   • BlurSensitivity        (variance cutoff + threshold decision + persistence)
//   • PhotoSelectionLogic     (toggle, select-all, paint range, paint/scroll axis)
//
// The PhotoKit/Metal/UI-bound properties from design.md (Property 2 Laplacian
// metamorphic, 3 unloadable-image exclusion, 4 scan-scope predicate on PHAsset
// enums, 5 candidate ordering, 12 post-delete transition, 13 home-row detail)
// require the app target's PhotoKit/Metal/SwiftUI types and cannot run in this
// standalone harness; they are covered by on-device/integration testing instead.
//
// NOTE: Unlike `Tests/main.swift`, this file is compiled under a non-`main.swift`
// name, so its executable checks live in an `@main` entry point (Swift only
// permits top-level statements in a file literally named `main.swift`). The
// assertions themselves are unchanged.
//
// Compile & run (see README "Blurry photo checks"):
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     CameraRollSorter/Services/BlurSensitivity.swift \
//     CameraRollSorter/Features/Shared/PhotoSelectionLogic.swift \
//     Tests/BlurryPhotoChecks.swift \
//     -o /tmp/CameraRollSorter-blurry-checks
//   /tmp/CameraRollSorter-blurry-checks

// MARK: - Harness

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}

/// Minimum randomized iterations per property test (design.md requirement).
private let iterations = 200

/// Deterministic PRNG so failures reproduce. xorshift64*, seeded fixed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

private var rng = SeededGenerator(seed: 0xB1FF_0000_C0FFEE)

private func randomIDs(_ count: Int) -> [String] {
    (0..<count).map { "id-\($0)" }
}

@main
enum BlurryPhotoChecks {
    static func main() {
        // MARK: - Property 1: Blur decision follows the variance threshold
        // Validates: Requirements 2.2, 2.3

        for _ in 0..<iterations {
            let variance = Double.random(in: -5...80, using: &rng)
            let cutoff = Double.random(in: 0...60, using: &rng)
            let expected = variance < cutoff
            check(BlurSensitivity.isBlurry(variance: variance, cutoff: cutoff) == expected,
                  "Property 1: isBlurry(v,c) == (v < c) for v=\(variance), c=\(cutoff)")
        }
        // Boundary: variance exactly equal to cutoff is NOT blurry (strict <).
        check(BlurSensitivity.isBlurry(variance: 18.0, cutoff: 18.0) == false,
              "Property 1: variance == cutoff is not blurry (strict <)")

        // MARK: - Property 10: The blur decision is monotonic in the cutoff
        // Validates: Requirements 7.3, 7.5

        // Pointwise monotonicity: for a fixed variance, a higher cutoff never
        // un-flags a photo that a lower cutoff flagged (a higher cutoff flags a
        // superset).
        for _ in 0..<iterations {
            let variance = Double.random(in: -5...80, using: &rng)
            var c1 = Double.random(in: 0...60, using: &rng)
            var c2 = Double.random(in: 0...60, using: &rng)
            if c1 > c2 { swap(&c1, &c2) } // ensure c1 <= c2
            let blurryAtLow = BlurSensitivity.isBlurry(variance: variance, cutoff: c1)
            let blurryAtHigh = BlurSensitivity.isBlurry(variance: variance, cutoff: c2)
            check(!blurryAtLow || blurryAtHigh,
                  "Property 10: isBlurry(v,c1) implies isBlurry(v,c2) for v=\(variance), c1=\(c1), c2=\(c2)")
        }

        // Set monotonicity: over a fixed random set of variances, the blurry set
        // at a lower cutoff is a subset of the blurry set at a higher cutoff.
        for _ in 0..<iterations {
            let variances = (0..<Int.random(in: 1...40, using: &rng)).map { _ in Double.random(in: -5...80, using: &rng) }
            var c1 = Double.random(in: 0...60, using: &rng)
            var c2 = Double.random(in: 0...60, using: &rng)
            if c1 > c2 { swap(&c1, &c2) } // ensure c1 <= c2
            func blurrySet(_ cutoff: Double) -> Set<Int> {
                Set(variances.indices.filter { BlurSensitivity.isBlurry(variance: variances[$0], cutoff: cutoff) })
            }
            check(blurrySet(c1).isSubset(of: blurrySet(c2)),
                  "Property 10: blurry set at cutoff \(c1) subset of blurry set at cutoff \(c2)")
        }

        // currentCutoff clamps into [minCutoff, maxCutoff] and defaults when
        // unset / <= 0.
        for _ in 0..<iterations {
            let raw = Double.random(in: -20...120, using: &rng)
            UserDefaults.standard.set(raw, forKey: BlurSensitivity.storageKey)
            let current = BlurSensitivity.currentCutoff
            if raw <= 0 {
                check(current == BlurSensitivity.defaultCutoff,
                      "Property 10: stored \(raw) <= 0 yields defaultCutoff")
            } else {
                let expected = min(max(raw, BlurSensitivity.minCutoff), BlurSensitivity.maxCutoff)
                check(current == expected,
                      "Property 10: stored \(raw) clamps into [minCutoff, maxCutoff] -> \(expected)")
            }
            check(current >= BlurSensitivity.minCutoff && current <= BlurSensitivity.maxCutoff,
                  "Property 10: currentCutoff \(current) within [minCutoff, maxCutoff]")
        }
        UserDefaults.standard.removeObject(forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.defaultCutoff,
              "Property 10: missing stored value defaults to defaultCutoff")

        // MARK: - Property 11: Cutoff persistence round-trips
        // Validates: Requirements 7.2

        let epsilon = 1e-9
        for _ in 0..<iterations {
            let cutoff = Double.random(in: BlurSensitivity.minCutoff...BlurSensitivity.maxCutoff, using: &rng)
            UserDefaults.standard.set(cutoff, forKey: BlurSensitivity.storageKey)
            check(abs(BlurSensitivity.currentCutoff - cutoff) < epsilon,
                  "Property 11: writing cutoff \(cutoff) then reading currentCutoff round-trips")
        }
        // A stored value <= 0 yields the default.
        UserDefaults.standard.set(0.0, forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.defaultCutoff,
              "Property 11: stored 0 yields defaultCutoff")
        UserDefaults.standard.set(-12.5, forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.defaultCutoff,
              "Property 11: stored negative yields defaultCutoff")
        // A missing value yields the default.
        UserDefaults.standard.removeObject(forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.defaultCutoff,
              "Property 11: missing stored value yields defaultCutoff")
        // An out-of-range stored value is clamped.
        UserDefaults.standard.set(BlurSensitivity.maxCutoff + 25, forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.maxCutoff,
              "Property 11: above-range stored value clamps to maxCutoff")
        UserDefaults.standard.set(BlurSensitivity.minCutoff / 2, forKey: BlurSensitivity.storageKey)
        check(BlurSensitivity.currentCutoff == BlurSensitivity.minCutoff,
              "Property 11: positive below-range stored value clamps to minCutoff")
        UserDefaults.standard.removeObject(forKey: BlurSensitivity.storageKey)

        // MARK: - Property 6: Toggling selection twice is the identity
        // Validates: Requirements 6.1, 6.2

        for _ in 0..<iterations {
            let ids = randomIDs(Int.random(in: 1...30, using: &rng))
            let base = Set(ids.filter { _ in Bool.random(using: &rng) })
            let target = ids.randomElement(using: &rng)!

            let once = PhotoSelectionLogic.toggle(target, in: base)
            let twice = PhotoSelectionLogic.toggle(target, in: once)
            check(twice == base, "Property 6: double toggle is identity for \(target)")
            check(once.contains(target) == !base.contains(target),
                  "Property 6: single toggle flips target membership")
            let others = ids.filter { $0 != target }
            check(others.allSatisfy { once.contains($0) == base.contains($0) },
                  "Property 6: single toggle leaves other members unchanged")
        }

        // MARK: - Property 9: Select All selects every detected photo
        // Validates: Requirements 6.7

        for _ in 0..<iterations {
            let ids = randomIDs(Int.random(in: 0...40, using: &rng))
            let prior = Set(ids.filter { _ in Bool.random(using: &rng) })
            let selected = PhotoSelectionLogic.selectAll(ids: ids)
            check(selected == Set(ids), "Property 9: Select All == set of all ids")
            check(prior.isSubset(of: selected), "Property 9: Select All is a superset of any prior selection")
        }

        // MARK: - Property 7: A paint drag sets exactly the swept range
        // Validates: Requirements 6.3, 6.6

        for _ in 0..<iterations {
            let ids = randomIDs(Int.random(in: 1...40, using: &rng))
            let base = Set(ids.filter { _ in Bool.random(using: &rng) })
            let anchor = Int.random(in: 0..<ids.count, using: &rng)
            let target = Int.random(in: 0..<ids.count, using: &rng)
            let selects = PhotoSelectionLogic.dragSelects(anchorIndex: anchor, ids: ids, base: base)
            let result = PhotoSelectionLogic.paintRange(
                anchorIndex: anchor, targetIndex: target, base: base, ids: ids, selects: selects
            )

            let lo = min(anchor, target), hi = max(anchor, target)
            let inRange = Set((lo...hi).map { ids[$0] })
            check(inRange.allSatisfy { result.contains($0) == selects },
                  "Property 7: swept range set to \(selects) for [\(lo),\(hi)]")
            let outside = Set(ids).subtracting(inRange)
            check(outside.allSatisfy { result.contains($0) == base.contains($0) },
                  "Property 7: outside swept range unchanged from base")
            check(selects == !base.contains(ids[anchor]),
                  "Property 7: anchor cell decides select-vs-deselect")
        }
        do {
            let ids = randomIDs(5)
            let base: Set<String> = ["id-1", "id-3"]
            check(PhotoSelectionLogic.paintRange(anchorIndex: 0, targetIndex: 99, base: base, ids: ids, selects: true) == base,
                  "Property 7: out-of-range target yields base unchanged")
            check(PhotoSelectionLogic.paintRange(anchorIndex: -1, targetIndex: 2, base: base, ids: ids, selects: true) == base,
                  "Property 7: out-of-range anchor yields base unchanged")
        }

        // MARK: - Property 8: Paint/scroll decision follows the dominant drag axis
        // Validates: Requirements 6.4

        for _ in 0..<iterations {
            let dx = CGFloat.random(in: -200...200, using: &rng)
            let dy = CGFloat.random(in: -200...200, using: &rng)
            let expected = abs(dx) >= abs(dy)
            check(PhotoSelectionLogic.isPaint(dx: dx, dy: dy) == expected,
                  "Property 8: isPaint == (|dx| >= |dy|) for dx=\(dx), dy=\(dy)")
        }
        check(PhotoSelectionLogic.isPaint(dx: 10, dy: 10) == true, "Property 8: exact diagonal counts as paint")
        check(PhotoSelectionLogic.isPaint(dx: 0, dy: 5) == false, "Property 8: pure vertical is a scroll")

        // MARK: - Auto-scroll mapping sanity (supports Requirement 6.6 auto-scroll)

        let viewport = CGRect(x: 0, y: 100, width: 300, height: 600)
        let margin: CGFloat = 70
        do {
            let mid = PhotoSelectionLogic.autoScroll(for: CGPoint(x: 150, y: 400), viewport: viewport, edgeMargin: margin)
            check(mid.direction == 0 && mid.intensity == 0, "AutoScroll: center yields no scroll")
            let top = PhotoSelectionLogic.autoScroll(for: CGPoint(x: 150, y: 110), viewport: viewport, edgeMargin: margin)
            check(top.direction == -1 && top.intensity > 0, "AutoScroll: near top scrolls up")
            let atTop = PhotoSelectionLogic.autoScroll(for: CGPoint(x: 150, y: 100), viewport: viewport, edgeMargin: margin)
            check(atTop.direction == -1 && atTop.intensity == 1, "AutoScroll: at top edge intensity clamps to 1")
            let bottom = PhotoSelectionLogic.autoScroll(for: CGPoint(x: 150, y: 690), viewport: viewport, edgeMargin: margin)
            check(bottom.direction == 1 && bottom.intensity > 0, "AutoScroll: near bottom scrolls down")
            let degenerate = PhotoSelectionLogic.autoScroll(for: CGPoint(x: 0, y: 0), viewport: .zero, edgeMargin: margin)
            check(degenerate.direction == 0 && degenerate.intensity == 0, "AutoScroll: zero viewport disables scroll")
        }
        check(PhotoSelectionLogic.autoScrollStep(intensity: 0, maxStep: 8) == 1, "AutoScrollStep: intensity 0 -> 1 row")
        check(PhotoSelectionLogic.autoScrollStep(intensity: 1, maxStep: 8) == 8, "AutoScrollStep: intensity 1 -> maxStep rows")
        for _ in 0..<iterations {
            let a = Double.random(in: 0...1, using: &rng)
            let b = Double.random(in: 0...1, using: &rng)
            let lo = min(a, b), hi = max(a, b)
            check(PhotoSelectionLogic.autoScrollStep(intensity: lo, maxStep: 8) <= PhotoSelectionLogic.autoScrollStep(intensity: hi, maxStep: 8),
                  "AutoScrollStep: monotonic non-decreasing in intensity")
        }

        print("\nAll blurry-photo pure-logic checks passed (\(iterations) iterations per property).")
    }
}
