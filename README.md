# Camera Roll Sorter

A prototype for finding nearby photos, displaying raw visual similarity scores, and reviewing which group members to keep. See APP_CONTEXT.md for the original product brief; the candidate policy below reflects the latest implementation direction.

## Current behavior

- Supports full and limited Photos authorization, with a picker to change the limited selection.
- Scans metadata for **all accessible images**, with no recent-date cutoff. Photos missing capture dates are counted separately and excluded from chronological matching.
- For each reference photo, selects **up to five nearest other photos by capture time**, before or after it, with a **strictly less than 24-hour** difference from the reference. A neighborhood therefore contains at most six photos. Ties are deterministic; neighborhoods can overlap.
- The scan compares each unique nearest-neighbor candidate pair using Vision. Pairs with distance at or below the persisted threshold (default **0.50**) become links; connected links form disjoint similarity groups, with no five-photo size limit. Isolated photos are omitted from similarity results. A chain can connect endpoints that were not directly compared or are not directly similar.
- Review settings offers a distance slider (0–2 in 0.05 steps). Lower is stricter. Closing settings regroups the retained scores without rerunning Vision. This is an experimental distance cutoff, not a calibrated confidence.
- Only similarity groups are displayed; time is solely an internal candidate filter. There is no reference image in a group. Opening a group goes directly to the chooser. Its pair-review mode uses a minimum spanning tree of accepted measured links, ordered by distance. A group of N photos has N−1 reviewed links, chosen by Kruskal’s algorithm with deterministic tie-breaking. Untested pairs are never assumed to match. Photos remain chronological.
- Groups are published incrementally as measured pairs arrive, so confirmed groups can be reviewed while the remaining candidates are still being scanned.
- Added or removed photos are reconciled incrementally in batches of any size. Invalidated scores are pruned, and Vision runs only for newly required candidate pairs—including pairs between existing photos that become neighbors after removals.
- Displays **Vision revision 2 distance** directly. Lower is closer; this is not a confidence percentage, quality rating, or validated match threshold.
- The chooser has a burst-style keep list and a pair-review mode. Pair review starts with the lowest stored distances and offers keep first, keep second, or keep both. The keep list is session-local until the user confirms a deletion.
- Uses current local previews with normalized orientation and scale-fit preprocessing. No automatic iCloud downloads occur. Deletion only happens after an explicit chooser confirmation and uses PhotoKit so iOS places selected assets in Recently Deleted.

The simulator-only pixel-distance fallback and time-only group UI have been removed. Vision failures are shown as errors; no replacement or fabricated scores are shown. The earlier simulator Espresso failure may still occur. Library-wide metadata discovery and candidate image analysis run automatically, with pair-count progress. A bounded 256-entry feature-print cache is used during each analysis pass, and comparisons retain chronological neighborhood order to maximize reuse. Feature prints are not persisted between passes; measured pair distances are retained for threshold tuning and incremental library changes until the next full scan. There is no persistent disk cache yet.

## Development

Open `CameraRollSorter.xcodeproj`, select the shared `CameraRollSorter` scheme, and run. The app targets iOS 18.6 or later and was created with Xcode 27. Configure your signing team for a physical iPhone.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CameraRollSorter.xcodeproj -scheme CameraRollSorter \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/CameraRollSorter-build CODE_SIGNING_ALLOWED=NO build
```

Source folders: `App` for the entry point, `Models` for candidate selection, `Services` for PhotoKit and Vision, and `Features` for the library, comparison screen, chooser, and settings. Xcode includes files under the synchronized source folder automatically.

## Grouping checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  CameraRollSorter/Models/SequenceGrouping.swift CameraRollSorter/Models/SimilarityGrouping.swift Tests/main.swift \
  -o /tmp/CameraRollSorter-grouping-checks
/tmp/CameraRollSorter-grouping-checks
```

Checks cover the strict one-day boundary, nearest-five selection in both time directions, old photos, quick-shot sequences, chronological display, deterministic ties, candidate limits, threshold boundaries, connected groups larger than five, rejected bridges, invalid scores, deterministic component ordering, minimum spanning trees, cycle removal, and duplicate-edge handling. Physical-device checks of real photo scores, permission changes, cloud-only photos, deletion permissions, Recently Deleted behavior, and full-library performance remain required. Review decisions are local to the chooser session and are not persisted.
