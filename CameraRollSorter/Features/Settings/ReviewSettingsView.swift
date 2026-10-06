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
            settingsForm
                #if os(macOS)
                .formStyle(.grouped)
                .contentMargins(.horizontal, 28, for: .scrollContent)
                .frame(width: 600, height: 680)
                #endif
                .navigationTitle("Review settings")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    private var settingsForm: some View {
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
                Text("Results per feature before pausing on the home screen. Opening a list uses the scan buffer below. Default 50.")
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
                Text("Results to scan ahead of your position; scrolling loads more. Counts groups for Similar photos and photos for other features. Default 200.")
                    .foregroundStyle(.secondary)

                Text("Set scan direction and start date at the top of each list.")
                Text("Only accessible, locally available photos are analyzed with Vision. No automatic iCloud downloads.")
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
                Text("Lower is stricter. Pairs within this distance join a group. Closing settings regroups saved scores. Default 0.40.")
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
                Text("Skip visual comparisons for pairs beyond this distance when both have locations. Pairs missing locations are still compared. Pull to refresh to apply changes.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Similar photos · Location shortcut")
            }
            Section {
                LabeledContent("Maximum time apart", value: "Less than 24 hours")
                LabeledContent("Neighbors per photo", value: "Up to 5")
                Text("Neighbors are chosen by capture time, before or after each photo. Linked matches can form groups larger than five, including photos that do not directly match.")
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
                Text("Flags non-utility photos below this Vision score. Higher flags more. Lowering updates current results; raising re-scans when you reopen Low-aesthetic. Requires a physical device.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Low-aesthetic")
            }

            // Live → Still has no settings of its own (its scan window is
            // controlled in-list), so it needs no section here.
        }
    }
}

#Preview { ReviewSettingsView() }
