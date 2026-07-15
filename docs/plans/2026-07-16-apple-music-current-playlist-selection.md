# Apple Music Current Playlist Selection Implementation Plan

> [!NOTE]
> The deterministic queue-selection and cached-playlist work in this plan remains relevant. Its tempo-origin/rejection steps were subsequently superseded by `2026-07-16-acceleration-only-tempo-policy.md`: confirmed 30...300 BPM tracks are never rejected or auto-skipped for cadence/rate, and the temporary `StreamingEntryOrigin`/tempo-rejection gate described below was removed. Tempo-related snippets are historical implementation context only.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Apple Music playlist row selection start the exact requested entry and let users switch within the already-loaded current playlist without reloading the library.

**Architecture:** Treat the loaded `[Playlist.Entry]` array as the single source of truth, locate the selected entry by its playlist-entry ID, and construct an explicit `ApplicationMusicPlayer.Queue(for:startingAt:)` from that same array. Keep a lightweight playlist session in `AppleMusicStreamingController`, verify MusicKit's prepared queue entry before playback, and expose the cached session to a SwiftUI current-playlist sheet. Tempo playability is governed separately by the acceleration-only policy.

**Tech Stack:** Swift 6, SwiftUI, MusicKit `ApplicationMusicPlayer`, Combine, XCTest, Xcode 26.4.

---

### Task 1: Add deterministic selection and tempo-origin models

**Files:**
- Modify: `Cadenza/Models/QueueItem.swift:203-319`
- Test: `Tests/QueueItemTests.swift:216-327`

**Step 1: Write failing selection-plan tests**

Add tests that use plain string IDs so they run without MusicKit authorization:

```swift
func testStreamingPlaylistSelectionPlanPreservesRequestedTailIndexes() {
    let ids = (0..<10).map { "entry-\($0)" }

    XCTAssertEqual(
        StreamingPlaylistSelectionPlan.make(entryIDs: ids, selectedEntryID: "entry-5")?.selectedIndex,
        5
    )
    XCTAssertEqual(
        StreamingPlaylistSelectionPlan.make(entryIDs: ids, selectedEntryID: "entry-6")?.selectedIndex,
        6
    )
    XCTAssertEqual(
        StreamingPlaylistSelectionPlan.make(entryIDs: ids, selectedEntryID: "entry-7")?.selectedIndex,
        7
    )
}

func testStreamingPlaylistSelectionPlanRejectsMissingEntry() {
    XCTAssertNil(
        StreamingPlaylistSelectionPlan.make(
            entryIDs: ["entry-a", "entry-b"],
            selectedEntryID: "entry-c"
        )
    )
}

func testStreamingQueueStartVerifierRequiresExactQueueEntry() {
    XCTAssertTrue(
        StreamingQueueStartVerifier.matches(
            expectedQueueEntryID: "queue-4",
            actualQueueEntryID: "queue-4"
        )
    )
    XCTAssertFalse(
        StreamingQueueStartVerifier.matches(
            expectedQueueEntryID: "queue-4",
            actualQueueEntryID: "queue-8"
        )
    )
}
```

**Step 2: Write failing explicit-selection tempo tests**

```swift
func testExplicitStreamingSelectionDoesNotAutoSkipRejectedTrack() {
    XCTAssertFalse(
        StreamingTempoPolicyGate.shouldAutoSkipRejectedPlaylistEntry(origin: .explicitSelection)
    )
}

func testQueueAdvanceStillAutoSkipsRejectedTrack() {
    XCTAssertTrue(
        StreamingTempoPolicyGate.shouldAutoSkipRejectedPlaylistEntry(origin: .queueAdvance)
    )
}
```

**Step 3: Run tests to verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CadenzaTests/QueueItemTests
```

Expected: FAIL because `StreamingPlaylistSelectionPlan`, `StreamingQueueStartVerifier`, `StreamingEntryOrigin`, and the new gate method do not exist.

**Step 4: Add the minimal pure models**

Add after `StreamingTempoPolicyGate`:

```swift
enum StreamingEntryOrigin: Sendable, Equatable {
    case explicitSelection
    case queueAdvance
}

struct StreamingPlaylistSelectionPlan: Sendable, Equatable {
    let selectedEntryID: String
    let selectedIndex: Int

    static func make(entryIDs: [String], selectedEntryID: String) -> Self? {
        guard let selectedIndex = entryIDs.firstIndex(of: selectedEntryID) else { return nil }
        return Self(selectedEntryID: selectedEntryID, selectedIndex: selectedIndex)
    }
}

struct StreamingQueueStartVerifier: Sendable, Equatable {
    static func matches(expectedQueueEntryID: String?, actualQueueEntryID: String?) -> Bool {
        guard let expectedQueueEntryID, let actualQueueEntryID else { return false }
        return expectedQueueEntryID == actualQueueEntryID
    }
}
```

Extend `StreamingTempoPolicyGate`:

```swift
static func shouldAutoSkipRejectedPlaylistEntry(origin: StreamingEntryOrigin) -> Bool {
    origin == .queueAdvance
}
```

**Step 5: Run tests to verify they pass**

Run the Task 1 test command again.

Expected: `QueueItemTests` PASS.

**Step 6: Commit**

```bash
git add Cadenza/Models/QueueItem.swift Tests/QueueItemTests.swift
git commit -m "test: define deterministic streaming queue selection"
```

---

### Task 2: Build and verify an explicit MusicKit entry queue

**Files:**
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:196-231`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:255-470`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:633-655`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:792-843`
- Test: `Tests/QueueItemTests.swift`

**Step 1: Add a failing session-index transition test**

Add a pure helper test that proves an explicitly requested index stays explicit while a different observed index becomes a queue advance:

```swift
func testStreamingEntryOriginStaysExplicitForRequestedIndex() {
    XCTAssertEqual(
        StreamingEntryOrigin.resolved(
            requestedIndex: 6,
            previousIndex: 6,
            observedIndex: 6
        ),
        .explicitSelection
    )
}

func testStreamingEntryOriginBecomesQueueAdvanceWhenObservedIndexChanges() {
    XCTAssertEqual(
        StreamingEntryOrigin.resolved(
            requestedIndex: nil,
            previousIndex: 6,
            observedIndex: 7
        ),
        .queueAdvance
    )
}
```

Add the corresponding static resolver to `StreamingEntryOrigin` only after verifying failure.

**Step 2: Run the targeted tests and verify failure**

Run the Task 1 test command.

Expected: FAIL because `StreamingEntryOrigin.resolved` is missing.

**Step 3: Add controller playlist-session state**

Add published read-only state:

```swift
@Published private(set) var currentPlaylistName: String?
@Published private(set) var currentPlaylistEntries: [Playlist.Entry] = []
@Published private(set) var currentPlaylistEntryID: String?
@Published private(set) var currentPlaylistIndex: Int?
@Published private(set) var currentEntryOrigin: StreamingEntryOrigin = .explicitSelection

var hasCurrentPlaylist: Bool {
    currentPlaylistName != nil && !currentPlaylistEntries.isEmpty
}
```

Keep playlist ID/name/entries together in a private session value. Provide a read-only BPM helper for the sheet:

```swift
func cachedBPMValue(for entry: Playlist.Entry) -> Double? {
    bpm(for: entry)?.bpm
}
```

Clear this state from `stop()` and before single-song playback.

**Step 4: Replace the mixed playlist/entry queue initializer**

At the start of playlist playback:

1. Build `StreamingPlaylistSelectionPlan` from `preloadedEntries.map { $0.id.rawValue }`.
2. Fail with `선택한 곡을 현재 플레이리스트에서 찾을 수 없습니다` when the selected ID is absent.
3. Re-read `selectedEntry` from `preloadedEntries[plan.selectedIndex]`.
4. Save the playlist session and mark the selected entry/index as `.explicitSelection`.

Replace:

```swift
player.queue = ApplicationMusicPlayer.Queue(playlist: playlist, startingAt: entry)
startPlayerObservation()
syncCurrentEntryFromQueue()
try await player.prepareToPlay()
```

with the same-array queue and post-prepare verification:

```swift
let queue = ApplicationMusicPlayer.Queue(
    for: preloadedEntries,
    startingAt: selectedEntry
)
let expectedQueueEntryID = queue.entries.indices.contains(plan.selectedIndex)
    ? queue.entries[plan.selectedIndex].id
    : nil
player.queue = queue
try await player.prepareToPlay()
guard StreamingQueueStartVerifier.matches(
    expectedQueueEntryID: expectedQueueEntryID,
    actualQueueEntryID: player.queue.currentEntry?.id
) else {
    failExplicitSelection(
        generation: generation,
        message: "선택한 곡을 재생 대기열에 설정하지 못했습니다"
    )
    return
}
syncCurrentEntryFromQueue()
startPlayerObservation()
```

The observer must not start before validation because its immediate queue sync can overwrite the requested title with an unresolved or stale `currentEntry`.

**Step 5: Reuse the cached playlist without a library request**

Add:

```swift
func playCurrentPlaylistEntry(_ entry: Playlist.Entry, playbackRate: Double) async
```

It must read the saved session, locate `entry.id` in the saved entries, and call the same private playlist playback implementation. It must not issue `MusicLibraryRequest` or call `playlist.with(.entries)`.

**Step 6: Synchronize current playlist index from MusicKit queue position**

Inside `syncCurrentEntryFromQueue()`, map `player.queue.currentEntry.id` back to its index in `player.queue.entries`, then to the same index in `currentPlaylistEntries`. Update `currentPlaylistEntryID` and `currentPlaylistIndex`. If the index changes outside the requested explicit setup, set `currentEntryOrigin = .queueAdvance`.

This position mapping preserves duplicate songs because it does not use Song ID as the sole playlist-row identity.

**Step 7: Run tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CadenzaTests/QueueItemTests \
  -only-testing:CadenzaTests/AudioManagerGenerationTests
```

Expected: PASS and the controller compiles with the explicit `Playlist.Entry` queue initializer.

**Step 8: Commit**

```bash
git add Cadenza/Models/QueueItem.swift Cadenza/Services/AppleMusicStreamingController.swift Tests/QueueItemTests.swift
git commit -m "fix: start Apple Music queue at selected entry"
```

---

### Task 3: [Superseded] Prevent automatic skipping after direct selection

**Files:**
- Modify: `Cadenza/Views/PlayerView.swift:1085-1131`
- Test: `Tests/QueueItemTests.swift`

> This task captured an intermediate policy. The current implementation removes the origin-specific rejection gate entirely: every confirmed supported BPM remains on the selected/current track and uses the acceleration-only plan. Missing or invalid BPM requests confirmation without cadence-based auto-skip.

**Step 1: Add the behavior at the policy boundary**

Before calling `streamingTempoSkipCoordinator.transitionForRejected`, branch on the tested gate:

```swift
guard StreamingTempoPolicyGate.shouldAutoSkipRejectedPlaylistEntry(
    origin: streaming.currentEntryOrigin
) else {
    streaming.pause()
    audio.presentError("케이던스 범위에 맞지 않는 곡입니다")
    return
}
```

Do not change the single-song rejection path or automatic queue-advance skip coordinator.

**Step 2: Run the policy and queue tests**

Run the Task 2 test command.

Expected: PASS. Explicit selections pause on rejection; queue advances still reach the existing skip coordinator.

**Step 3: Commit**

```bash
git add Cadenza/Views/PlayerView.swift Tests/QueueItemTests.swift
git commit -m "fix: keep directly selected streaming track"
```

---

### Task 4: Add the cached current-playlist sheet

**Files:**
- Modify: `Cadenza/Views/AppleMusicStreamingPlaylistView.swift:325-333`
- Modify: `Cadenza/Views/PlayerView.swift:12-151`
- Modify: `Cadenza/Views/PlayerView.swift:221-249`
- Modify: `Cadenza/Views/PlayerView.swift:986-1017`

**Step 1: Add `AppleMusicCurrentPlaylistSheet`**

Define the new SwiftUI view at the bottom of `AppleMusicStreamingPlaylistView.swift` so the Xcode project file does not need regeneration. Its inputs are:

```swift
let playlistName: String
let entries: [Playlist.Entry]
let currentEntryID: String?
let bpmValue: (Playlist.Entry) -> Double?
let onSelect: (Playlist.Entry) -> Void
let onChooseAnotherPlaylist: () -> Void
```

Render a plain dark list with title, artist, optional integer BPM, and a speaker/check icon for the current playlist-entry ID. Add `다른 플레이리스트 선택` as a bottom safe-area action and a `닫기` toolbar button. Row taps call `onSelect(entry)` and dismiss.

**Step 2: Present the sheet from `PlayerView`**

Add:

```swift
@State private var showAppleMusicCurrentPlaylist = false
```

Add a sheet modifier that passes only controller-cached data. Its `onChooseAnotherPlaylist` callback dismisses the current sheet and presents `AppleMusicStreamingPlaylistView` on the next main-actor turn to avoid overlapping sheets.

**Step 3: Add the current-playlist button to streaming track info**

Under the Apple Music streaming badge, show a plain button only when `streaming.hasCurrentPlaylist`:

```swift
Button {
    showAppleMusicCurrentPlaylist = true
} label: {
    Label("현재 플레이리스트", systemImage: "list.bullet")
}
.accessibilityHint("다시 불러오지 않고 현재 재생 목록에서 곡을 선택합니다")
```

Include the current 1-based index and total count when available.

**Step 4: Route sheet selections through the cached session**

Add a helper parallel to `playAppleMusicPlaylist`:

```swift
private func playCurrentAppleMusicPlaylistEntry(_ entry: Playlist.Entry) {
    audio.clearError()
    resetStreamingTempoSkipCycle()
    audio.prepareForStreamingPlayback()
    audio.setStreamingBeatAlignment(bpm: nil, beatOffsetSeconds: nil)
    if audio.state == .playing { audio.pause() }
    Task {
        await streaming.playCurrentPlaylistEntry(entry, playbackRate: 1.0)
        applyStreamingTempoAndAlignment()
    }
}
```

This path must not set `showAppleMusicStreamingPlaylists` and must not perform a library request.

**Step 5: Build and inspect compiler diagnostics**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Expected: `** BUILD SUCCEEDED **`; no new Swift concurrency warnings.

**Step 6: Commit**

```bash
git add Cadenza/Views/AppleMusicStreamingPlaylistView.swift Cadenza/Views/PlayerView.swift
git commit -m "feat: reopen current Apple Music playlist instantly"
```

---

### Task 5: Full regression, physical-device validation, and publication

**Files:**
- Verify: all modified Swift and test files
- Update if needed: `docs/plans/2026-07-16-apple-music-current-playlist-selection-design.md`

**Step 1: Run the full test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Expected: all Cadenza tests PASS.

**Step 2: Run static analysis and a clean device build**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild analyze \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean build \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS,id=00008150-00196C493CF1401C' \
  -allowProvisioningUpdates
```

Expected: analyze and device build succeed. Existing AppIntents metadata and orientation warnings may remain; no new warnings from this change.

**Step 3: Install and launch on the paired iPhone**

Locate the device build product under DerivedData, then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device 00008150-00196C493CF1401C \
  /absolute/path/to/Cadenza.app

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
  --device 00008150-00196C493CF1401C com.jy.cadenza
```

Expected: install and launch succeed.

**Step 4: Perform the physical-device acceptance checks**

- Open the playlist that reproduced the bug.
- Select the fifth, fourth, and third entries from the end independently.
- Confirm each selected title and audible track match immediately.
- Open `현재 플레이리스트` while playing and choose another entry.
- Confirm the cached sheet appears instantly without returning to the playlist library.
- Select confirmed-BPM entries requiring large acceleration and confirm each remains selected, plays with `큰 폭 가속`, and never shows a cadence-range error.
- Let queue playback advance naturally and confirm confirmed-BPM entries are not skipped because of cadence or playback rate.

**Step 5: Review the final diff and commit any verification-only adjustments**

```bash
git status --short
git diff --check
git diff origin/codex/cadence-window-policy...HEAD
```

Expected: no whitespace errors and only the approved queue-selection feature is present.

**Step 6: Push the existing feature branch**

```bash
git push origin codex/cadence-window-policy
```

Expected: the existing draft pull request updates with the new commits.
