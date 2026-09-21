import SwiftUI

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
    // doesn't take up vertical space (the date label button toggles it).
    @State private var wheelExpanded = false
    /// Capture-date span of the owning list, used to bound and seed the picker.
    let dateRange: ClosedRange<Date>?
    /// Called after any control change so the owner can reconcile its scan.
    let onChange: () -> Void

    private var startDate: Binding<Date> {
        Binding(
            get: {
                let stored = startInterval == 0 ? Date() : Date(timeIntervalSince1970: startInterval)
                if let dateRange {
                    return min(max(stored, dateRange.lowerBound), dateRange.upperBound)
                }
                return stored
            },
            set: { newValue in
                // Day-granular picker: snap the boundary so the whole selected
                // day is included in the travel direction.
                let cal = Calendar.current
                let snapped = direction == "older"
                    ? (cal.date(bySettingHour: 23, minute: 59, second: 59, of: newValue) ?? newValue)
                    : cal.startOfDay(for: newValue)
                startInterval = snapped.timeIntervalSince1970
                onChange()
            }
        )
    }

    /// Default start when first enabling "from date": the midpoint of the span,
    /// so it actually narrows (rather than the extreme, which is a no-op).
    private func defaultStart() -> Date {
        guard let dateRange else { return Date() }
        let mid = dateRange.lowerBound.timeIntervalSince1970
            + (dateRange.upperBound.timeIntervalSince1970 - dateRange.lowerBound.timeIntervalSince1970) / 2
        return Date(timeIntervalSince1970: mid)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Tags name the destination ("older"/"newer"); labels name travel.
            Picker("Scan order", selection: $direction) {
                Text("New→Old").tag("older")
                Text("Old→New").tag("newer")
            }
            .pickerStyle(.segmented)
            .onChange(of: direction) { _, _ in
                if startEnabled { startInterval = defaultStart().timeIntervalSince1970 }
                onChange()
            }

            HStack {
                Toggle(direction == "older" ? "Newest from date" : "Oldest from date", isOn: $startEnabled)
                    .toggleStyle(.button)
                    .onChange(of: startEnabled) { _, isOn in
                        if isOn { startInterval = defaultStart().timeIntervalSince1970 }
                        wheelExpanded = isOn      // reveal the wheel when turning on
                        onChange()
                    }
                if startEnabled {
                    // Compact date label; tap to expand/collapse the wheel so it
                    // only takes up space while actually picking.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { wheelExpanded.toggle() }
                    } label: {
                        Text(startDate.wrappedValue, format: .dateTime.year().month().day())
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            // Wheel (year/month/day rollers) shown only while expanded, so it
            // doesn't take up space the rest of the time — like the old popover.
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
