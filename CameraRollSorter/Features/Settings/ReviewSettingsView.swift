import SwiftUI

struct ReviewSettingsView: View {
    @AppStorage("review.distanceThreshold") private var threshold = 0.4
    @AppStorage("review.geoGateEnabled") private var geoGateEnabled = true
    @AppStorage("review.geoGateKilometers") private var geoGateKilometers = 1.0
    @AppStorage("review.initialGroupTarget") private var initialGroupTarget = 500
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Similarity threshold") {
                    LabeledContent("Maximum Vision distance", value: threshold.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $threshold, in: 0...2, step: 0.05)
                        .accessibilityLabel("Maximum Vision distance")
                        .accessibilityValue(threshold.formatted(.number.precision(.fractionLength(2))))
                    Text("Default 0.40. Lower is stricter. Pairs at or below this distance join a group. Changes regroup existing scores when you close settings.")
                        .foregroundStyle(.secondary)
                }
                Section("Initial scan") {
                    LabeledContent("Groups before pausing", value: "\(initialGroupTarget)")
                    Slider(
                        value: Binding(
                            get: { Double(initialGroupTarget) },
                            set: { initialGroupTarget = Int($0) }
                        ),
                        in: 100...2000, step: 100
                    )
                    .accessibilityLabel("Groups to find before pausing the initial scan")
                    .accessibilityValue("\(initialGroupTarget)")
                    Text("The scan pauses once this many similar-photo groups are found, so results appear quickly. Scrolling to the end scans more. Default 500. Changes take effect on the next scan.")
                        .foregroundStyle(.secondary)
                }
                Section("Location shortcut") {
                    Toggle("Skip far-apart photos", isOn: $geoGateEnabled)
                    if geoGateEnabled {
                        LabeledContent("Maximum distance", value: "\(geoGateKilometers.formatted(.number.precision(.fractionLength(1)))) km")
                        Slider(value: $geoGateKilometers, in: 0.1...50, step: 0.1)
                            .accessibilityLabel("Maximum distance in kilometers")
                            .accessibilityValue("\(geoGateKilometers.formatted(.number.precision(.fractionLength(1)))) kilometers")
                    }
                    Text("When on, photo pairs that both have location data and are farther apart than this are skipped without a visual comparison, speeding up the scan. Pairs missing location on either side are always compared. Changes take effect on the next scan (pull to refresh).")
                        .foregroundStyle(.secondary)
                }
                Section("Scan scope") {
                    Text("All accessible photos in your camera roll, regardless of capture date.")
                    Text("With limited access, only the photos you allow can be scanned.")
                        .foregroundStyle(.secondary)
                }
                Section("Comparison candidates") {
                    LabeledContent("Maximum time apart", value: "Less than 24 hours")
                    LabeledContent("Neighbors per photo", value: "Up to 5")
                    Text("Each photo is compared with its closest neighbors by capture time, before or after it. Matching links join into larger groups, which can contain more than five photos. A chain of matches may connect endpoints that are not directly similar.")
                        .foregroundStyle(.secondary)
                }
                Section("Photo library") {
                    Text("Scores use Vision and local previews without automatic iCloud downloads. The chooser can move rejected photos to Recently Deleted after you confirm.")
                }
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
