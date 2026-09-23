import SwiftUI

struct ReviewSettingsView: View {
    @AppStorage("review.distanceThreshold") private var threshold = 0.4
    @AppStorage("review.geoGateEnabled") private var geoGateEnabled = true
    @AppStorage("review.geoGateKilometers") private var geoGateKilometers = 1.0
    @AppStorage("review.initialGroupTarget") private var initialGroupTarget = 200
    @AppStorage("review.previewTarget") private var previewTarget = 50
    @AppStorage(BlurSensitivity.storageKey) private var blurCutoff = BlurSensitivity.defaultCutoff
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Global — applies to every cleanup feature.
                Section {
                    // Initial scan (home-screen preview cap).
                    LabeledContent("Initial scan", value: "\(previewTarget)")
                    Slider(
                        value: Binding(
                            get: { Double(previewTarget) },
                            set: { previewTarget = Int($0) }
                        ),
                        in: 10...200, step: 10
                    )
                    .accessibilityLabel("Results to find per feature on the home screen before pausing")
                    .accessibilityValue("\(previewTarget)")
                    Text("On the home screen, each feature scans only up to this many results before pausing, so opening the app doesn't run all three scans to completion at once. Opening a feature's list scans the rest up to the buffer above. Default 50.")
                        .foregroundStyle(.secondary)

                    // Scan buffer (full, kept while a list is open).
                    LabeledContent("Scan buffer", value: "\(initialGroupTarget)")
                    Slider(
                        value: Binding(
                            get: { Double(initialGroupTarget) },
                            set: { initialGroupTarget = Int($0) }
                        ),
                        in: 100...2000, step: 100
                    )
                    .accessibilityLabel("Results to keep scanned ahead of your position before pausing")
                    .accessibilityValue("\(initialGroupTarget)")
                    Text("Each scan pauses once it has this many results below your current position, so the app stays responsive; scrolling loads more. Applies to Similar photos (groups), Live → Still, and Low-aesthetic (photos). Default 200.")
                        .foregroundStyle(.secondary)

                    Text("Scan direction and start date are set at the top of each list, so you can adjust them while reviewing.")
                    Text("With limited access, only the photos you allow can be scanned. Scores use Vision and local previews without automatic iCloud downloads.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("General")
                }

                // MARK: Similar photos.
                Section {
                    LabeledContent("Maximum Vision distance", value: threshold.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $threshold, in: 0...2, step: 0.05)
                        .accessibilityLabel("Maximum Vision distance")
                        .accessibilityValue(threshold.formatted(.number.precision(.fractionLength(2))))
                    Text("Default 0.40. Lower is stricter. Pairs at or below this distance join a group. Changes regroup existing scores when you close settings.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Similar photos")
                }
                Section {
                    Toggle("Skip far-apart photos", isOn: $geoGateEnabled)
                    if geoGateEnabled {
                        LabeledContent("Maximum distance", value: "\(geoGateKilometers.formatted(.number.precision(.fractionLength(1)))) km")
                        Slider(value: $geoGateKilometers, in: 0.1...50, step: 0.1)
                            .accessibilityLabel("Maximum distance in kilometers")
                            .accessibilityValue("\(geoGateKilometers.formatted(.number.precision(.fractionLength(1)))) kilometers")
                    }
                    Text("When on, photo pairs that both have location data and are farther apart than this are skipped without a visual comparison, speeding up the scan. Pairs missing location on either side are always compared. Changes take effect on the next scan (pull to refresh).")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Similar photos · Location shortcut")
                }
                Section {
                    LabeledContent("Maximum time apart", value: "Less than 24 hours")
                    LabeledContent("Neighbors per photo", value: "Up to 5")
                    Text("Each photo is compared with its closest neighbors by capture time, before or after it. Matching links join into larger groups, which can contain more than five photos. A chain of matches may connect endpoints that are not directly similar.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Similar photos · Comparison candidates")
                }

                // MARK: Low-aesthetic (Blurry).
                Section {
                    LabeledContent("Sensitivity", value: blurCutoff.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $blurCutoff, in: BlurSensitivity.minCutoff...BlurSensitivity.maxCutoff, step: 0.05)
                        .accessibilityLabel("Low-aesthetic sensitivity")
                        .accessibilityValue(blurCutoff.formatted(.number.precision(.fractionLength(2))))
                    Text("Flags non-utility photos whose Vision aesthetics score falls below this cutoff. Higher is more sensitive and flags more photos. Lowering re-checks your current results instantly; raising re-scans next time you open Low-aesthetic. Scoring needs a physical device.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Low-aesthetic")
                }

                // Live → Still has no settings of its own (its scan window is
                // controlled in-list), so it needs no section here.
            }
            .navigationTitle("Review settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview { ReviewSettingsView() }
