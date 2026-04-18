# Metronome Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically align the metronome to ordinary music tracks by estimating and caching beat offset, then starting playback nodes on the same engine timeline.

**Architecture:** Add pure beat-grid planning models for testable sync math, add an offline analyzer plus cache for one-time beat-offset discovery, and update `AudioManager` to schedule music and metronome from a shared anchor time on play and seek.

**Tech Stack:** Swift, AVFoundation, XCTest, XcodeGen

---

### Task 1: Add sync planning tests

**Files:**
- Modify: `Tests/PlaybackModelsTests.swift`
- Modify: `Cadenza/Utilities/PlaybackModels.swift`

**Step 1: Write failing tests**
- Add tests for next-beat delay at track start, exact-beat seeks, and beat-index continuity after seeking into a track.

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -project Cadenza.xcodeproj -scheme CadenzaTests -destination 'platform=iOS Simulator,name=iPhone 17'`

**Step 3: Write minimal implementation**
- Add pure sync planning types and math helpers in `PlaybackModels.swift`.

**Step 4: Run test to verify it passes**
- Run the same `xcodebuild test` command.

### Task 2: Add beat-offset analysis and cache

**Files:**
- Create: `Cadenza/Utilities/BeatAlignmentAnalyzer.swift`
- Modify: `Cadenza/Models/AudioManager.swift`

**Step 1: Write failing test or harness**
- Reuse pure-model tests for cache key normalization and offset normalization where possible.

**Step 2: Implement analyzer**
- Read a short PCM window, estimate onset energy, infer beat offset against known or candidate BPM, and cache the result for reuse.

**Step 3: Integrate cache lookup**
- Load cached beat alignment before analysis and only analyze on cache miss or stale fingerprint.

### Task 3: Start audio and metronome from one anchor

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift`

**Step 1: Update playback start path**
- Compute a shared `AVAudioTime` anchor for `play()` and schedule both nodes from it.

**Step 2: Update seek/resume path**
- Recompute metronome phase from the current source position and restart from the matching beat.

**Step 3: Verify**
- Run the full `xcodebuild test` command and manually test a bundled sample plus a normal track in Simulator.
