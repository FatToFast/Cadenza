# PR 1: 큐 인프라 리팩터 (외부 동작 변경 없음)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 추후 Apple Music 큐 기능 인프라 타입·훅을 `AudioManager`에 도입하되 **기존 외부 동작 불변**. 기존 30개 테스트 회귀 없이 통과.

**Architecture:** 신규 타입(`QueueItem`, `NowPlayingInfo`, `PlaybackEndBehavior`) 추가, `scheduleLoop` completion을 `trackGeneration` 카운터로 stale drop, `trackEndedSubject` 발행 경로 준비(`.loop` 기본값 유지), `PlayerView`가 `currentNowPlayingInfo`만 읽도록 전환.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Combine, XCTest

**Dependencies:** PR 0 spike 결과와 무관, 독립 진행 가능.

---

## File Structure

**Create**: `Cadenza/Models/QueueItem.swift`, `NowPlayingInfo.swift`, `PlaybackEndBehavior.swift`, `Tests/QueueItemTests.swift`, `Tests/NowPlayingInfoTests.swift`, `Tests/AudioManagerGenerationTests.swift`

**Modify**: `Cadenza/Models/AudioManager.swift` (trackGeneration, loadFile overload, scheduleLoop guard, trackEndedSubject, currentNowPlayingInfo), `Cadenza/Views/PlayerView.swift`

---

## 공통 빌드·테스트 명령

```bash
xattr -cr Cadenza Tests
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project Cadenza.xcodeproj -scheme CadenzaTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/CadenzaDerivedData-pr1 test 2>&1 | tail -10
```

성공 기준: `** TEST SUCCEEDED **`.

---

## Task 1a: OriginalBPMSource `Sendable` 선언 추가 (prerequisite)

**Files**: Modify `Cadenza/Utilities/PlaybackModels.swift`

`NowPlayingInfo`가 `Sendable`을 채택하려면 포함 필드인 `OriginalBPMSource`도 `Sendable` 이어야 Swift 6 strict concurrency에서 통과.

- [ ] **Step 1**: 기존 `enum OriginalBPMSource: Equatable {` 선언에 `Sendable` 추가:
  ```swift
  enum OriginalBPMSource: Sendable, Equatable {
  ```
- [ ] **Step 2**: 빌드·테스트 — 30개 유지(의미 변경 없음).
- [ ] **Step 3**: 커밋 `refactor(models): OriginalBPMSource conforms to Sendable`.

## Task 1: PlaybackEndBehavior enum

**Files**: Create `Cadenza/Models/PlaybackEndBehavior.swift`

- [ ] **Step 1**: 파일 생성:

```swift
import Foundation

/// 곡 끝 도달 시 AudioManager의 동작.
/// - loop: 기존 동작, 같은 파일을 재스케줄.
/// - notify: trackEndedSubject로 이벤트 발행. 재스케줄 없음. 큐 모드.
enum PlaybackEndBehavior: Sendable, Equatable { case loop, notify }
```

- [ ] **Step 2**: `xcodegen generate` 후 테스트 — 30개 통과 유지.
- [ ] **Step 3**: 커밋 `feat(audio): add PlaybackEndBehavior enum`.

## Task 2: QueueItem (file 소스 only)

**Files**: Create `Cadenza/Models/QueueItem.swift`, `Tests/QueueItemTests.swift`

- [ ] **Step 1: 테스트**

```swift
// Tests/QueueItemTests.swift
import XCTest
@testable import Cadenza

final class QueueItemTests: XCTestCase {
    func testFileSourceURL() {
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        let item = QueueItem(id: "x", title: "s", artist: nil, source: .file(url))
        if case .file(let u) = item.source { XCTAssertEqual(u, url) } else { XCTFail() }
    }

    func testAnalysisCacheIdentityUsesFilePath() {
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        let item = QueueItem(id: "x", title: "s", artist: nil, source: .file(url))
        XCTAssertEqual(item.analysisCacheIdentity, "file-\(url.path)")
    }

    func testUnplayableReasonNilByDefault() {
        let item = QueueItem(id: "x", title: "s", artist: nil,
                             source: .file(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertNil(item.unplayableReason)
    }
}
```

- [ ] **Step 2**: 빌드 — 컴파일 FAIL (`QueueItem` 미정의).
- [ ] **Step 3: 구현**

```swift
// Cadenza/Models/QueueItem.swift
import Foundation

struct QueueItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let source: Source
    var unplayableReason: UnplayableReason?

    enum Source: Sendable, Equatable {
        case file(URL)
        // .appleMusic는 PR 2에서 추가
    }

    enum UnplayableReason: Sendable, Equatable {
        case cloudOnly, decodingFailed, subscriptionLapsed
        case rateOutOfRange(required: Double)
    }

    var analysisCacheIdentity: String {
        switch source {
        case .file(let url): return "file-\(url.path)"
        }
    }
}
```

- [ ] **Step 4**: 테스트 — 33개 통과.
- [ ] **Step 5**: 커밋 `feat(queue): QueueItem value type with file source`.

## Task 3: NowPlayingInfo

**Files**: Create `Cadenza/Models/NowPlayingInfo.swift`, `Tests/NowPlayingInfoTests.swift`

- [ ] **Step 1: 테스트**

```swift
import XCTest
@testable import Cadenza

final class NowPlayingInfoTests: XCTestCase {
    func testConstructs() {
        let info = NowPlayingInfo(title: "S", artist: "A", originalBPM: 128,
            originalBPMSource: .metadata, playbackProgress: 0.5,
            playbackDuration: 180, queueContext: nil)
        XCTAssertEqual(info.title, "S")
        XCTAssertEqual(info.originalBPM, 128)
    }
    func testEmpty() {
        XCTAssertNil(NowPlayingInfo.empty.title)
        XCTAssertEqual(NowPlayingInfo.empty.originalBPM, BPMRange.originalDefault)
    }
    func testQueueContext() {
        let ctx = NowPlayingInfo.QueueContext(currentIndex: 2, totalCount: 5, nextTitle: "N")
        XCTAssertEqual(ctx.currentIndex, 2)
    }
}
```

- [ ] **Step 2**: 빌드 FAIL 확인.
- [ ] **Step 3: 구현**

```swift
import Foundation

struct NowPlayingInfo: Sendable, Equatable {
    let title: String?
    let artist: String?
    let originalBPM: Double
    let originalBPMSource: OriginalBPMSource
    let playbackProgress: Double
    let playbackDuration: TimeInterval
    let queueContext: QueueContext?

    struct QueueContext: Sendable, Equatable {
        let currentIndex: Int
        let totalCount: Int
        let nextTitle: String?
    }

    static let empty = NowPlayingInfo(title: nil, artist: nil,
        originalBPM: BPMRange.originalDefault, originalBPMSource: .assumedDefault,
        playbackProgress: 0, playbackDuration: 0, queueContext: nil)
}
```

- [ ] **Step 4**: 테스트 — 36개 통과.
- [ ] **Step 5**: 커밋 `feat(playback): NowPlayingInfo value type`.

## Task 4: trackGeneration + loadFile 오버로드

**Files**: Modify `Cadenza/Models/AudioManager.swift`

- [ ] **Step 1**: private 영역(163행 근처)에 `private var trackGeneration: Int = 0` 추가.

- [ ] **Step 2**: 기존 `func loadFile(url: URL) async` 를 두 개로 분리:

```swift
func loadFile(url: URL) async {
    trackGeneration += 1
    let gen = trackGeneration
    await loadFile(url: url, generation: gen)
}

func loadFile(url: URL, generation: Int) async {
    self.trackGeneration = generation
    // ...기존 loadFile 본문 그대로 이어붙임...
}
```

기존 본문을 그대로 두 번째 함수 안에 이동하되, 최상단에 `trackGeneration = generation` 한 줄 추가. 기존 `defer`와 reset 블록 모두 유지.

- [ ] **Step 3**: 테스트 — 36개 그대로 통과, 외부 동작 불변.
- [ ] **Step 4**: 커밋 `refactor(audio): trackGeneration counter + loadFile overload`.

## Task 5: scheduleLoop completion에 generation 가드

**Files**: Modify `Cadenza/Models/AudioManager.swift` — `scheduleLoop` 함수

- [ ] **Step 1**: completion closure를 교체. 핵심: generation capture + 체크:

```swift
let capturedGeneration = self.trackGeneration
playerNode.scheduleSegment(
    file, startingFrame: startFrame,
    frameCount: AVAudioFrameCount(framesRemaining), at: nil
) { [weak self] in
    Task { @MainActor in
        guard let self else { return }
        guard self.trackGeneration == capturedGeneration else { return } // stale drop
        guard self.state == .playing else {
            self.isScheduling = false
            self.hasScheduledPlayback = false
            return
        }
        self.currentPlaybackTime = 0
        self.isScheduling = false
        self.hasScheduledPlayback = false
        self.currentScheduledStartFrame = 0
        self.scheduleLoop()
        if self.metronomeEnabled {
            self.startMetronome(alignedToSourceTime: 0, anchorHostTime: mach_absolute_time())
        }
        logger.debug("Loop: re-scheduled (gen=\(capturedGeneration))")
    }
}
```

- [ ] **Step 2**: 테스트 — 36개 통과 유지.
- [ ] **Step 3**: 커밋 `refactor(audio): guard scheduleLoop completion against stale generation`.

## Task 6: trackEndedSubject + playbackEndBehavior 분기

**Files**: Modify `Cadenza/Models/AudioManager.swift`, Create `Tests/AudioManagerGenerationTests.swift`

- [ ] **Step 1**: `import Combine` 확인. private 영역:

```swift
let trackEndedSubject = PassthroughSubject<Void, Never>()
@Published var playbackEndBehavior: PlaybackEndBehavior = .loop
```

- [ ] **Step 2**: scheduleLoop completion의 재스케줄 블록 교체:

```swift
switch self.playbackEndBehavior {
case .loop:
    self.scheduleLoop()
    if self.metronomeEnabled {
        self.startMetronome(alignedToSourceTime: 0, anchorHostTime: mach_absolute_time())
    }
case .notify:
    self.trackEndedSubject.send(())
    logger.debug("Track ended, notify (gen=\(capturedGeneration))")
}
```

- [ ] **Step 3: 테스트**

```swift
import XCTest
import Combine
@testable import Cadenza

@MainActor
final class AudioManagerGenerationTests: XCTestCase {
    func testDefaultBehaviorIsLoop() {
        XCTAssertEqual(AudioManager().playbackEndBehavior, .loop)
    }
    func testBehaviorMutable() {
        let a = AudioManager()
        a.playbackEndBehavior = .notify
        XCTAssertEqual(a.playbackEndBehavior, .notify)
    }
    func testTrackEndedSubjectEmits() {
        let a = AudioManager()
        var n = 0
        let c = a.trackEndedSubject.sink { n += 1 }
        a.trackEndedSubject.send(())
        XCTAssertEqual(n, 1)
        c.cancel()
    }
}
```

- [ ] **Step 4**: 테스트 — 39개 통과.
- [ ] **Step 5**: 커밋 `feat(audio): trackEndedSubject + playbackEndBehavior branch`.

## Task 7: currentNowPlayingInfo computed property

**Files**: Modify `Cadenza/Models/AudioManager.swift`, `Tests/AudioManagerGenerationTests.swift`

- [ ] **Step 1**: AudioManager 본문에:

```swift
var currentNowPlayingInfo: NowPlayingInfo {
    NowPlayingInfo(
        title: trackTitle, artist: trackArtist,
        originalBPM: originalBPM, originalBPMSource: originalBPMSource,
        playbackProgress: trackDuration > 0 ? currentPlaybackTime / trackDuration : 0,
        playbackDuration: trackDuration,
        queueContext: nil
    )
}
```

- [ ] **Step 2**: `AudioManagerGenerationTests`에 추가:

```swift
func testDefaultNowPlayingEmpty() {
    let info = AudioManager().currentNowPlayingInfo
    XCTAssertNil(info.title)
    XCTAssertEqual(info.originalBPM, BPMRange.originalDefault)
    XCTAssertNil(info.queueContext)
}
```

- [ ] **Step 3**: 테스트 — 40개 통과.
- [ ] **Step 4**: 커밋 `feat(audio): expose currentNowPlayingInfo`.

## Task 8: PlayerView가 currentNowPlayingInfo 경유 표시

**Files**: Modify `Cadenza/Views/PlayerView.swift`

- [ ] **Step 1**: `PlayerView` 본문에 헬퍼:

```swift
private var nowPlaying: NowPlayingInfo { audio.currentNowPlayingInfo }
```

- [ ] **Step 2**: 기존에 `audio.trackTitle`, `audio.trackArtist`, `audio.originalBPM`, `audio.originalBPMSource`, `audio.playbackProgress`, `audio.trackDuration`를 **표시 용도로** 읽던 모든 부분을 `nowPlaying.title` 등으로 교체. 재생 컨트롤 호출(`audio.play()`, `audio.pause()`, `audio.seek(...)`)은 그대로 `audio` 사용.

- [ ] **Step 3**: 빌드:

```bash
xattr -cr Cadenza Tests
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/CadenzaDerivedData-pr1 build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4**: 시뮬레이터 수동 스모크 — 샘플 프리셋 로드, 재생, BPM 슬라이더, 루프 모두 정상.

- [ ] **Step 5**: 전체 테스트 최종 실행 — 40개 통과.

- [ ] **Step 6**: 커밋 `refactor(ui): PlayerView binds NowPlayingInfo for display`.

## Exit Criteria

- [ ] 기존 30개 테스트 회귀 없음
- [ ] 신규 10개 테스트(QueueItem 3, NowPlayingInfo 3, AudioManagerGeneration 4) 통과
- [ ] 시뮬레이터 수동 스모크 통과 (재생·루프·BPM 변경)
- [ ] `AudioManager`에 `trackGeneration`, `trackEndedSubject`, `playbackEndBehavior`, `currentNowPlayingInfo` 존재
- [ ] `PlayerView`가 개별 @Published 필드를 표시 용도로 직접 참조하지 않음
- [ ] `.loop` 기본값으로 기존 파일 피커 무한 루프 유지

## Rollback

각 커밋 독립. 문제 발생 시 `git revert <sha>`. Task 5가 회귀 원인이면 이전 completion closure로 복원, 이후 태스크 보류.
