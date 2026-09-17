# iPhone photo sequence cleanup — development context

## Current implementation policy (updated from user direction)

The user superseded the time-only review fallback below: display similarity groups only. Scan all accessible image metadata. For each photo, test only up to five nearest temporal neighbors, strictly less than 24 hours away. Accepted Vision-distance edges (default threshold 0.50, tunable) form connected groups of unrestricted size. No group member is a reference image. Group detail shows the minimum spanning tree over accepted measured candidate edges and their raw distances. Transitive membership is explicitly intended; endpoints need not directly match. Preserve the older notes below as historical product context where they do not conflict with this policy.

## Objective

Build an iPhone app that helps a person review several separately captured photos of the same moment and keep the ones they want. Typical examples are repeated shutter taps with small changes in expression, framing, motion, or exposure. These are not necessarily actual Camera Burst assets or duplicate copies of one image.

The primary value is reducing the work of finding and comparing these sequences. Success does not require automatically judging which image is best.

## Evidence from the user

- The user wants similar-shot cleanup beyond the native Photos Duplicates feature.
- The user explicitly wants the keeper-selection UI to look and feel like choosing photos from a burst in Apple's Photos app (camera roll). Treat this as a confirmed design preference.
- They tried Clever Cleaner with full Photos access and a completed scan. It found no similar photos, including a deliberate test of 4–5 shots taken close together of the same subject.
- They tried CleanMyPhone (formerly Gemini Photos). It also failed that test and labeled photos the user considers clear as blurry.
- These observations establish that those apps did not meet this user's needs. They do not establish the cause or identify the algorithms used by those apps.
- Earlier recommendations were based on vendor descriptions, not hands-on benchmarks. Do not repeat those claims as validated evidence.
- The user also expressed interest in removing Live Photo motion while retaining a still photo. Treat this as a secondary feature, not a prerequisite for the first MVP.

## Product direction

Start with reliable sequence review. Add visual similarity only after testing it on representative photos.

1. **Sequence review:** surface close-in-time photos without requiring a visual similarity match. Label these “Taken close together,” not “Duplicates.” This mode must surface the user's deliberate test sequence.
2. **Visual grouping:** experimentally refine sequences using image similarity. Failure to match must not hide photos from sequence review.
3. **User choice:** support keeping multiple images, keeping all, skipping a group, and revisiting decisions.

Avoid initial blur labels, automatic keeper selection, and unattended deletion. These features have not earned the user's trust.

## Proposed MVP (implementation defaults, not confirmed preferences)

- Native SwiftUI app with PhotoKit access.
- A user-selected date range, initially a recent period, rather than an expensive mandatory full-library scan.
- Chronological candidate sequences using capture time. Start with a configurable adjacent-shot gap (e.g. 30 seconds) and a bounded total sequence span (e.g. 2 minutes). These are tunable heuristics, not established optimums.
- Split long chains so a long session cannot become one enormous group. Explain time boundaries and permit reviewing neighboring shots.
- Grid of sequences; opening a sequence enters the burst-style keeper selector described below. Preserve aspect ratio.
- Explicit keeper selection, including multiple keepers. Present the proposed removals in a review step; never interpret opening or skipping a group as approval to delete.
- Batch deletion through supported PhotoKit changes after explicit user action, handling cancellation and failure accurately.
- Local persistence for review state and analysis cache. Avoid repeated processing when nothing changed.
- Clear scan progress and an honest empty state distinguishing no candidates from inaccessible or not-yet-loaded photos.

## Keeper-selection UI — confirmed design reference

Use Apple's Photos burst-selection experience as the visual and interaction reference, applied to groups of separately captured photos. Inspect the reference on the target iOS version during implementation; the details below are proposed app behavior, not a claim about every detail of Apple's current UI.

- A large, dominant preview of the current photo with minimal surrounding controls.
- A horizontal thumbnail filmstrip along the bottom for quickly moving through the sequence, synchronized with swiping between large previews.
- Clearly distinguish the currently viewed photo from photos selected to keep. Browsing alone must not change keeper selection.
- A simple selection circle/checkmark to toggle the current photo as a keeper, with selection marks visible in the filmstrip. Allow one or several keepers.
- Keep chronological order stable while comparing; do not reorder shots by an experimental quality score.
- Show a compact position and selection count, such as “3 of 8” and “2 selected.” Support zoom to inspect expressions and detail without accidentally selecting or advancing.
- Provide Done and Cancel. Cancel discards uncommitted selection changes and never deletes assets. Returning to a committed review restores its keeper selections.
- In the initial read-only milestone, Done records the choice locally without changing the photo library. Make that behavior clear.
- Once deletion is implemented, Done leads to explicit choices to keep everything or keep selected photos and review removal of the remainder. Show the actual keep/remove counts before requesting deletion. With zero keepers selected, do not offer a keep-selected action that would delete the whole group.
- Support VoiceOver labels for photo position and keeper state, accessible control sizes, and readable selection counts.

This is a familiar interaction pattern, not a requirement to create native Burst assets or embed Apple's internal selector. Implement the interface in the app unless a suitable documented public component is verified.

## Technical approach and boundaries

### Photo access

Use PhotoKit to fetch accessible image assets and metadata. Handle full, limited, denied, and restricted authorization. Limited access means results cover only accessible assets; communicate that plainly.

Handle missing capture dates explicitly. Do not silently imply complete chronological coverage. Account for actual Camera bursts separately using burst metadata; repeated manual shutter taps normally need no burst identifier.

Use appropriately sized previews and bounded concurrency. Handle orientation, degraded callbacks, cancellations, and iCloud-only assets. Distinguish pending downloads from completed analysis; offer a deliberate download policy. Keep analysis on-device, while explaining that fetching iCloud originals can require network access.

### Similarity experiment

Apple Vision's `VNGenerateImageFeaturePrintRequest` produces image feature prints. `VNFeaturePrintObservation.computeDistance(_:to:)` compares them. This is a general image similarity building block, not a ready-made sequence grouper, duplicate classifier, or best-photo selector.

Its usefulness for this user's photos is UNVALIDATED. First build a small diagnostic that compares known sequences and unrelated examples, records distances, and displays the images alongside the results. Do not invent a universal threshold or convert distances into confidence percentages.

Keep preprocessing and feature-print revision consistent. Cache with asset identity, modification information, preprocessing configuration, and algorithm revision; invalidate incompatible or stale entries.

Compare within bounded temporal neighborhoods initially. Avoid full-library all-pairs comparisons. If visual clustering is added, prevent transitive chains from joining visually distinct endpoints; small groups allow explicit pairwise checks.

No documented public PhotoKit API exposing Photos' built-in duplicate detection/merge engine was identified in the prior research. Do not claim access to it or claim its internal algorithm differs from Vision. Verify current SDK capabilities during implementation.

### Live Photo still-only conversion (later)

Treat this as a separate, explicit operation: create a still asset, verify successful creation, then offer deletion of the original Live Photo. Turning Live playback off is not equivalent to removing its motion resource.

Before shipping, validate image quality, chosen key photo, edits, orientation, capture date, location, and relevant album/favorite behavior. Explain any metadata or editing-history loss. Never delete the original after a failed or unverified export. Avoid claiming immediate storage savings before accounting for Recently Deleted and iCloud behavior.

## Validation before expanding scope

Use real examples supplied or selected by the user; the development environment does not currently contain the user's test photos.

Required scenarios:

- Four or five separate shots a few seconds apart: appear in sequence review even if Vision finds no match.
- Same subject with small framing/expression changes: measure visual distances and inspect results before selecting thresholds.
- Different subjects photographed seconds apart: sequence review may include them, but visual grouping should be evaluated for incorrect matches.
- Similar-looking scenes on different days: do not silently combine them in temporal mode.
- Long chain of nearby timestamps: bounded groups remain manageable.
- Clear images: no unsupported blur judgments in the MVP.
- Full versus limited library access, iCloud-only images, missing dates, actual bursts, Live Photos, edited images, and library changes during review.
- Keep multiple / keep all / skip: no unintended deletion selection.
- Burst-style selector: filmstrip and preview stay synchronized; viewed and selected states are distinct; multiple keepers survive navigation; Cancel discards draft changes; zero selection cannot trigger deletion of the entire group.
- Deletion cancellation or failure: show actual outcome and preserve coherent review state.

Evaluate grouping using manually labeled examples, measuring missed useful groups and incorrectly grouped photos separately. Compare Vision-assisted review against the time-only baseline. Benchmark memory, responsiveness, and scan time on a physical iPhone; simulator success alone is insufficient.

## Implementation sequence

1. Inspect the chosen repository and installed Xcode/SDK environment. Pick the deployment target from actual tooling and the user's device requirements.
2. Build read-only sequence review with PhotoKit, timestamps, a burst-style keeper selector, local selection state, and explicit access/loading states.
3. Validate that the user's failed-app test is surfaced reliably.
4. Add the Vision diagnostic and decide from evidence whether similarity improves the workflow.
5. Add persistent review decisions and a reviewed deletion flow.
6. Consider Live Photo conversion and any quality ranking only after the core workflow works.

Do not turn experimental feature scores into product judgments prematurely. Prefer a useful, transparent comparison tool over unsupported automation claims.

## Official API references

- PhotoKit: https://developer.apple.com/documentation/PhotoKit
- Vision similarity sample: https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print
- Feature-print request: https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest
- Burst identifier: https://developer.apple.com/documentation/photos/phasset/burstidentifier
- iCloud image requests: https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed

These links were consulted during the preceding discussion. Recheck relevant current API contracts when implementing; this brief is not a substitute for SDK documentation.

## Starter instruction for a coding session

Read APP_CONTEXT.md and implement the first read-only MVP in the selected iOS repository. Start by inspecting repository instructions and the available Xcode environment. Build chronological sequence review with PhotoKit and SwiftUI, preserving a time-only path that cannot be filtered out by visual similarity. Model the keeper-selection screen on Apple's Photos burst selector: a large preview, synchronized horizontal filmstrip, and explicit selection of one or multiple keepers. Save selections locally without modifying the photo library in this milestone. Handle authorization and iCloud loading states explicitly. Do not add blur labels, automatic best-shot selection, deletion, or Live Photo conversion in the first milestone. Validate the sequence-grouping and selection behavior with meaningful edge cases and report what was tested on simulator versus physical hardware. Use the Vision diagnostic as the next milestone, and clearly distinguish measured results from assumptions.
