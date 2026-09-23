import SwiftUI

/// A fixed, non-scrollable, horizontally-centered row of a photo and its
/// nearest temporal neighbors — two captured before, the photo itself, then two
/// after, by capture time — shown beneath the large image in the Low-aesthetic
/// detail view. It lets the user glance at whether a better "nearby shot"
/// exists next to the flagged photo without leaving the screen.
///
/// The strip is informational only: neighbors are NOT part of the selection.
/// Press-and-hold any thumbnail to peek a large, screen-centered preview that
/// blurs the content behind it; it disappears the instant the finger lifts.
struct NeighborStrip: View {
    /// The identifier whose neighbors to show (rendered highlighted in the
    /// middle of the row). The strip reloads when it changes.
    let identifier: String
    /// Reports the id currently being peeked (press-and-hold), or nil on release,
    /// so the host can present a full-screen centered preview above everything.
    let onPeek: (String?) -> Void

    @State private var before: [String] = []
    @State private var after: [String] = []
    @State private var loadedFor: String?

    private let thumbSize: CGFloat = 58

    var body: some View {
        VStack(spacing: 4) {
            Text("Nearby by time")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(before, id: \.self) { cell($0, isTarget: false) }
                cell(identifier, isTarget: true)
                ForEach(after, id: \.self) { cell($0, isTarget: false) }
            }
        }
        .frame(maxWidth: .infinity)               // center the whole row
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: identifier) { load() }
    }

    private func cell(_ id: String, isTarget: Bool) -> some View {
        PhotoThumbnail(identifier: id, size: thumbSize, fill: true, cornerRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    // Highlight the reviewed photo so its place in the timeline
                    // is obvious; neighbors get a faint hairline.
                    .stroke(isTarget ? Color.accentColor : .white.opacity(0.15),
                            lineWidth: isTarget ? 2.5 : 0.5)
            )
            // Touch-down shows the peek; lift (or cancel) hides it. A 0-distance
            // drag is the most reliable "hold to show, release to hide" surface.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPeek(id) }
                    .onEnded { _ in onPeek(nil) }
            )
            .accessibilityLabel(isTarget
                ? "The photo under review. Press and hold to preview."
                : "Nearby photo. Press and hold to preview.")
    }

    private func load() {
        guard loadedFor != identifier else { return }
        let neighbors = PhotoNeighbors.around(identifier, count: 2)
        before = neighbors.before
        after = neighbors.after
        loadedFor = identifier
    }
}
