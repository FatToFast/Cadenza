# Cadenza 자동 박자 동기화 계획

**Goal:** 사용자가 ms 단위로 직접 맞추지 않아도, Cadenza가 자동 분석 결과의 신뢰도를 판단해 메트로놈을 곡 박자에 맞추거나 안전하게 BPM 기반 재생으로 폴백한다.

**Architecture:** 기존 `BeatAlignmentAnalyzer`, `BeatGridSyncPlanner`, `StreamingBPMResolver`를 유지하되, 분석 결과를 그대로 신뢰하지 않고 reliability gate를 추가한다. 로컬 파일과 Apple Music 스트리밍 모두 같은 상태 언어를 사용한다: `자동 박자 맞춤`, `BPM만 맞춤`, `확인 필요`, `박자 불안정`.

**Tech Stack:** Swift, SwiftUI, AVFoundation, MusicKit, XCTest.

---

## Product Direction

- 기본 UX에서 수동 ms 보정(`지금 맞추기`, `-40ms`, `+40ms`, `리셋`)을 제거한다.
- 사용자가 개입하는 기본 플로우는 하프/더블타임 의심 BPM 선택뿐이다.
- `confidence < 0.35` 또는 beat interval variation `> 0.07`이면 beat grid sync를 쓰지 않는다.
- 신뢰도 낮은 곡은 억지로 메트로놈을 박자에 붙이지 않고 `BPM만 맞춤` 또는 `박자 불안정`으로 표시한다.
- AI API와 온디바이스 ML 모델은 이번 1차 범위에서 제외한다.

## Implementation Plan

### Task 0: Run external beat tracker spike

**Files:**
- Reference: `docs/plans/2026-04-23-beat-tracker-library-spike.md`

**Steps:**
- Treat external beat tracking as a benchmark before adding app dependencies.
- Do not embed GPL/AGPL libraries in the app target.
- Use preview/local audio only; do not assume Apple Music playback exposes PCM samples.
- Use the spike results to decide whether the built-in analyzer is sufficient after reliability gating.

### Task 1: Add beat-sync reliability model

**Files:**
- Modify: `Cadenza/Utilities/PlaybackModels.swift`
- Modify: `Tests/PlaybackModelsTests.swift`

**Steps:**
- Add a pure helper that evaluates preview/beat-alignment reliability from confidence and beat interval variation.
- Use thresholds: confidence minimum `0.35`, beat interval variation maximum `0.07`.
- Return a compact status that can drive UI and audio routing: automatic beat sync, BPM-only, needs confirmation, unstable beat grid.
- Add tests for reliable grid, low confidence, unstable intervals, missing grid, and missing BPM.

### Task 2: Gate local-file beat grid sync

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift`
- Modify: `Cadenza/Views/PlayerView.swift`

**Steps:**
- Keep running `BeatAlignmentAnalyzer` for local files.
- Before assigning `sourceBeatTimesSeconds`, pass the analysis through the reliability helper.
- If unreliable, keep `originalBPM` but clear `sourceBeatTimesSeconds` so metronome scheduling falls back to BPM/offset behavior instead of following a bad grid.
- Replace the visible `Sync Debug` section with a user-facing status label.
- Keep ms nudge controls only behind `#if DEBUG` if they are still useful during development.

### Task 3: Gate Apple Music preview beat grid sync

**Files:**
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift`
- Modify: `Tests/StreamingBPMResolverTests.swift`

**Steps:**
- Keep GetSongBPM/external BPM lookup before preview analysis.
- When preview analysis succeeds, classify its confidence and `beatTimesSeconds` before caching/applying it.
- If reliable, store/apply BPM plus beat offset/grid.
- If unreliable, store/apply BPM only and expose a BPM-only or unstable status to the player UI.
- Do not introduce sample-accurate Apple Music synchronization in this task; `ApplicationMusicPlayer` remains the playback path.

### Task 4: Add simple BPM confirmation for octave mistakes

**Files:**
- Add: `Cadenza/Services/TrackBPMOverrideStore.swift`
- Modify: `Cadenza/Models/AudioManager.swift`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift`
- Modify: `Cadenza/Utilities/PlaybackModels.swift`
- Modify: `Cadenza/Views/PlayerView.swift`
- Add: `Tests/TrackBPMOverrideStoreTests.swift`
- Modify: `Tests/PlaybackModelsTests.swift`

**Steps:**
- Add a per-track BPM override store backed by `UserDefaults` keyed by stable track identity (Apple Music `songID`, local file `persistentID`/asset key). The store records the user's chosen BPM and is the highest-priority source — it overrides analysis, metadata, preset, and external BPM lookups.
- On track load (both local and streaming paths), look up the override before running analysis/external lookup. If found, apply it as `originalBPMSource = .manual` and skip half/double normalization.
- Detect likely half/double-time ambiguity from analysis/external BPM candidates and surface a `needsConfirmation` status with both candidates (e.g. `87` and `174`).
- Replace ms timing controls with two BPM choice buttons in `PlayerView` for the `needsConfirmation` status. Tapping a button persists it through `TrackBPMOverrideStore` and the existing manual BPM path.
- Auto-default rule: when the user does not pick (running scenario), pick the candidate closer to `audio.targetBPM`. Apply this default automatically on track load so playback never stalls waiting for input. Show a small "자동 선택됨 (목표에 가까움)" hint until the user confirms or changes it; once confirmed, store as manual override.
- Manual numeric BPM input in `PlayerView` must also write to `TrackBPMOverrideStore` so it persists across sessions.
- Do not normalize user-selected BPM through external double-time normalization.

## Persistence Contract

- Override store key: `"trackBPMOverride.v1.<identity>"` where `<identity>` is `am-<songID>` for Apple Music tracks and `local-<persistentID>` for library files; metadata-hashed key (`title|artist|album`) is used as a fallback when neither identifier is available.
- Stored value is `Double` BPM only. The store does not persist any beat grid, offset, or analysis confidence — only the user's authoritative tempo.
- Reads happen synchronously on the main actor when a track is bound; writes happen whenever `setOriginalBPM` is called from manual entry, BPM choice tap, or auto-default acceptance.
- `assumedDefault` placeholder values must never be written back to the store.

## Test Plan

- Run focused playback model tests after adding the reliability helper.
- Run focused streaming resolver tests after changing preview result gating.
- Run the full suite:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17'`
- Manually verify:
  - bundled sample shows `자동 박자 맞춤`;
  - low-confidence or unstable tracks show `BPM만 맞춤` or `박자 불안정`;
  - half/double-time songs show only BPM choice buttons;
  - normal playback and playlist BPM display still work.

## Assumptions

- Manual ms-level beat correction is too difficult for default users and should not be part of the primary UX.
- Existing manual BPM correction remains valid because choosing between BPM candidates is easier than phase alignment.
- `origin/main` is the correct base for this plan branch.
- Existing design-branch work is intentionally excluded from this branch.
