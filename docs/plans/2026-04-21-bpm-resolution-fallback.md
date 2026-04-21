# BPM Resolution Fallback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make streaming BPM selection less brittle by restoring curated GetSongBPM lookup before preview analysis and preserving preview analysis as the fallback.

**Architecture:** Keep Apple Music playback unchanged. Extract a small testable streaming BPM resolver that can combine a cached metadata value, a GetSongBPM lookup, and preview analysis in a deterministic order, then call it from `AppleMusicStreamingController`.

**Tech Stack:** Swift, MusicKit, XCTest, AVFoundation.

---

### Task 1: Add resolver regression tests

**Files:**
- Create: `Tests/StreamingBPMResolverTests.swift`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift`

**Step 1: Write failing tests**
- Add a test that returns a GetSongBPM BPM before invoking preview analysis.
- Add a test that keeps an existing cached BPM when GetSongBPM has already been attempted and preview is not needed.
- Add a test that falls back to preview analysis when GetSongBPM returns nil.

**Step 2: Run test to verify it fails**
- Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/StreamingBPMResolverTests`
- Expected: fail because the resolver type does not exist.

### Task 2: Implement GetSongBPM-first resolver

**Files:**
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift`

**Step 1: Add resolver implementation**
- Create an internal `StreamingBPMResolver` helper that receives async closures for GetSongBPM lookup and preview analysis.
- Return an internal `StreamingBPMResolution` value with the BPM result and whether external lookup was attempted.

**Step 2: Wire controller**
- Restore one-attempt-per-track GetSongBPM tracking.
- In `startPreviewBPMAnalysisIfNeeded`, use resolver order:
  1. Try GetSongBPM once.
  2. If external lookup succeeds, cache and apply it.
  3. If existing metadata cache exists, keep it and skip preview.
  4. Otherwise run preview analysis.

**Step 3: Run focused tests**
- Run the same focused `xcodebuild test` command.
- Expected: pass.

### Task 3: Verify broader behavior

**Files:**
- No production edits unless tests expose a defect.

**Step 1: Run broader tests**
- Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17'`
- Expected: pass.

**Step 2: Manual validation**
- On device, play a known awkward Apple Music track and confirm the displayed source becomes automatic detection/metadata before preview analysis changes it.
- If still awkward, use this result to decide whether Spotify PKCE and deprecated `audio_features` should be added as an optional fallback.
