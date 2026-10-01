import SwiftUI

/// Global scan-buffer setting shared by ALL cleanup features. Each incremental
/// scan pauses once it has this many results (groups / convertible photos /
/// low-aesthetic photos) BELOW the viewer's current position, and resumes as
/// the list scrolls. Backed by the single `review.initialGroupTarget` key so
/// one slider in settings governs Similar photos, Live → Still, and
/// Low-aesthetic alike.
nonisolated enum ScanBuffer {
    // Full buffer, kept while a feature's list is actively being viewed.
    static let storageKey = "review.initialGroupTarget"
    static let defaultTarget = 200
    // Preview buffer, used while no list is open (the home screen). Keeps each
    // scan from burning through its full buffer on all three features at launch;
    // opening a list lifts the cap to the full `target`. Both are settable.
    static let previewStorageKey = "review.previewTarget"
    static let defaultPreviewTarget = 50

    /// Full results to keep buffered ahead of the current position before
    /// pausing, once the feature's list is actively being viewed.
    static var target: Int {
        let value = UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultTarget
        return max(1, value)
    }

    /// Results to find on the home screen (per feature) before pausing, when no
    /// list is open yet.
    static var previewTarget: Int {
        let value = UserDefaults.standard.object(forKey: previewStorageKey) as? Int ?? defaultPreviewTarget
        return max(1, value)
    }

    /// Effective buffer for the current viewing state: the small `previewTarget`
    /// until the list is open, then the full `target`.
    static func effectiveTarget(listActive: Bool) -> Int {
        listActive ? target : min(target, previewTarget)
    }
}

/// Pinned scan-scope controls shared (as UI only) by the Similar photos list
/// and the Live → Still grid: scan direction (New→Old / Old→New) and an
/// optional "from date" window. State is NOT shared between the two screens —
/// each owns its own direction/start values and passes them in as bindings, so
/// changing one screen's window never affects the other. Any change calls
/// `onChange`, which each screen wires to its model's reconciliation.
struct ScanControlsHeader: View {
    @Binding var direction: String          // "older" (New→Old) or "newer" (Old→New)
    @Binding var startEnabled: Bool
    @Binding var startInterval: Double      // seconds since 1970; 0 = unset
    // Whether the wheel picker is expanded. Collapses when not picking so it
    // doesn't take up vertical space (the date label and the done button both
    // toggle it).
    @State private var wheelExpanded = false
    /// Capture-date span of the owning list, used to bound and seed the picker.
    let dateRange: ClosedRange<Date>?
    /// Called after any live control change so the owner can reconcile its scan.
    /// Fires on every wheel tick, toggle, and order change — the visible list
    /// updates immediately from this.
    let onChange: () -> Void
    /// Called when the user SETTLES the window: closes the roller, changes the
    /// order, or toggles the date window off. The owner uses this to schedule
    /// its debounced (2s) memory cleanup. Optional — screens with no cache
    /// (Live → Still, Blurry) pass a no-op.
    var onSettle: () -> Void = {}
    /// Called when the roller OPENS, so the owner cancels any pending cleanup
    /// while the user is still picking. Optional — see `onSettle`.
    var onCancelCleanup: () -> Void = {}

    /// Called after EVERY control change (order, toggle, wheel tick, open/close).
    /// Always reconciles the visible scan via `onChange`, then applies the
    /// cleanup rule uniformly:
    ///   • roller OPEN  → cancel any pending cleanup, and never schedule one
    ///     (the user is still deciding).
    ///   • roller CLOSED → schedule/reset the debounced (2s) cleanup, so any
    ///     change postpones it and a burst collapses to one prune 2s after the
    ///     last change.
    private func notifyChange() {
        onChange()
        if wheelExpanded { onCancelCleanup() } else { onSettle() }
    }

    /// Expand or collapse the wheel with animation, then reconcile. Because
    /// `notifyChange` reads the NEW `wheelExpanded`, opening cancels cleanup and
    /// closing schedules it.
    private func setWheel(expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { wheelExpanded = expanded }
        notifyChange()
    }

    /// Wheel binding. Reads/writes `startInterval` directly and reconciles on
    /// every change, so results update live as the rollers move. Snaps the
    /// boundary to the whole selected day in the travel direction. Since the
    /// wheel is only visible while expanded, each tick resets-then-cancels the
    /// cleanup — i.e. no prune is ever scheduled while picking.
    private var startDate: Binding<Date> {
        Binding(
            get: {
                let stored = startInterval == 0 ? defaultStart() : Date(timeIntervalSince1970: startInterval)
                if let dateRange {
                    return min(max(stored, dateRange.lowerBound), dateRange.upperBound)
                }
                return stored
            },
            set: { newValue in
                let cal = Calendar.current
                let snapped = direction == "older"
                    ? (cal.date(bySettingHour: 23, minute: 59, second: 59, of: newValue) ?? newValue)
                    : cal.startOfDay(for: newValue)
                startInterval = snapped.timeIntervalSince1970
                notifyChange()
            }
        )
    }

    /// Default start when first enabling "from date". For New→Old (`older`) the
    /// newest photos are the interesting ones, so start at the span's upper
    /// bound ("newest from today"); for Old→New start at the lower bound. Using
    /// the extreme means today's photos aren't filtered out of the window.
    private func defaultStart() -> Date {
        guard let dateRange else { return Date() }
        return direction == "older" ? dateRange.upperBound : dateRange.lowerBound
    }

    var body: some View {
        VStack(spacing: 8) {
            // Tags name the destination ("older"/"newer"); labels name travel.
            Picker("Scan order", selection: $direction) {
                Text("Old→New").tag("newer")
                Text("New→Old").tag("older")
            }
            .pickerStyle(.segmented)
            .onChange(of: direction) { _, _ in
                // Re-seed the start to the new direction's sensible default and
                // re-apply, so flipping direction while enabled keeps a valid
                // window (e.g. "newest from today" vs "oldest from the start").
                if startEnabled { startInterval = defaultStart().timeIntervalSince1970 }
                // Reconcile + apply the cleanup rule (open → suppress, closed →
                // schedule/reset the 2s timer).
                notifyChange()
            }

            HStack {
                Toggle(direction == "older" ? "Newest from date" : "Oldest from date", isOn: $startEnabled)
                    .toggleStyle(.button)
                    .onChange(of: startEnabled) { _, isOn in
                        if isOn {
                            // Seed from the last-used date; only fall back to the
                            // default (today if no range) when nothing is stored,
                            // so re-enabling remembers where the user left off.
                            if startInterval == 0 {
                                startInterval = defaultStart().timeIntervalSince1970
                            }
                            // Opening the roller reconciles and cancels cleanup.
                            setWheel(expanded: true)
                        } else {
                            // Turning the window off closes the roller and
                            // settles (schedules the 2s cleanup).
                            setWheel(expanded: false)
                        }
                    }
                if startEnabled {
                    // Single bubble: the date, with a tick to its right while
                    // the wheel is open — so "done picking" reads as part of the
                    // same element, no second button. Tapping toggles the wheel
                    // (open ↔ close), firing the settle/cancel callbacks via
                    // `setWheel`.
                    Button {
                        setWheel(expanded: !wheelExpanded)
                    } label: {
                        HStack(spacing: 6) {
                            Text(startDate.wrappedValue, format: .dateTime.year().month().day())
                                .font(.subheadline)
                            if wheelExpanded {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(wheelExpanded ? "Done picking date" : "Change date")
                }
                Spacer()
            }
            // Wheel (year/month/day rollers) shown only while expanded, so it
            // doesn't take up space the rest of the time — like the old popover.
            // The wheel applies on every change, so results update live.
            if startEnabled && wheelExpanded {
                Group {
                    if let dateRange {
                        DatePicker("", selection: startDate, in: dateRange, displayedComponents: .date)
                    } else {
                        DatePicker("", selection: startDate, displayedComponents: .date)
                    }
                }
                .labelsHidden()
                .datePickerStyle(.wheel)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
