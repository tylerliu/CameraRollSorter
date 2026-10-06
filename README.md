# Camera Roll Sorter

An iPhone and Mac app for reviewing similar photos, converting Live Photos to still images, and finding low-aesthetic or blurry photos. See APP_CONTEXT.md for the original product brief; the candidate policy below reflects the latest implementation direction.

## Current behavior

- Supports Photos authorization on iOS and macOS. On iOS, limited access includes a picker to change the accessible selection. macOS uses full access; the limited-library picker is unavailable there.
- Scans metadata for **all accessible images**, with no recent-date cutoff. Photos missing capture dates are counted separately and excluded from chronological matching.
- For each reference photo, selects **up to five nearest other photos by capture time**, before or after it, with a **strictly less than 24-hour** difference from the reference. A neighborhood therefore contains at most six photos. Ties are deterministic; neighborhoods can overlap.
- The scan compares each unique nearest-neighbor candidate pair using Vision. Pairs with distance at or below the persisted threshold (default **0.50**) become links; connected links form disjoint similarity groups, with no five-photo size limit. Isolated photos are omitted from similarity results. A chain can connect endpoints that were not directly compared or are not directly similar.
- Review settings offers a distance slider (0–2 in 0.05 steps). Lower is stricter. Closing settings regroups the retained scores without rerunning Vision. This is an experimental distance cutoff, not a calibrated confidence.
- Only similarity groups are displayed; time is solely an internal candidate filter. There is no reference image in a group. Opening a group goes directly to the chooser. Its pair-review mode uses a minimum spanning tree of accepted measured links, ordered by distance. A group of N photos has N−1 reviewed links, chosen by Kruskal’s algorithm with deterministic tie-breaking. Untested pairs are never assumed to match. Photos remain chronological.
- Groups are published incrementally as measured pairs arrive, so confirmed groups can be reviewed while the remaining candidates are still being scanned.
- Added or removed photos are reconciled incrementally in batches of any size. Invalidated scores are pruned, and Vision runs only for newly required candidate pairs—including pairs between existing photos that become neighbors after removals.
- After confirmed deletion, the deleted members and their incident similarity edges disappear immediately. The survivors are regrouped by connected components at the current threshold, so a former group can split. Components with at least two photos stay visible; components with zero or one photo disappear. Newly exposed candidate pairs are analyzed incrementally.
- Displays **Vision revision 2 distance** directly. Lower is closer; this is not a confidence percentage, quality rating, or validated match threshold.
- The chooser has a burst-style keep list and a pair-review mode. Live Photos use native playback and badging. A filmstrip scrubs between photos; metadata includes filename, capture, camera/lens, dimensions, and mapped location. On iPhone, pinch zoom and double-tap reset control the preview, and an upward swipe opens metadata. Mac controls are described below. Pair review starts with the lowest stored distances and offers keep first, keep second, or keep both. The keep list is session-local until the user confirms a deletion.
- Uses current local previews with normalized orientation and scale-fit preprocessing. No automatic iCloud downloads occur. Deletion only happens after an explicit chooser confirmation and uses PhotoKit so Photos places selected assets in Recently Deleted.
- Similar-photo groups appear in adaptive cards. Photo-selection grids adapt their column count to the available width, with thin gaps and rounded corners below ten columns. Resizing within the same column count keeps thumbnail requests stable.
- Cleanup scans keep a configurable buffer ahead of the visible results, pause when it is full, and resume as you scroll. The home screen uses a smaller preview buffer. Scan controls support direction and an optional start date; confirming a date preserves the existing scan-window cleanup behavior.
- Live → Still preserves the source still image’s original filename, capture date, location, and favorite state.

The simulator-only pixel-distance fallback and time-only group UI have been removed. Vision failures are shown as errors; no replacement or fabricated scores are shown. The earlier simulator Espresso failure may still occur. Library-wide metadata discovery and candidate image analysis run automatically, with pair-count progress. A bounded 256-entry feature-print cache is used during each analysis pass, and comparisons retain chronological neighborhood order to maximize reuse. Feature prints are not persisted between passes; measured pair distances are retained for threshold tuning and incremental library changes until the next full scan. There is no persistent disk cache yet.

## Mac controls

Photo viewers open inside the main window, with a Back button to return to the grid. Still previews request full-resolution locally available images. The window supports standard macOS resizing and full-screen controls.

- **← / →:** previous or next photo. At fitted zoom, a horizontal two-finger trackpad swipe also pages with animation. In the similar-photo chooser, filmstrip clicks/drags and arrow keys switch immediately for comparison; toolbar buttons and trackpad paging animate.
- **Space:** toggle keep in the similar-photo chooser.
- **⌘I:** toggle the metadata side pane, also available through the Info button.
- **Zoom:** use the toolbar slider, trackpad pinch, or **⌘+ / ⌘−** (**⌘=** also zooms in). Zoom ranges from fitted size to 5×. Drag with the mouse or scroll with two fingers to pan a zoomed photo; movement stops at image boundaries and centers any axis smaller than the viewer.
- **Selection grids:** click the selection circle, or click the photo in Select mode, to toggle it. **S** toggles Select mode. **Shift-click** applies the last plain click’s select/deselect action across the inclusive range. Clicking and dragging in Select mode paints a selection. Right-click a Live → Still photo to delete it; iPhone offers the same action through a long press.
- **Start date:** expand the date control to edit its textual date fields with the keyboard or steppers, then confirm with the tick button. Year fields allow large jumps without paging through calendar months.


## Development

Open `CameraRollSorter.xcodeproj`, select the shared `CameraRollSorter` scheme, and run. The app targets iOS 18.6 or later and macOS 15 or later, using Xcode 27. Choose an iPhone/simulator or My Mac as the run destination. Configure your signing team for a physical iPhone.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CameraRollSorter.xcodeproj -scheme CameraRollSorter \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/CameraRollSorter-build CODE_SIGNING_ALLOWED=NO build
```

Build the Mac app with the same scheme:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CameraRollSorter.xcodeproj -scheme CameraRollSorter \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/CameraRollSorter-mac-build CODE_SIGNING_ALLOWED=NO build
```

CI runs **Build (iOS)**, **Build (macOS)**, and **Logic checks**.

Source folders: `App` for the entry point, `Models` for candidate selection, `Services` for PhotoKit and Vision, and `Features` for the library, comparison screen, chooser, and settings; `Platform` contains shared platform helpers and iOS/macOS implementations. Xcode includes files under the synchronized source folder automatically.

## Grouping checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  CameraRollSorter/Models/SequenceGrouping.swift CameraRollSorter/Models/SimilarityGrouping.swift \
  CameraRollSorter/Models/IncrementalSimilarityGrouping.swift Tests/main.swift \
  -o /tmp/CameraRollSorter-grouping-checks
/tmp/CameraRollSorter-grouping-checks
```

Checks cover the strict one-day boundary, nearest-five selection in both time directions, old photos, quick-shot sequences, chronological display, deterministic ties, candidate limits, threshold boundaries, connected groups larger than five, rejected bridges, invalid scores, deterministic component ordering, minimum spanning trees, cycle removal, and duplicate-edge handling. Physical-device checks of real photo scores, permission changes, cloud-only photos, deletion permissions, Recently Deleted behavior, and full-library performance remain required. Review decisions are local to the chooser session and are not persisted.

## Blurry photo checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  CameraRollSorter/Services/BlurSensitivity.swift CameraRollSorter/Features/Shared/PhotoSelectionLogic.swift Tests/BlurryPhotoChecks.swift \
  -o /tmp/CameraRollSorter-blurry-checks
/tmp/CameraRollSorter-blurry-checks
```

Property-based checks (200 randomized iterations each, seeded for reproducibility) for the pure logic behind the Blurry photos flow: the strict variance threshold decision, sensitivity cutoff monotonicity and totality, sensitivity persistence round-tripping through `UserDefaults`, selection toggle involution, Select All, paint-range selection over the swept index range, the paint-vs-scroll drag-axis decision, and the edge auto-scroll direction/intensity mapping. These cover the PhotoKit/Metal/SwiftUI-free surfaces (`BlurSensitivity`, `PhotoSelectionLogic`). The image-bound properties — Laplacian-variance blur scoring (`BlurClassifier`, Metal + vImage), the scan-scope predicate on `PHAsset` types, incremental scan/reconcile ordering, and post-delete state — require the app target and remain on-device/integration checks.
