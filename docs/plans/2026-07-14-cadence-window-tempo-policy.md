# Cadence Window Tempo Policy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 기준 케이던스부터 +10 SPM까지 원곡 속도를 우선 허용하고, 1.25배를 넘는 곡은 안전하게 차단·건너뛰며 모든 표시와 보조 로직을 같은 템포 계획에 맞춘다.

**Architecture:** `BPMRange.TempoPlan`을 템포 판단의 단일 소스로 확장해 허용 구간, 실제 케이던스, 음악 목표 BPM, 안전 재생속도와 재생 가능 여부를 함께 반환한다. `AudioManager`, `RunningCadenceFit`, 큐, 메인 UI, 메트로놈과 Live Activity는 이 결과만 소비하고 원곡 BPM 자체는 변경하지 않는다.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, MusicKit, ActivityKit, XCTest, XcodeGen

---

**Implementation protocol:** 각 동작 변경은 @superpowers:test-driven-development의 RED → GREEN → REFACTOR 순서를 따르고, 완료 주장은 @superpowers:verification-before-completion의 fresh test/build 증거가 있을 때만 한다.

## 실행 전 주의사항

- 현재 작업 트리에는 이 기능의 초기 프로토타입과 사용자 소유 변경이 함께 있다.
- 다음 경로는 별도 요청 없이는 stage하지 않는다: `project.yml`, `Cadenza.xcodeproj/project.pbxproj`, `Cadenza 3.xcodeproj/`, `SMA/`.
- 각 커밋 전 `git diff --cached --name-only`로 의도한 파일만 포함됐는지 확인한다.
- 이 컴퓨터는 현재 `xcode-select`가 Command Line Tools를 가리킨다. Xcode가 `/Applications/Xcode.app`에 있다면 전역 설정을 바꾸지 말고 각 명령 앞에 다음을 붙인다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

- 기본 테스트 destination은 `platform=iOS Simulator,name=iPhone 16 Pro`다. 설치된 simulator 이름이 다르면 `xcrun simctl list devices available`로 실제 이름만 바꾼다.

## Task 1: 단일 TempoPlan과 단방향 케이던스 구간

**Files:**
- Modify: `Cadenza/Utilities/Constants.swift:6-109`
- Modify: `Tests/PlaybackModelsTests.swift:262-377`

**Step 1: 현재 대칭 드리프트를 깨는 실패 테스트 작성**

기존 cadence drift 테스트를 새 정책 테스트로 교체하고 다음 사례를 추가한다.

```swift
func testTempoPlanUsesNativeCadenceInsideUpwardWindow() {
    let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 92)
    XCTAssertEqual(plan.allowedCadence.lowerBound, 180)
    XCTAssertEqual(plan.allowedCadence.upperBound, 190)
    XCTAssertEqual(plan.effectiveCadence, 184)
    XCTAssertEqual(plan.playbackRate, 1.0, accuracy: 0.0001)
    XCTAssertTrue(plan.isPlayable)
    XCTAssertEqual(plan.mode, .originalSpeed)
}

func testTempoPlanNeverDriftsBelowBaseCadence() {
    let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 89)
    XCTAssertEqual(plan.effectiveCadence, 180)
    XCTAssertEqual(plan.playbackRate, 90 / 89, accuracy: 0.0001)
    XCTAssertTrue(plan.isPlayable)
    XCTAssertEqual(plan.mode, .adjustedSpeed)
}

func testTempoPlanRejectsRateAboveQualityLimit() {
    let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 96)
    XCTAssertFalse(plan.isPlayable)
    XCTAssertEqual(plan.rejectionReason, .rateAboveMaximum)
    XCTAssertGreaterThan(plan.requiredPlaybackRate, 1.25)
}

func testTempoPlanMovesWindowWithBaseAndCapsAtGlobalMaximum() {
    XCTAssertEqual(
        BPMRange.tempoPlan(targetCadence: 175, originalBPM: 92).allowedCadence,
        175...185
    )
    XCTAssertEqual(
        BPMRange.tempoPlan(targetCadence: 195, originalBPM: 100).allowedCadence,
        195...200
    )
}
```

**Step 2: 테스트가 올바르게 실패하는지 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/PlaybackModelsTests
```

Expected: 새 `allowedCadence`, `mode`, `isPlayable`, `rejectionReason` API가 없어 compile failure가 나거나, 89 BPM이 178 SPM으로 하향 드리프트해 assertion이 실패한다.

**Step 3: 최소 TempoPlan 구현**

`Constants.swift`의 임시 `cadenceDriftTolerance`/`driftRateThreshold` 기반 구현을 다음 형태로 교체한다.

```swift
enum BPMRange {
    static let targetMin: Double = 140
    static let targetMax: Double = 200
    static let targetDefault: Double = 180
    static let cadenceAllowance: Double = 10
    static let maximumQualityRate: Double = 1.25

    enum TempoMode: Equatable, Sendable {
        case originalSpeed
        case adjustedSpeed
        case rejected
    }

    enum TempoRejectionReason: Equatable, Sendable {
        case invalidOriginalBPM
        case slowingRequired
        case rateAboveMaximum
    }

    struct TempoPlan: Equatable, Sendable {
        let baseCadence: Double
        let allowedCadence: ClosedRange<Double>
        let musicalTarget: Double
        let effectiveCadence: Double
        let requiredPlaybackRate: Double
        let mode: TempoMode
        let rejectionReason: TempoRejectionReason?

        var isPlayable: Bool { rejectionReason == nil }
        var playbackRate: Double { isPlayable ? requiredPlaybackRate : 1.0 }
    }
}
```

알고리즘은 다음 순서를 그대로 따른다.

```swift
static func tempoPlan(targetCadence: Double, originalBPM: Double) -> TempoPlan {
    let base = min(max(targetCadence, targetMin), targetMax)
    let allowed = base...min(base + cadenceAllowance, targetMax)

    guard originalBPM.isFinite, originalBPM > 0 else {
        return rejectedPlan(base: base, allowed: allowed, reason: .invalidOriginalBPM)
    }

    let nativeCandidates = (0...2).map { originalBPM * pow(2.0, Double($0)) }
    if let native = nativeCandidates.first(where: { allowed.contains($0) }) {
        return TempoPlan(
            baseCadence: base,
            allowedCadence: allowed,
            musicalTarget: originalBPM,
            effectiveCadence: native,
            requiredPlaybackRate: 1,
            mode: .originalSpeed,
            rejectionReason: nil
        )
    }

    let musicalTarget = foldedMusicalTarget(targetCadence: base, originalBPM: originalBPM)
    let requiredRate = musicalTarget / originalBPM
    guard requiredRate >= 1 else {
        return rejectedPlan(base: base, allowed: allowed, musicalTarget: musicalTarget,
                            requiredRate: requiredRate, reason: .slowingRequired)
    }
    guard requiredRate <= maximumQualityRate else {
        return rejectedPlan(base: base, allowed: allowed, musicalTarget: musicalTarget,
                            requiredRate: requiredRate, reason: .rateAboveMaximum)
    }
    return TempoPlan(
        baseCadence: base,
        allowedCadence: allowed,
        musicalTarget: musicalTarget,
        effectiveCadence: base,
        requiredPlaybackRate: requiredRate,
        mode: .adjustedSpeed,
        rejectionReason: nil
    )
}
```

`metronomeCadence`의 `<100이면 ×2` 분기는 제거하고 입력 케이던스를 140~200으로 clamp만 한다. 프로덕션 참조가 없는 `automaticTarget`과 그 테스트도 제거한다.

**Step 4: 순수 모델 테스트 통과 확인**

Run: Task 1 Step 2와 동일.

Expected: `PlaybackModelsTests` 0 failures.

**Step 5: 커밋**

```bash
git add Cadenza/Utilities/Constants.swift Tests/PlaybackModelsTests.swift
git diff --cached --check
git commit -m "feat: add bounded cadence tempo plan"
```

## Task 2: AudioManager를 TempoPlan에 연결하고 안전하지 않은 재생 차단

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift:79-139, 672-715, 830-840`
- Modify: `Tests/AudioManagerGenerationTests.swift:29-90`

**Step 1: 실패하는 통합 테스트 작성**

```swift
func testAudioManagerExposesSameTempoPlanUsedForPlayback() {
    let audio = AudioManager()
    audio.targetBPM = 180
    audio.setStreamingBeatAlignment(bpm: 95, source: .metadata, beatOffsetSeconds: nil)

    XCTAssertEqual(audio.tempoPlan.effectiveCadence, 190)
    XCTAssertEqual(audio.playbackRate, audio.tempoPlan.playbackRate)
    XCTAssertEqual(audio.metronomeBPM, 190)
    XCTAssertTrue(audio.isCurrentTempoPlayable)
}

func testAudioManagerBlocksUnsafeSingleTrackTempo() {
    let audio = AudioManager()
    audio.targetBPM = 180
    audio.setStreamingBeatAlignment(bpm: 96, source: .metadata, beatOffsetSeconds: nil)

    XCTAssertFalse(audio.isCurrentTempoPlayable)
    XCTAssertEqual(audio.playbackRate, 1.0)
    XCTAssertEqual(audio.tempoRejectionMessage, "케이던스 범위에 맞지 않는 곡입니다")
}
```

**Step 2: 해당 테스트만 실행해 실패 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/AudioManagerGenerationTests
```

Expected: `tempoPlan`이 private이고 playability/message API가 없어 compile failure.

**Step 3: 최소 통합 구현**

- `tempoPlan`을 읽기 전용 internal 계산 프로퍼티로 노출한다.
- `musicalTargetBPM`, `effectiveCadence`, `playbackRate`와 `metronomeBPM`은 모두 `tempoPlan`에서 읽는다.
- 거부된 계획의 적용 재생속도는 1.0으로 둔다.
- `isCurrentTempoPlayable`과 `tempoRejectionMessage`를 추가한다.
- 로컬 파일 재생의 `canStartPlayback`과 `play()` guard에 확정 BPM의 재생 가능 여부를 포함한다.
- BPM 미확정 상태는 기존 `needsConfirmation` 안내를 유지하고 큰 변속은 적용하지 않는다.
- `updateRate()`는 거부된 계획에서 `timePitch.rate = 1.0`을 적용한다.

**Step 4: 통합 테스트와 모델 테스트 실행**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/AudioManagerGenerationTests \
  -only-testing:CadenzaTests/PlaybackModelsTests
```

Expected: 두 test class 모두 0 failures.

**Step 5: 커밋**

```bash
git add Cadenza/Models/AudioManager.swift Tests/AudioManagerGenerationTests.swift
git diff --cached --check
git commit -m "feat: gate playback with tempo plan"
```

## Task 3: RunningCadenceFit의 독립 배수 계산 제거

**Files:**
- Modify: `Cadenza/Utilities/PlaybackModels.swift:535-705`
- Modify: `Tests/PlaybackModelsTests.swift:475-545`
- Modify: `Cadenza/Views/PlayerView.swift:548-570`

**Step 1: 실제 TempoPlan과 같아야 하는 실패 테스트 작성**

```swift
func testRunningCadenceFitUsesTempoPlanPlaybackRate() {
    let fit = RunningCadenceFit.evaluate(originalBPM: 120, targetCadence: 180)
    let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 120)

    XCTAssertEqual(fit.playbackRate, plan.requiredPlaybackRate, accuracy: 0.0001)
    XCTAssertEqual(fit.isRecommended, plan.isPlayable)
    XCTAssertEqual(fit.status, .unsuitable)
}

func testRunningCadenceFitReportsNativeNinetyFiveAsOriginalSpeed() {
    let fit = RunningCadenceFit.evaluate(originalBPM: 95, targetCadence: 180)
    XCTAssertEqual(fit.playbackRate, 1.0)
    XCTAssertEqual(fit.nativeFootCadence, 190)
    XCTAssertEqual(fit.status, .excellent)
}
```

**Step 2: 실패 확인**

Run: Task 1 Step 2와 동일.

Expected: 120 BPM fit은 기존 1.5 pulse 후보 때문에 1.0배/적합으로 계산되어 실패.

**Step 3: 최소 구현**

- `pulseMultipliers`, 후보 정렬과 `fitPenalty`를 삭제한다.
- `evaluate`가 `BPMRange.tempoPlan`을 한 번 호출해 필드를 구성한다.
- `nativeFootCadence`는 `plan.effectiveCadence`, `playbackRate`는 `plan.requiredPlaybackRate`를 사용한다.
- `plan.isPlayable == false`면 `.unsuitable`로 분류한다.
- 재생 가능하면 기존 7%/14% 기준을 유지하되 1.25까지는 `.awkward`로 표현한다.
- 프리뷰 신뢰도/불안정 grid override는 기존대로 마지막에 적용한다.
- `detailText`는 실제 계획을 설명하도록 `92 BPM · 184 SPM · 원곡 속도` 또는 `170 BPM · 180 SPM · 106%` 형식으로 변경한다.
- `PlayerView.currentCadenceFit`은 현재 기준 케이던스만 전달하고 추가 계산을 하지 않는다.

**Step 4: 모델 테스트 실행**

Expected: `PlaybackModelsTests` 0 failures.

**Step 5: 커밋**

```bash
git add Cadenza/Utilities/PlaybackModels.swift Tests/PlaybackModelsTests.swift Cadenza/Views/PlayerView.swift
git diff --cached --check
git commit -m "fix: align cadence fit with tempo plan"
```

## Task 4: 정확한 원곡 BPM을 보존하고 자동 옥타브 스냅 제거

**Files:**
- Modify: `Cadenza/Views/PlayerView.swift:153-198, 571-648`
- Modify: `Cadenza/Models/AudioManager.swift:842-875`
- Modify: `Tests/AudioManagerGenerationTests.swift`

**Step 1: SwiftUI 생명주기를 포함한 회귀 테스트 작성**

`AudioManagerGenerationTests.swift`에 `SwiftUI`와 `UIKit`을 import하고 host view를 이용한다.

```swift
func testPlayerViewDoesNotSnapDetectedOriginalBPMToCadenceOctave() async {
    let audio = AudioManager()
    audio.targetBPM = 180
    let host = UIHostingController(rootView: PlayerView().environmentObject(audio))
    let window = UIWindow()
    window.rootViewController = host
    window.makeKeyAndVisible()
    _ = host.view

    audio.setStreamingBeatAlignment(bpm: 87, source: .analysis, beatOffsetSeconds: nil)
    await Task.yield()

    XCTAssertEqual(audio.originalBPM, 87)
}
```

**Step 2: 테스트 실패 확인**

Run: Task 2 Step 2와 동일.

Expected: `PlayerView.onChange`가 `applyAutoBPMDefaultIfNeeded()`를 호출해 87을 174로 변경하므로 failure.

**Step 3: 최소 수정**

- `audio.originalBPM`/`originalBPMSource`에서 `applyAutoBPMDefaultIfNeeded`를 호출하는 두 `onChange`를 제거한다.
- `applyAutoBPMDefaultIfNeeded`와 `AudioManager.applyAutoBPMDefault`를 삭제한다.
- `bpmChoiceSection`은 현재 감지값을 active 상태로만 표시한다.
- `자동 선택됨`, `목표에 가까움`, `적용했습니다` 문구를 제거한다.
- 안내는 `감지된 원곡 BPM을 유지합니다. 박자가 두 배 또는 절반으로 잡혔다면 다른 값을 선택하세요.`로 변경한다.
- 사용자가 버튼을 눌렀을 때의 `confirmBPMChoice`와 영구 override 동작은 유지한다.

**Step 4: 회귀 테스트 실행**

Expected: `AudioManagerGenerationTests`와 `AudioManagerOverrideIntegrationTests` 0 failures.

**Step 5: 커밋**

```bash
git add Cadenza/Views/PlayerView.swift Cadenza/Models/AudioManager.swift Tests/AudioManagerGenerationTests.swift
git diff --cached --check
git commit -m "fix: preserve detected original bpm"
```

## Task 5: 로컬·스트리밍 큐의 안전한 건너뛰기

**Files:**
- Modify: `Cadenza/Models/QueueItem.swift:3-141`
- Modify: `Cadenza/Models/AudioManager.swift:358-452`
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:335-476`
- Modify: `Cadenza/Views/PlayerView.swift:996-1103`
- Modify: `Tests/QueueItemTests.swift`
- Modify: `Tests/AudioManagerGenerationTests.swift`

**Step 1: 큐 순환 방지 실패 테스트 작성**

```swift
func testPlaylistSkipsItemsMarkedTempoUnplayable() {
    var playlist = LocalFilePlaylist(fileURLs: [
        URL(fileURLWithPath: "/tmp/a.mp3"),
        URL(fileURLWithPath: "/tmp/b.mp3"),
        URL(fileURLWithPath: "/tmp/c.mp3"),
    ])
    playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.8))

    XCTAssertEqual(playlist.moveToNextPlayable()?.title, "b")
    playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.7))
    XCTAssertEqual(playlist.moveToNextPlayable()?.title, "c")
    playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.6))
    XCTAssertNil(playlist.moveToNextPlayable())
}

func testSkipGuardRejectsSameStreamingIdentityTwice() {
    var guardState = TempoSkipGuard()
    XCTAssertTrue(guardState.register(identity: "song-a"))
    XCTAssertFalse(guardState.register(identity: "song-a"))
}
```

**Step 2: 테스트 실패 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/QueueItemTests
```

Expected: queue marking/navigation과 `TempoSkipGuard`가 없어 compile failure.

**Step 3: 순수 큐 도우미 구현**

- `LocalFilePlaylist.markCurrentUnplayable(_:)`가 `items`와 `originalItems`의 동일 ID 항목을 갱신하게 한다.
- `moveToNextPlayable()`은 현재 뒤쪽 항목만 최대 `items.count`번 검사하고 `unplayableReason == nil`인 항목을 반환한다.
- `TempoSkipGuard`는 현재 자동 전진 사이클에서 방문한 streaming identity를 Set으로 관리하고 중복을 거부한다.

**Step 4: AudioManager 로컬 큐 연결**

- 트랙 로드 완료 후 `tempoPlan.isPlayable == false`면 현재 항목을 `.rateOutOfRange(required:)`로 표시한다.
- playlist load/next/track-ended 자동 전진은 `moveToNextPlayable()`을 사용한다.
- 모든 항목이 거부되면 재생을 중지하고 `케이던스 범위에 맞는 곡이 없습니다`를 표시한다.
- 사용자가 직접 선택한 단일 곡은 자동으로 다른 곡으로 이동하지 않는다.

**Step 5: 스트리밍 큐 연결**

- `AppleMusicStreamingController`에 현재 queue identity와 playlist 여부를 읽는 API를 추가한다.
- `skipToNext`는 성공 여부를 반환하게 한다.
- `PlayerView.applyStreamingTempoAndAlignment`에서 BPM이 확정된 뒤 plan이 거부되면 playlist는 다음 곡으로 이동한다.
- 같은 identity를 다시 만나거나 next가 실패하면 자동 전진을 멈추고 안내한다.
- 단일 streaming 곡이면 pause하고 안내한다.
- 새 사용자 선택 또는 기준 케이던스 변경 시 skip guard를 초기화한다.

**Step 6: 큐·통합 테스트 실행**

Expected: `QueueItemTests`, `AudioManagerGenerationTests`, `StreamingBPMResolverTests` 0 failures.

**Step 7: 커밋**

```bash
git add Cadenza/Models/QueueItem.swift Cadenza/Models/AudioManager.swift \
  Cadenza/Services/AppleMusicStreamingController.swift Cadenza/Views/PlayerView.swift \
  Tests/QueueItemTests.swift Tests/AudioManagerGenerationTests.swift
git diff --cached --check
git commit -m "feat: skip tracks outside cadence policy"
```

## Task 6: 메인 케이던스 UI와 접근성 정합성

**Files:**
- Modify: `Cadenza/Views/Components/BPMDisplayView.swift`
- Modify: `Cadenza/Views/Components/BPMSliderView.swift`
- Modify: `Cadenza/Views/PlayerView.swift:35-100, 220-348, 442-475`

**Step 1: UI가 필요한 데이터를 명시하는 compile-failing initializer 변경**

`BPMDisplayView` 호출부를 먼저 다음 형태로 바꿔 compile failure를 만든다.

```swift
BPMDisplayView(
    tempoPlan: audio.tempoPlan,
    originalBPM: nowPlaying.originalBPM,
    originalBPMSource: nowPlaying.originalBPMSource,
    cadenceFit: currentCadenceFit
)
```

**Step 2: build 실패 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: 새 initializer가 없어 compile failure.

**Step 3: BPMDisplayView 최소 구현**

- 큰 숫자: `tempoPlan.effectiveCadence`
- 보조 문구: `기준 180 · 허용 180~190`
- 원곡: `원곡 92 BPM`
- `.originalSpeed`: `원곡 속도`
- `.adjustedSpeed`: `재생속도 1.06배`
- `.rejected`: `범위에 맞지 않음 · 필요 1.88배`
- `원곡 → 목표` 화살표를 삭제한다.
- 전체를 `.accessibilityElement(children: .ignore)`로 묶고 label/value에 실제·기준·허용·원곡·속도를 포함한다.

**Step 4: BPMSliderView 정리**

- 상수 변경으로 140~200 범위를 사용한다.
- playbackRate 전달과 `현재 1.06x` 중복 표시를 제거한다.
- reset 라벨을 `↺ 180`으로 바꾼다.
- 빠른 조절 버튼에 `.frame(minHeight: 44)`를 적용한다.
- slider에 `기준 케이던스` accessibility label/value를 추가한다.

**Step 5: playbackControls 중복 제거**

`trackInfoSection`의 streaming/local/metronome/empty 네 분기에서 `playbackControls`를 제거하고 body 하단 공통 호출 하나만 남긴다. `원본 BPM` 용어는 `원곡 BPM`으로 통일한다.

**Step 6: build 및 관련 테스트**

Run: Task 6 Step 2와 Task 1 Step 2.

Expected: build 성공, 모델 테스트 0 failures. Simulator에서 네 상태 각각 playback control 한 세트만 보이는지 수동 확인.

**Step 7: 커밋**

```bash
git add Cadenza/Views/Components/BPMDisplayView.swift \
  Cadenza/Views/Components/BPMSliderView.swift Cadenza/Views/PlayerView.swift
git diff --cached --check
git commit -m "fix: make cadence ui match tempo plan"
```

## Task 7: Live Activity에 실제 케이던스 전달

**Files:**
- Modify: `Cadenza/Models/CadenzaActivityAttributes.swift:12-22`
- Modify: `Cadenza/Services/LiveActivityCoordinator.swift:41-72`
- Modify: `CadenzaLiveActivity/CadenzaLiveActivity.swift:7-160`
- Modify: `Tests/NowPlayingInfoTests.swift` 또는 새 activity state assertions를 기존 test file에 추가

**Step 1: 상태 의미 테스트 작성**

```swift
func testActivityStateKeepsCadenceSeparateFromOriginalBPM() {
    let state = CadenzaActivityState(
        title: "Song", artist: nil,
        effectiveCadence: 190, baseCadence: 180, originalBPM: 95,
        elapsed: 0, duration: 180, isPlaying: true, artworkData: nil
    )
    XCTAssertEqual(state.effectiveCadence, 190)
    XCTAssertEqual(state.baseCadence, 180)
    XCTAssertEqual(state.originalBPM, 95)
}
```

**Step 2: compile failure 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/NowPlayingInfoTests
```

Expected: 새 state 필드가 없어 compile failure.

**Step 3: 상태와 위젯 구현**

- 모호한 `bpm`/`targetBPM`을 `effectiveCadence`/`baseCadence`/`originalBPM`으로 변경한다.
- coordinator는 `audio.tempoPlan.effectiveCadence`를 전달한다.
- Combine 관찰은 `originalBPM`, `targetBPM` 변경 모두 유지해 derived cadence 갱신을 보장한다.
- 큰 SPM, compact trailing 숫자, `BeatBreathingHalo`는 `effectiveCadence`를 사용한다.
- 하단 보조 정보는 `기준 180`으로 표시하고 원곡 BPM은 필요할 때만 작은 보조값으로 표시한다.

**Step 4: test와 app-extension build 실행**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: main app과 Live Activity extension 모두 build 성공.

**Step 5: 커밋**

```bash
git add Cadenza/Models/CadenzaActivityAttributes.swift \
  Cadenza/Services/LiveActivityCoordinator.swift \
  CadenzaLiveActivity/CadenzaLiveActivity.swift Tests/NowPlayingInfoTests.swift
git diff --cached --check
git commit -m "fix: show effective cadence in live activity"
```

## Task 8: 메트로놈 설정 영속성

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift:100-105, 223-236`
- Modify: `Tests/AudioManagerGenerationTests.swift`

**Step 1: 격리 UserDefaults를 쓰는 실패 테스트 작성**

```swift
func testMetronomePreferencesPersistAcrossAudioManagerInstances() {
    let suite = "AudioManagerPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = AudioManager(defaults: defaults)
    first.targetBPM = 175
    first.metronomeEnabled = false
    first.metronomeVolume = 0.35

    let second = AudioManager(defaults: defaults)
    XCTAssertEqual(second.targetBPM, 175)
    XCTAssertFalse(second.metronomeEnabled)
    XCTAssertEqual(second.metronomeVolume, 0.35, accuracy: 0.001)
}
```

**Step 2: compile failure 확인**

Run: Task 2 Step 2와 동일.

Expected: `defaults:` injection API가 없어 compile failure.

**Step 3: 최소 영속 구현**

- `AudioManager` init에 `defaults: UserDefaults = .standard`를 주입한다.
- target cadence didSet도 주입된 defaults를 사용한다.
- metronome enabled/volume 전용 key를 추가한다.
- `object(forKey:) != nil`일 때만 저장값을 복원한다.
- cadence는 140~200, volume은 0~1로 clamp한다.
- init 중 프로퍼티 대입이 didSet을 호출하지 않는 기존 특성을 유지한다.

**Step 4: 테스트 실행**

Expected: `AudioManagerGenerationTests` 0 failures이고 test 간 `UserDefaults.standard` 오염이 없다.

**Step 5: 커밋**

```bash
git add Cadenza/Models/AudioManager.swift Tests/AudioManagerGenerationTests.swift
git diff --cached --check
git commit -m "feat: persist metronome preferences"
```

## Task 9: BPM 분석 실패의 수동 재시도 경로

외부 API와 프리뷰의 자동 상시 교차검증은 별도 설계가 필요한 후속 범위다. 이번 계획에서는 “세션 동안 재시도 불가”를 해소하고, 사용자가 명시적으로 재시도할 때 외부 조회와 캐시를 우회한 프리뷰 분석을 모두 새로 실행한다.

**Files:**
- Modify: `Cadenza/Services/AppleMusicStreamingController.swift:111-120, 756-835`
- Modify: `Cadenza/Views/PlayerView.swift:650-730`
- Modify: `Tests/StreamingBPMResolverTests.swift`

**Step 1: retry state 실패 테스트 작성**

순수 `PreviewAnalysisRetryPolicy`를 추가하는 API부터 테스트한다.

```swift
func testPreviewRetryPolicyAllowsExplicitRetryAfterFailure() {
    var policy = PreviewAnalysisRetryPolicy(maxAutomaticAttempts: 1)
    XCTAssertTrue(policy.shouldAttempt(identity: "song"))
    policy.recordFailure(identity: "song")
    XCTAssertFalse(policy.shouldAttempt(identity: "song"))
    policy.reset(identity: "song")
    XCTAssertTrue(policy.shouldAttempt(identity: "song"))
}
```

**Step 2: 실패 확인**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CadenzaTests/StreamingBPMResolverTests
```

Expected: retry policy가 없어 compile failure.

**Step 3: 최소 retry 구현**

- `failedPreviewAnalysisKeys` Set을 명시적 `PreviewAnalysisRetryPolicy`로 교체한다.
- controller에 `retryCurrentBPMAnalysis()`를 추가해 현재 identity의 실패와 GetSongBPM attempted 상태를 초기화하고 preview 분석 캐시를 우회해 다시 시작한다.
- 수동 재시도에서는 새 외부 BPM이 있어도 프리뷰 분석을 수행하며, 프리뷰 성공값을 우선하고 실패 시 외부/기존 값으로 폴백한다.
- 박자 상태가 `.needsConfirmation` 또는 `.bpmOnly`일 때 `다시 분석` 버튼을 노출한다.
- 수동 BPM override는 재시도보다 계속 우선한다.
- 프로덕션 경로의 관련 `print`는 같은 로깅 문장이 이미 있을 때 제거한다.

**Step 4: resolver 테스트와 build 실행**

Expected: `StreamingBPMResolverTests` 0 failures, app build 성공.

**Step 5: 커밋**

```bash
git add Cadenza/Services/AppleMusicStreamingController.swift \
  Cadenza/Views/PlayerView.swift Tests/StreamingBPMResolverTests.swift
git diff --cached --check
git commit -m "feat: allow bpm analysis retry"
```

## Task 10: 문서 현행화와 전체 검증

**Files:**
- Modify: `SPEC.md:277-278, 442-444`
- Modify: `DESIGN.md:45-65, 108-116, 145-154, 528-563`
- Modify: `PLANNING.md:131-155, 620-730`

**Step 1: 문서 불일치 갱신**

- 목표 BPM을 `기준 케이던스`로 통일한다.
- 슬라이더 140~200, 기본 180, 허용 상향 +10을 기록한다.
- 프리셋 행을 현재 -5/기본/+5 조작으로 갱신한다.
- 원곡 BPM, 음악 목표 BPM, 실제 케이던스의 의미를 용어집에 분리한다.
- 1.25배 초과 큐 skip과 단일 곡 block 정책을 에러/상태 표에 추가한다.
- Live Activity가 실제 케이던스를 표시한다고 명시한다.

**Step 2: whitespace와 변경 범위 검사**

```bash
git diff --check
git status --short
git diff --stat
```

Expected: whitespace error 없음. 사용자 소유 `project.yml`, pbxproj, `Cadenza 3.xcodeproj/`, `SMA/`는 여전히 stage되지 않음.

**Step 3: 전체 테스트 실행**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: `** TEST SUCCEEDED **`, 0 failures.

**Step 4: clean build 실행**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean build \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: `** BUILD SUCCEEDED **`.

**Step 5: 핵심 시나리오 수동 확인**

- 기준 180 + 원곡 90 → 180 SPM/원곡 속도
- 기준 180 + 원곡 92 → 184 SPM/원곡 속도
- 기준 180 + 원곡 95 → 190 SPM/원곡 속도
- 기준 180 + 원곡 89 → 180 SPM/약 1.01배
- 기준 180 + 원곡 96 → 단일 곡 block 또는 queue skip
- 기준을 175로 변경 → 허용 175~185로 즉시 갱신
- 네 화면 상태에서 playback control 한 세트만 표시
- 앱 재시작 후 기준/메트로놈 on-off/볼륨 복원
- Live Activity 대표 숫자와 펄스가 effective cadence 사용
- VoiceOver가 `실제 케이던스, 기준, 허용 범위` 순서로 읽음

**Step 6: 문서 커밋**

```bash
git add SPEC.md DESIGN.md PLANNING.md
git diff --cached --check
git commit -m "docs: update cadence policy and controls"
```

## 완료 기준

- 모든 템포 소비자가 동일한 `TempoPlan`을 사용한다.
- 기준 180에서 91~95 BPM 곡이 182~190 SPM 원곡 속도로 재생된다.
- 원곡 속도 후보는 기준 케이던스 아래로 내려가지 않는다.
- 1.25배를 넘는 곡은 실제로 큰 배속이 적용되기 전에 차단된다.
- 원곡 BPM이 목표 케이던스에 맞춰 자동 변경되지 않는다.
- 메인 UI, 메트로놈과 Live Activity가 같은 실제 케이던스를 표시한다.
- 재생 컨트롤이 중복 렌더링되지 않는다.
- 메트로놈 설정이 재시작 후 복원된다.
- 전체 test와 clean build가 성공한다.
