# Acceleration-Only Tempo Policy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make every track with a valid BPM playable at the selected cadence without ever slowing the music down or skipping it because of playback-rate quality limits.

**Architecture:** Keep `BPMRange.tempoPlan` as the single source of truth. Preserve original speed when a folded native cadence is inside the upward +10 SPM window; otherwise reuse `foldedMusicalTarget` to select the smallest higher octave-related music target, producing a playback rate at or above 1.0. Existing local and streaming queue policy code then stays on its playable path for every confirmed BPM.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, MusicKit, XCTest, Xcode `xcodebuild`/`xcresulttool`.

---

### Task 1: Lock the acceleration-only contract with failing tests

**Files:**
- Modify: `Tests/PlaybackModelsTests.swift:261-335, 547-675`
- Modify: `Tests/AudioManagerGenerationTests.swift:172-286, 309-460`

**Step 1: Replace the 96 BPM slowdown expectation with acceleration**

In `PlaybackModelsTests`, replace the upper-bound slowdown test with:

```swift
func testTempoPlanAcceleratesNinetySixBPMToNextHigherFold() {
    let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 96)

    XCTAssertTrue(plan.isPlayable)
    XCTAssertEqual(plan.mode, .adjustedSpeed)
    XCTAssertNil(plan.rejectionReason)
    XCTAssertEqual(plan.musicalTarget, 180, accuracy: 0.0001)
    XCTAssertEqual(plan.effectiveCadence, 180, accuracy: 0.0001)
    XCTAssertEqual(plan.requiredPlaybackRate, 180.0 / 96.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(plan.playbackRate, 1.0)
}
```

**Step 2: Add a valid-BPM invariant test**

```swift
func testTempoPlanMakesEverySupportedOriginalBPMPlayableWithoutSlowing() {
    for targetCadence in stride(from: 140.0, through: 200.0, by: 1.0) {
        for originalBPM in stride(from: 30.0, through: 300.0, by: 1.0) {
            let plan = BPMRange.tempoPlan(
                targetCadence: targetCadence,
                originalBPM: originalBPM
            )

            XCTAssertTrue(plan.isPlayable, "BPM: \(originalBPM)")
            XCTAssertGreaterThanOrEqual(
                plan.requiredPlaybackRate,
                1.0,
                "BPM: \(originalBPM)"
            )
            XCTAssertLessThanOrEqual(
                plan.requiredPlaybackRate,
                Double(BPMRange.rateMax),
                "BPM: \(originalBPM)"
            )
        }
    }
}
```

Keep the invalid-BPM test: zero, negative, NaN, and infinity must still return `.invalidOriginalBPM`.

**Step 3: Update 120 BPM and local queue integration expectations**

Replace tests that use confirmed 120 BPM as a rejected tempo with these behaviors:

```swift
func testConfirmedOneTwentyBPMAcceleratesToBaseCadence() {
    let audio = AudioManager()
    audio.targetBPM = 180
    audio.setStreamingBeatAlignment(
        bpm: 120,
        source: .metadata,
        beatOffsetSeconds: nil
    )

    XCTAssertTrue(audio.isCurrentTempoPlayable)
    XCTAssertEqual(audio.musicalTargetBPM, 180, accuracy: 0.0001)
    XCTAssertEqual(audio.playbackRate, 1.5, accuracy: 0.0001)
    XCTAssertEqual(audio.metronomeBPM, 180, accuracy: 0.0001)
    XCTAssertNil(audio.tempoRejectionMessage)
}

func testConfirmedTempoNeverMarksOrAdvancesLocalPlaylist() {
    let audio = AudioManager()
    audio.targetBPM = 180
    audio.setStreamingBeatAlignment(
        bpm: 120,
        source: .metadata,
        beatOffsetSeconds: nil
    )
    var playlist = LocalFilePlaylist(fileURLs: [
        URL(fileURLWithPath: "/tmp/a.mp3"),
        URL(fileURLWithPath: "/tmp/b.mp3"),
    ])

    let action = audio.evaluateCurrentLocalTempoPolicy(
        playlist: &playlist,
        allowsAutomaticAdvance: true
    )

    XCTAssertEqual(action, .keepCurrent)
    XCTAssertEqual(playlist.currentItem?.title, "a")
    XCTAssertNil(playlist.currentItem?.unplayableReason)
}
```

Also change the playing-track regression so setting a confirmed BPM to 120 keeps `.playing` and leaves `errorMessage` nil. Remove or rewrite the old `rejectCurrent`, `advance`, and `exhausted` assertions whose only trigger was `.rateOutOfRange`.

**Step 4: Update running-fit expectations for large acceleration**

For 120 BPM expect 1.5x, 180 SPM, `.awkward`, and an adjusted-speed detail string. For 70 BPM expect a playable rate above 1.25 rather than `.unsuitable`.

**Step 5: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,id=A89D4321-06EB-4C03-91ED-9FA09AC506DA' \
  -only-testing:CadenzaTests/PlaybackModelsTests \
  -only-testing:CadenzaTests/AudioManagerGenerationTests
```

Expected: FAIL on the new 96/120/all-valid-BPM assertions because the current implementation slows or rejects those plans.

---

### Task 2: Implement the minimal no-slowdown, no-rejection tempo plan

**Files:**
- Modify: `Cadenza/Utilities/Constants.swift:6-190`
- Test: `Tests/PlaybackModelsTests.swift`
- Test: `Tests/AudioManagerGenerationTests.swift`

**Step 1: Remove quality limits from playability**

Delete `minimumQualityRate`, the `closestWindowAdjustment` helper, and the valid-BPM guards that return `.slowingRequired` or `.rateAboveMaximum`. Keep `.invalidOriginalBPM` as the only rejection for `tempoPlan`.

**Step 2: Restore upward-only folded targeting**

After the original-speed window check, use:

```swift
let musicalTarget = foldedMusicalTarget(
    targetCadence: base,
    originalBPM: originalBPM
)
let requiredPlaybackRate = musicalTarget / originalBPM

return TempoPlan(
    baseCadence: base,
    allowedCadence: allowed,
    musicalTarget: musicalTarget,
    effectiveCadence: base,
    requiredPlaybackRate: requiredPlaybackRate,
    mode: .adjustedSpeed,
    rejectionReason: nil
)
```

Keep the original-speed candidates `[0.5, 1.0, 2.0, 4.0]` and the existing `foldedMusicalTarget` candidate family `[0.25, 0.5, 1.0, 2.0, 4.0]`. The helper already chooses the smallest candidate whose playback rate is at least 1.0. The 0.5 native relation preserves original speed for cases such as original 280 BPM at target 140 SPM.

**Step 3: Simplify obsolete rejection declarations**

Remove `maximumQualityRate` if no presentation code still consumes it. Reduce `TempoRejectionReason` to `.invalidOriginalBPM` after `rg` confirms no remaining callers of `.slowingRequired` or `.rateAboveMaximum`. Simplify `rejectedPlan` back to the invalid-input case.

**Step 4: Run focused tests and verify GREEN**

Run the Task 1 command again.

Expected: PASS. Specifically verify:

- 87 BPM → 90 BPM target, about 1.034x, 180 SPM
- 92 BPM → 1.0x, 184 SPM
- 95 BPM → 1.0x, 190 SPM
- 96 BPM → 180 BPM target, 1.875x, 180 SPM
- 120 BPM → 180 BPM target, 1.5x, 180 SPM
- 70 BPM → 90 BPM target, about 1.286x, 180 SPM
- 280 BPM at target 140 → native 0.5 relation, 1.0x, 140 SPM

**Step 5: Commit the policy change**

```bash
git add Cadenza/Utilities/Constants.swift \
  Tests/PlaybackModelsTests.swift \
  Tests/AudioManagerGenerationTests.swift
git commit -m "fix: accelerate every confirmed tempo"
```

---

### Task 3: Make large acceleration informational instead of unplayable

**Files:**
- Modify: `Cadenza/Utilities/PlaybackModels.swift:570-660`
- Modify: `Tests/PlaybackModelsTests.swift:538-675`
- Inspect: `Cadenza/Views/Components/BPMDisplayView.swift:65-160`
- Inspect: `Cadenza/Views/AppleMusicStreamingPlaylistView.swift:224-246`

**Step 1: Write the failing presentation test**

```swift
func testRunningCadenceFitLabelsLargeAccelerationWithoutRejectingIt() {
    let fit = RunningCadenceFit.evaluate(
        originalBPM: 120,
        targetCadence: 180
    )

    XCTAssertEqual(fit.playbackRate, 1.5, accuracy: 0.0001)
    XCTAssertEqual(fit.nativeFootCadence, 180, accuracy: 0.0001)
    XCTAssertEqual(fit.status, .awkward)
    XCTAssertEqual(fit.badgeText, "큰 폭 가속")
    XCTAssertEqual(fit.detailText, "120 BPM · 180 SPM · 150%")
}
```

**Step 2: Run the single test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,id=A89D4321-06EB-4C03-91ED-9FA09AC506DA' \
  -only-testing:CadenzaTests/PlaybackModelsTests/testRunningCadenceFitLabelsLargeAccelerationWithoutRejectingIt
```

Expected: FAIL because `.awkward` currently renders `박자 주의`.

**Step 3: Change only the non-risk awkward label**

In `RunningCadenceFit.badgeText`, preserve the higher-priority `신뢰도 낮음` and `박자 불안정` labels, then change the ordinary `.awkward` branch:

```swift
case .awkward:
    return "큰 폭 가속"
```

Do not use `isRecommended` or the badge status as a playback gate. `TempoPlan.isPlayable` remains the only playability source.

**Step 4: Run the presentation and view-model tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,id=A89D4321-06EB-4C03-91ED-9FA09AC506DA' \
  -only-testing:CadenzaTests/PlaybackModelsTests \
  -only-testing:CadenzaTests/QueueItemTests
```

Expected: PASS with no test that labels a valid high-rate plan as `러닝 부적합`.

**Step 5: Commit the presentation change**

```bash
git add Cadenza/Utilities/PlaybackModels.swift Tests/PlaybackModelsTests.swift
git commit -m "fix: present large tempo changes as acceleration"
```

---

### Task 4: Verify, install, and publish

**Files:**
- Verify only: all changed source and test files
- Update only if behavior changed materially: `DESIGN.md:46-59`

**Step 1: Run the complete test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,id=A89D4321-06EB-4C03-91ED-9FA09AC506DA'
```

Then inspect the newest result bundle:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcresulttool get test-results summary \
  --path "$(ls -td /Users/jyjeong/Library/Developer/Xcode/DerivedData/Cadenza-*/Logs/Test/*.xcresult | head -n 1)"
```

Expected: `failedTests: 0`, `result: Passed`.

**Step 2: Run static analysis and whitespace validation**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild analyze -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'generic/platform=iOS Simulator'
git diff --check
```

Expected: both commands exit 0.

**Step 3: Build for the physical iPhone**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean build -quiet \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS,id=00008150-00196C493CF1401C' \
  -allowProvisioningUpdates
```

Expected: exit 0; the existing orientation warning is non-blocking.

**Step 4: Install and launch**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device 00008150-00196C493CF1401C \
  /Users/jyjeong/Library/Developer/Xcode/DerivedData/Cadenza-gvjpqjgwtxiedfcflabgmggcpnyb/Build/Products/Debug-iphoneos/Cadenza.app

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
  --device 00008150-00196C493CF1401C \
  --terminate-existing com.jy.cadenza
```

Expected: install and launch both succeed.

**Step 5: Manually verify representative playlist selections**

On the device, select known tracks near 92, 96, and 120 BPM. Verify title/audio identity, no `케이던스 범위에 맞지 않는 곡입니다` message, no automatic jump, and playback-rate displays of approximately 1.0x, 1.875x, and 1.5x respectively.

**Step 6: Push the existing branch**

```bash
git status --short --branch
git push origin codex/cadence-window-policy
```

Expected: local and remote `codex/cadence-window-policy` are synchronized and PR #1 contains the new commits.
