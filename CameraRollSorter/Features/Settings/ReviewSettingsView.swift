import SwiftUI

struct ReviewSettingsView: View {
    @AppStorage("review.distanceThreshold") private var threshold = 0.4
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
