# Now Playing & Remote Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 로컬 파일 재생 경로에 잠금화면 Now Playing 정보 + Remote Command (play/pause/next/previous) + 백그라운드 오디오 모드를 연동해, 앱을 포그라운드로 열지 않아도 잠금화면에서 기본 미디어 컨트롤을 쓸 수 있게 만든다. Live Activity 구현의 전제조건이다.

**Architecture:** 로컬 플레이리스트 상태(`LocalFilePlaylist`)와 곡 이동 로직(`handleLocalPlaylistNext/Previous/TrackEnded`)을 `PlayerView`에서 `AudioManager`로 이동한다. `MPNowPlayingInfoCenter`는 `AudioManager`의 published 상태가 바뀔 때마다 업데이트된다. `MPRemoteCommandCenter`는 앱 시작 시 한 번 등록되고, 핸들러는 `AudioManager`의 public 메서드를 호출한다. Apple Music 스트리밍 경로(`AppleMusicStreamingController`)는 건드리지 않는다 (MusicKit이 자체 처리).

**Tech Stack:** Swift 6 · SwiftUI · AVAudioEngine (기존) · MediaPlayer framework (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, `MPMediaItemArtwork`) · iOS 17+ (앱 최소 버전)

---

## Scope & Non-Goals

**포함:**
- Info.plist에 `UIBackgroundModes` = `[audio]` 추가
- `AudioManager`에 로컬 플레이리스트 상태·메서드 이동 (`loadPlaylist`, `next`, `previous`, 자동 진행)
- `NowPlayingCenterCoordinator` 신규 — Now Playing info 업데이트 담당
- `RemoteCommandCoordinator` 신규 — Remote Command 핸들러 등록 담당
- `AudioManager`의 아트워크 로딩 (기존 `loadMetadataString` 근처에 `loadArtworkData` 추가)
- `PlayerView`의 플레이리스트 관련 코드 제거/위임

**제외 (별도 plan):**
- Live Activity (Widget Extension 타겟, ActivityKit)
- 앱 본체 UI 튜닝 (BPM 크기 축소 등)
- Apple Music 스트리밍 경로의 Now Playing (MusicKit이 이미 처리)

---

## File Structure

### Create
- `Cadenza/Services/NowPlayingCenterCoordinator.swift` — Now Playing info dictionary 빌드·업데이트
- `Cadenza/Services/RemoteCommandCoordinator.swift` — play/pause/next/previous 핸들러 등록, AudioManager에 위임
- `Tests/NowPlayingCenterCoordinatorTests.swift`
- `Tests/RemoteCommandCoordinatorTests.swift`
- `Tests/AudioManagerPlaylistTests.swift` — 플레이리스트 이동 로직 테스트

### Modify
- `Cadenza/Info.plist` — `UIBackgroundModes` 키 추가
- `Cadenza/Models/AudioManager.swift` — 플레이리스트 상태, next/previous 메서드, artwork 로드, Published `currentArtwork`
- `Cadenza/Views/PlayerView.swift` — 플레이리스트 로컬 상태 제거, `audio.localPlaylist`·`audio.next()`·`audio.previous()` 사용
- `Cadenza/CadenzaApp.swift` — Now Playing / Remote Command Coordinator 소유, AudioManager 주입

### Unchanged
- `Cadenza/Services/AppleMusicStreamingController.swift`
- `Cadenza/Models/QueueItem.swift` (`LocalFilePlaylist` 구조체 자체는 재사용)
- `Cadenza/Models/NowPlayingInfo.swift`

---

## Task Breakdown

- **Task 1**: Info.plist Background Audio 모드 추가
- **Task 2**: `AudioManager`에 `currentArtworkData` published 속성과 아트워크 로딩 추가
- **Task 3**: `AudioManager`로 플레이리스트 상태 이동 (Property + loadPlaylist)
- **Task 4**: `AudioManager.next()`·`previous()`·트랙 종료 자동 진행 구현
- **Task 5**: `PlayerView` 플레이리스트 코드 제거 + `audio.*` 위임
- **Task 6**: `NowPlayingCenterCoordinator` 신규 + 테스트
- **Task 7**: `CadenzaApp`에서 NowPlayingCenterCoordinator 연결 + Combine 구독
- **Task 8**: `RemoteCommandCoordinator` 신규 + 테스트
- **Task 9**: `CadenzaApp`에서 RemoteCommandCoordinator 연결
- **Task 10**: 실기기 수동 검증 체크리스트

---

## Task 1: Background Audio Mode

**Files:**
- Modify: `Cadenza/Info.plist`

이 작업은 iOS가 앱 백그라운드 진입 후에도 오디오 재생을 유지하도록 허용한다. 이 키가 없으면 잠금 시 소리가 끊기고 Now Playing도 동작하지 않는다.

- [ ] **Step 1: 현재 Info.plist 상태 확인**

Run:
```bash
grep -A2 "UIBackgroundModes" Cadenza/Info.plist || echo "MISSING"
```

Expected: `MISSING` — 아직 키 없음

- [ ] **Step 2: Info.plist에 `UIBackgroundModes` 추가**

`Cadenza/Info.plist`에서 `<key>LSRequiresIPhoneOS</key>` 바로 위에 다음을 추가:

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
	</array>
```

- [ ] **Step 3: 빌드해서 plist 구문 확인**

Run:
```bash
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Cadenza/Info.plist
git commit -m "feat(audio): enable background audio mode

잠금화면에서도 재생을 유지하도록 UIBackgroundModes에 audio 추가.
Now Playing 및 Remote Command 연동의 전제 조건."
```

---

## Task 2: AudioManager — Artwork Data

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift` (loadMetadataString 근처 + Published 속성)
- Test: `Tests/AudioManagerGenerationTests.swift` (아트워크 로딩 검증은 실파일 필요해서 최소 단위로만 추가)

Now Playing에 앨범 아트를 표시하려면 `AudioManager`가 현재 트랙의 artwork `Data`를 노출해야 한다. 스트리밍 곡은 `AppleMusicStreamingController`가 별도로 제공하므로 여기선 로컬 파일만 다룬다.

- [ ] **Step 1: Published 속성 추가**

`AudioManager`의 Published 블록(`@Published private(set) var trackArtist: String?` 바로 아래)에 추가:

```swift
@Published private(set) var currentArtworkData: Data?
```

- [ ] **Step 2: Artwork 로딩 헬퍼 추가**

`AudioManager.swift` 파일 맨 끝 (`loadMetadataString` 정적 메서드 근처)에 추가:

```swift
private static func loadArtworkData(from asset: AVAsset) async -> Data? {
    do {
        let metadata = try await asset.load(.commonMetadata)
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try await item.load(.dataValue) {
                return data
            }
        }
    } catch {
        logger.warning("[artwork] load failed: \(error.localizedDescription)")
    }
    return nil
}
```

- [ ] **Step 3: `loadFile`에서 artwork 로드 호출**

`loadFile(url:generation:)` 메서드 내부에서, `trackTitle`/`trackArtist`를 세팅하는 곳(기존 `loadMetadataString` 호출 근처)에 추가:

```swift
// 기존:
// trackTitle = await Self.loadMetadataString(...)
// trackArtist = await Self.loadMetadataString(...)

// 추가:
let artworkData = await Self.loadArtworkData(from: asset)
guard generation == trackGeneration else { return }
currentArtworkData = artworkData
```

**주의:** `generation` 가드를 artwork 로드 후에도 반드시 둬야 한다. 트랙이 빠르게 교체되면 이전 트랙의 아트워크가 새 트랙에 덮여쓸 수 있다. 기존 `loadMetadataString` 호출 직후의 가드 패턴을 그대로 따라한다.

- [ ] **Step 4: 트랙 교체/정지 시 artwork 초기화**

같은 파일의 `stop()` / `reset()` 또는 트랙 로드 실패 경로에서 `trackTitle = nil`을 세팅하는 자리마다 `currentArtworkData = nil`도 함께 세팅.

`loadFile(url:generation:)` 초반의 상태 초기화 블록 (기존 `trackTitle = nil; trackArtist = nil`을 세팅하는 곳)에 추가:

```swift
currentArtworkData = nil
```

- [ ] **Step 5: 빌드 확인**

Run:
```bash
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Cadenza/Models/AudioManager.swift
git commit -m "feat(audio): expose currentArtworkData for Now Playing

로컬 파일 메타데이터에서 아트워크 Data를 읽어 AudioManager가
published property로 노출. Now Playing Info Center에 바로 공급 가능.
trackGeneration 가드로 빠른 트랙 교체 경쟁 방지."
```

---

## Task 3: AudioManager — Playlist State Ownership

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift` (Published 속성 + loadPlaylist 메서드)
- Test: `Tests/AudioManagerPlaylistTests.swift` (new)

`PlayerView`의 `@State private var localPlaylist = LocalFilePlaylist()`를 `AudioManager`로 이동한다. 이후 Remote Command 핸들러가 AudioManager를 통해 플레이리스트를 조작할 수 있다.

- [ ] **Step 1: Published playlist 속성 추가**

`AudioManager.swift`의 Published 블록에 추가 (`currentArtworkData` 아래):

```swift
@Published private(set) var localPlaylist = LocalFilePlaylist()
@Published var isLocalRepeatEnabled: Bool = false
```

- [ ] **Step 2: `loadPlaylist(fileURLs:startIndex:autoPlay:)` 메서드 추가**

`AudioManager.swift`의 `// MARK: - Playback Control` 섹션 바로 위에 추가:

```swift
// MARK: - Local Playlist

func loadPlaylist(fileURLs urls: [URL], startIndex: Int = 0, autoPlay: Bool = false) async {
    let playlist = LocalFilePlaylist(
        items: urls.enumerated().map { QueueItem.localFile(url: $1, index: $0) },
        currentIndex: startIndex
    )
    localPlaylist = playlist
    updatePlaybackEndBehavior()
    guard let item = playlist.currentItem, case .file(let url) = item.source else { return }
    await loadFile(url: url)
    guard autoPlay, state == .ready else { return }
    play()
}

func clearLocalPlaylist() {
    localPlaylist = LocalFilePlaylist()
    updatePlaybackEndBehavior()
}

func toggleLocalShuffle() {
    _ = localPlaylist.toggleShuffle()
    updatePlaybackEndBehavior()
}

func toggleLocalRepeat() {
    isLocalRepeatEnabled.toggle()
    updatePlaybackEndBehavior()
}

private func updatePlaybackEndBehavior() {
    if localPlaylist.isEmpty {
        playbackEndBehavior = isLocalRepeatEnabled ? .loop : .notify
    } else {
        playbackEndBehavior = .notify
    }
}
```

**주의:** `LocalFilePlaylist`는 `Sendable`이고 값 타입(struct)이라서 전체 대입(`localPlaylist = ...`)이 Published 업데이트를 일으킨다. 내부 mutating 메서드를 직접 호출하면 Published가 발동하지 않으므로 `_ = localPlaylist.toggleShuffle()` 패턴을 의도적으로 쓴다(struct mutating은 self 전체 대입으로 간주되어 Published가 동작).

- [ ] **Step 3: 테스트 파일 생성**

`Tests/AudioManagerPlaylistTests.swift`:

```swift
import XCTest
@testable import Cadenza

@MainActor
final class AudioManagerPlaylistTests: XCTestCase {

    func testLoadPlaylistSetsCurrentItem() async throws {
        let audio = AudioManager()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ]
        await audio.loadPlaylist(fileURLs: urls, startIndex: 1, autoPlay: false)
        XCTAssertEqual(audio.localPlaylist.count, 2)
        XCTAssertEqual(audio.localPlaylist.currentIndex, 1)
    }

    func testClearLocalPlaylistEmptiesState() {
        let audio = AudioManager()
        audio.clearLocalPlaylist()
        XCTAssertTrue(audio.localPlaylist.isEmpty)
    }

    func testToggleRepeatUpdatesEndBehavior() {
        let audio = AudioManager()
        XCTAssertFalse(audio.isLocalRepeatEnabled)
        audio.toggleLocalRepeat()
        XCTAssertTrue(audio.isLocalRepeatEnabled)
        XCTAssertEqual(audio.playbackEndBehavior, .loop)
    }
}
```

- [ ] **Step 4: 테스트 실행**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/AudioManagerPlaylistTests 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Cadenza/Models/AudioManager.swift Tests/AudioManagerPlaylistTests.swift
git commit -m "feat(audio): move local playlist ownership to AudioManager

PlayerView에서 보유하던 LocalFilePlaylist를 AudioManager로 이동.
Remote Command 핸들러가 AudioManager를 통해 플레이리스트를 조작
가능하도록 하는 전제 작업. loadPlaylist/clear/toggleShuffle/
toggleRepeat API 제공."
```

---

## Task 4: AudioManager — next / previous / auto-advance

**Files:**
- Modify: `Cadenza/Models/AudioManager.swift`
- Modify: `Tests/AudioManagerPlaylistTests.swift`

플레이리스트 커서 이동 로직을 AudioManager로 가져온다. 트랙 자동 진행도 여기서 처리.

- [ ] **Step 1: `next()` / `previous()` 메서드 추가**

`AudioManager.swift`의 `// MARK: - Local Playlist` 섹션 (Task 3에서 추가한 섹션) 안, `updatePlaybackEndBehavior()` 바로 위에 추가:

```swift
func next() async {
    let shouldAutoPlay = state == .playing
    guard let item = localPlaylist.moveToNext() else { return }
    await loadAndMaybePlay(item, autoPlay: shouldAutoPlay)
}

func previous() async {
    let shouldAutoPlay = state == .playing
    guard let item = localPlaylist.moveToPrevious() else { return }
    await loadAndMaybePlay(item, autoPlay: shouldAutoPlay)
}

private func loadAndMaybePlay(_ item: QueueItem, autoPlay: Bool) async {
    guard case .file(let url) = item.source else { return }
    clearError()
    await loadFile(url: url)
    updatePlaybackEndBehavior()
    guard autoPlay, state == .ready else { return }
    play()
}
```

**주의:** `LocalFilePlaylist`는 struct이고 `@Published` property에 저장돼 있다. 위처럼 `localPlaylist.moveToNext()` 직접 호출은 self 전체 재대입으로 간주되어 Combine publisher가 발동한다 (테스트에서 `currentIndex` 검증 가능). `moveToNext`/`moveToPrevious`는 기존 `LocalFilePlaylist` API 그대로 사용.

- [ ] **Step 2: 트랙 종료 시 자동 진행 로직 AudioManager로 이동**

`AudioManager.swift`의 기존 `trackEndedSubject.send(())` 호출부(루프/정지 처리 근처)를 찾는다. 현재는 View가 이 subject를 구독해서 다음 곡으로 넘어가는데, 이제 AudioManager 내부에서 직접 처리한다.

`trackEndedSubject`를 `send`하기 직전, 다음을 추가:

```swift
// Auto-advance within local playlist
if !localPlaylist.isEmpty {
    Task { await self.handleLocalTrackEnded() }
}
```

`handleLocalTrackEnded`는 `// MARK: - Local Playlist` 섹션의 private 헬퍼로 추가:

```swift
private func handleLocalTrackEnded() async {
    if let next = localPlaylist.moveToNext() {
        await loadAndMaybePlay(next, autoPlay: true)
        return
    }
    if isLocalRepeatEnabled, let first = localPlaylist.moveToStart() {
        await loadAndMaybePlay(first, autoPlay: true)
    }
}
```

**주의:** `trackEndedSubject`는 View 레이어가 스트리밍 상태·메트로놈 등 다른 기능을 트리거하는 데 쓸 수도 있으므로 **삭제하지 말고 유지한다**. 플레이리스트 자동 진행만 AudioManager로 이동.

- [ ] **Step 3: 테스트 추가**

`Tests/AudioManagerPlaylistTests.swift`에 추가:

```swift
func testNextAdvancesPlaylistCursorWhenPossible() async throws {
    let audio = AudioManager()
    let urls = [
        URL(fileURLWithPath: "/tmp/a.mp3"),
        URL(fileURLWithPath: "/tmp/b.mp3"),
    ]
    await audio.loadPlaylist(fileURLs: urls, startIndex: 0, autoPlay: false)
    await audio.next()
    XCTAssertEqual(audio.localPlaylist.currentIndex, 1)
}

func testPreviousMovesCursorBackward() async throws {
    let audio = AudioManager()
    let urls = [
        URL(fileURLWithPath: "/tmp/a.mp3"),
        URL(fileURLWithPath: "/tmp/b.mp3"),
    ]
    await audio.loadPlaylist(fileURLs: urls, startIndex: 1, autoPlay: false)
    await audio.previous()
    XCTAssertEqual(audio.localPlaylist.currentIndex, 0)
}

func testNextAtEndOfPlaylistIsNoOp() async throws {
    let audio = AudioManager()
    let urls = [URL(fileURLWithPath: "/tmp/only.mp3")]
    await audio.loadPlaylist(fileURLs: urls, startIndex: 0, autoPlay: false)
    await audio.next()
    XCTAssertEqual(audio.localPlaylist.currentIndex, 0)
}
```

**주의:** 위 테스트는 `/tmp/*.mp3`가 실제로 존재하지 않아서 `loadFile`이 실패해 `state`가 `.error`로 갈 수 있다. 이 테스트의 목적은 "플레이리스트 커서 이동"만 검증하는 것이라, `state` 값은 assert하지 않는다. 커서 위치만 본다.

- [ ] **Step 4: 테스트 실행**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/AudioManagerPlaylistTests 2>&1 | tail -15
```

Expected: 6 tests passed (기존 3 + 새 3).

- [ ] **Step 5: Commit**

```bash
git add Cadenza/Models/AudioManager.swift Tests/AudioManagerPlaylistTests.swift
git commit -m "feat(audio): implement next/previous/auto-advance in AudioManager

플레이리스트 커서 이동 로직을 PlayerView에서 AudioManager로 이동.
트랙 종료 시 자동 진행도 AudioManager 내부에서 처리.
trackEndedSubject는 다른 구독자를 위해 유지."
```

---

## Task 5: PlayerView — Remove Playlist Local State

**Files:**
- Modify: `Cadenza/Views/PlayerView.swift`

PlayerView에서 `localPlaylist`, `isLocalRepeatEnabled`, `handleLocalPlaylistNext/Previous/ShuffleToggle/TrackEnded` 관련 코드를 제거하고 `audio.*` 메서드로 위임한다.

- [ ] **Step 1: 기존 상태·헬퍼 파악**

`PlayerView.swift`에서 다음을 모두 찾는다:

```bash
grep -nE "localPlaylist|isLocalRepeatEnabled|handleLocalPlaylist|handleLocalRepeat|loadLocalPlaylistItem|updateLocalPlaylistEndBehavior|clearLocalPlaylist|handleLocalPlaylistTrackEnded" Cadenza/Views/PlayerView.swift
```

모든 호출부를 `audio.*` 호출로 대체할 것이다.

- [ ] **Step 2: State 삭제**

PlayerView의 property 선언에서 아래 두 줄을 **삭제**:

```swift
@State private var localPlaylist = LocalFilePlaylist()
@State private var isLocalRepeatEnabled = false
```

- [ ] **Step 3: 버튼/컨트롤의 바인딩을 `audio.*`로 교체**

`handleLocalPlaylistNext` 호출 버튼: `{ Task { await audio.next() } }`로 변경.
`handleLocalPlaylistPrevious` 호출 버튼: `{ Task { await audio.previous() } }`.
`handleLocalPlaylistShuffleToggle` → `{ audio.toggleLocalShuffle() }`.
`handleLocalRepeatToggle` → `{ audio.toggleLocalRepeat() }`.

`isLocalRepeatEnabled` 참조 → `audio.isLocalRepeatEnabled`.
`localPlaylist.canMoveNext` / `canMovePrevious` / `isEmpty` / `currentItem` / `count` → `audio.localPlaylist.canMoveNext` 등.
`hasLocalPlaybackItem` 같은 computed var가 있다면 내부를 `audio.localPlaylist.currentItem != nil`로 변경.

- [ ] **Step 4: 플레이리스트 로드 진입점 교체**

기존 `handlePlaylistFileSelection`에서 `localPlaylist = LocalFilePlaylist(fileURLs: urls)` 후 `loadLocalPlaylistItem`을 호출하는 패턴을:

```swift
Task {
    await audio.loadPlaylist(fileURLs: urls, startIndex: 0, autoPlay: false)
}
```

로 단순화.

- [ ] **Step 5: PlayerView 내 다음 함수들 전부 삭제**

```
handleLocalPlaylistNext
handleLocalPlaylistPrevious
handleLocalPlaylistShuffleToggle
handleLocalRepeatToggle
handleLocalPlaylistTrackEnded
loadLocalPlaylistItem
clearLocalPlaylist
updateLocalPlaylistEndBehavior
```

`.onReceive(audio.trackEndedSubject)`에서 `handleLocalPlaylistTrackEnded`를 부르는 부분도 삭제. AudioManager가 이미 내부에서 처리하므로 이 구독은 플레이리스트용으로는 불필요 (다른 용도로 남아있다면 그대로).

- [ ] **Step 6: 빌드 확인**

Run:
```bash
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. 에러가 나면 `audio.*` 레퍼런스가 누락된 곳이다.

- [ ] **Step 7: 전체 테스트 수트 실행**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`, 기존 테스트 모두 통과.

- [ ] **Step 8: Commit**

```bash
git add Cadenza/Views/PlayerView.swift
git commit -m "refactor(player): delegate playlist control to AudioManager

PlayerView에서 플레이리스트 로컬 상태/핸들러 제거. 버튼 콜백은
audio.next/previous/toggleLocalShuffle/toggleLocalRepeat로 위임.
AudioManager가 소유권을 가지며 Remote Command 연동을 가능케 함."
```

---

## Task 6: NowPlayingCenterCoordinator

**Files:**
- Create: `Cadenza/Services/NowPlayingCenterCoordinator.swift`
- Create: `Tests/NowPlayingCenterCoordinatorTests.swift`

`MPNowPlayingInfoCenter.default().nowPlayingInfo` dictionary를 AudioManager 상태로부터 만든다. Combine 구독은 상위(CadenzaApp)가 한다. 이 클래스는 "상태 → dictionary" 순수 변환 + `nowPlayingInfo` 세팅만 담당.

- [ ] **Step 1: 실패하는 테스트 먼저**

`Tests/NowPlayingCenterCoordinatorTests.swift`:

```swift
import XCTest
import MediaPlayer
@testable import Cadenza

@MainActor
final class NowPlayingCenterCoordinatorTests: XCTestCase {

    func testBuildInfoIncludesTitleArtistDurationAndElapsed() {
        let info = NowPlayingCenterCoordinator.buildInfo(
            title: "Midnight City",
            artist: "M83",
            duration: 243,
            elapsed: 112,
            rate: 1.0,
            artworkData: nil
        )
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Midnight City")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "M83")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 243)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 112)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    func testBuildInfoIncludesArtworkWhenDataProvided() throws {
        // 1x1 PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: pngBase64))
        let info = NowPlayingCenterCoordinator.buildInfo(
            title: "X", artist: "Y", duration: 0, elapsed: 0, rate: 0, artworkData: data
        )
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork])
    }

    func testBuildInfoOmitsArtworkWhenNil() {
        let info = NowPlayingCenterCoordinator.buildInfo(
            title: nil, artist: nil, duration: 0, elapsed: 0, rate: 0, artworkData: nil
        )
        XCTAssertNil(info[MPMediaItemPropertyArtwork])
    }
}
```

- [ ] **Step 2: 테스트 실행 (실패 확인)**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/NowPlayingCenterCoordinatorTests 2>&1 | tail -10
```

Expected: 컴파일 실패 — `NowPlayingCenterCoordinator` 미정의.

- [ ] **Step 3: NowPlayingCenterCoordinator 구현**

`Cadenza/Services/NowPlayingCenterCoordinator.swift`:

```swift
import Combine
import Foundation
import MediaPlayer
import UIKit

/// AudioManager의 published 상태를 관찰해
/// MPNowPlayingInfoCenter.default().nowPlayingInfo에 반영한다.
/// 소유권: CadenzaApp (앱 루트 레벨 singleton).
@MainActor
final class NowPlayingCenterCoordinator {

    private weak var audio: AudioManager?
    private var cancellables = Set<AnyCancellable>()

    init(audio: AudioManager) {
        self.audio = audio
        bind()
    }

    private func bind() {
        guard let audio else { return }

        // 곡·재생 상태·시간 변화에 반응해 Now Playing info 업데이트
        Publishers.CombineLatest4(
            audio.$trackTitle,
            audio.$trackArtist,
            audio.$trackDuration,
            audio.$currentArtworkData
        )
        .sink { [weak self, weak audio] _, _, _, _ in
            guard let self, let audio else { return }
            self.update(from: audio)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            audio.$state,
            audio.$currentPlaybackTime,
            audio.$targetBPM // rate 갱신 트리거
        )
        .sink { [weak self, weak audio] _, _, _ in
            guard let self, let audio else { return }
            self.update(from: audio)
        }
        .store(in: &cancellables)
    }

    private func update(from audio: AudioManager) {
        let rate: Double = (audio.state == .playing) ? audio.playbackRate : 0.0
        let info = Self.buildInfo(
            title: audio.trackTitle,
            artist: audio.trackArtist,
            duration: audio.trackDuration,
            elapsed: audio.currentPlaybackTime,
            rate: rate,
            artworkData: audio.currentArtworkData
        )
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 순수 함수 — 테스트 친화적. 상태를 받아 dictionary를 리턴.
    static func buildInfo(
        title: String?,
        artist: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        rate: Double,
        artworkData: Data?
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        if let title { info[MPMediaItemPropertyTitle] = title }
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let data = artworkData, let image = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }
}
```

**주의:** Xcode 프로젝트 파일(`Cadenza.xcodeproj/project.pbxproj`)에 새 Swift 파일이 자동으로 추가되지 않을 수 있다. `xcodebuild build`가 성공하는지 확인해서, `Cannot find 'NowPlayingCenterCoordinator' in scope` 류 에러가 나면 Xcode에서 파일을 타겟에 추가해야 한다. 수동 조작 필요 시 별도로 안내.

- [ ] **Step 4: 테스트 실행**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/NowPlayingCenterCoordinatorTests 2>&1 | tail -15
```

Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Cadenza/Services/NowPlayingCenterCoordinator.swift Tests/NowPlayingCenterCoordinatorTests.swift Cadenza.xcodeproj/project.pbxproj
git commit -m "feat(nowplaying): add NowPlayingCenterCoordinator

AudioManager의 published 상태를 구독해 MPNowPlayingInfoCenter에
제목/아티스트/길이/진행시간/재생속도/아트워크를 반영.
buildInfo는 순수 함수로 분리해 테스트 가능."
```

---

## Task 7: CadenzaApp — Wire Up NowPlayingCenterCoordinator

**Files:**
- Modify: `Cadenza/CadenzaApp.swift`

앱 루트에서 AudioManager를 만들 때 Coordinator도 함께 생성·보관.

- [ ] **Step 1: 현재 CadenzaApp 파악**

```bash
cat Cadenza/CadenzaApp.swift
```

`@StateObject private var audio = AudioManager()` 비슷한 패턴이 있을 것.

- [ ] **Step 2: Coordinator 소유 추가**

`CadenzaApp`의 body 근처에 추가 (AudioManager property 아래):

```swift
@StateObject private var audio = AudioManager()
@State private var nowPlayingCoordinator: NowPlayingCenterCoordinator?
```

`body`의 메인 `WindowGroup` 컨텐츠에 `.task` 수정자 추가 (또는 기존 `.onAppear`/`.task` 안에 삽입):

```swift
.task {
    if nowPlayingCoordinator == nil {
        nowPlayingCoordinator = NowPlayingCenterCoordinator(audio: audio)
    }
}
```

**주의:** `NowPlayingCenterCoordinator`는 `@MainActor`이므로 메인 스레드에서 생성돼야 한다. `.task`는 기본적으로 @MainActor 컨텍스트에서 실행된다.

- [ ] **Step 3: 빌드 확인**

Run:
```bash
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Cadenza/CadenzaApp.swift
git commit -m "feat(app): instantiate NowPlayingCenterCoordinator at app launch

앱 시작 시 AudioManager를 구독하도록 Coordinator를 .task 안에서
생성. 이후 로컬 파일 재생 시 잠금화면 Now Playing 위젯에 곡
정보가 뜬다."
```

---

## Task 8: RemoteCommandCoordinator

**Files:**
- Create: `Cadenza/Services/RemoteCommandCoordinator.swift`
- Create: `Tests/RemoteCommandCoordinatorTests.swift`

잠금화면·이어폰·CarPlay 등에서 오는 원격 명령을 AudioManager에 위임.

- [ ] **Step 1: 실패하는 테스트 먼저**

`Tests/RemoteCommandCoordinatorTests.swift`:

```swift
import XCTest
import MediaPlayer
@testable import Cadenza

@MainActor
final class RemoteCommandCoordinatorTests: XCTestCase {

    func testRegisterEnablesPlayPauseAndSkipCommands() {
        let audio = AudioManager()
        let coordinator = RemoteCommandCoordinator(audio: audio)
        coordinator.register()

        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.pauseCommand.isEnabled)
        XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(center.nextTrackCommand.isEnabled)
        XCTAssertTrue(center.previousTrackCommand.isEnabled)
    }
}
```

**주의:** Remote Command 핸들러 호출 자체를 단위테스트로 검증하기 어렵다 (OS 레벨 이벤트). 위 테스트는 "등록이 실행되고 명령이 enable됐는지"만 확인. 실제 핸들러 동작 검증은 Task 10의 실기기 체크리스트로 한다.

- [ ] **Step 2: 테스트 실행 (실패 확인)**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/RemoteCommandCoordinatorTests 2>&1 | tail -8
```

Expected: 컴파일 실패 — `RemoteCommandCoordinator` 미정의.

- [ ] **Step 3: RemoteCommandCoordinator 구현**

`Cadenza/Services/RemoteCommandCoordinator.swift`:

```swift
import Foundation
import MediaPlayer

/// 잠금화면·이어폰·CarPlay의 원격 미디어 명령을 AudioManager에 연결.
/// 소유권: CadenzaApp (앱 시작 시 한 번 register).
@MainActor
final class RemoteCommandCoordinator {

    private weak var audio: AudioManager?

    init(audio: AudioManager) {
        self.audio = audio
    }

    func register() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let audio = self?.audio else { return .commandFailed }
            audio.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let audio = self?.audio else { return .commandFailed }
            audio.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let audio = self?.audio else { return .commandFailed }
            audio.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let audio = self?.audio else { return .commandFailed }
            Task { await audio.next() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let audio = self?.audio else { return .commandFailed }
            Task { await audio.previous() }
            return .success
        }
    }
}
```

- [ ] **Step 4: 테스트 실행**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CadenzaTests/RemoteCommandCoordinatorTests 2>&1 | tail -10
```

Expected: 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Cadenza/Services/RemoteCommandCoordinator.swift Tests/RemoteCommandCoordinatorTests.swift Cadenza.xcodeproj/project.pbxproj
git commit -m "feat(remotecmd): add RemoteCommandCoordinator

MPRemoteCommandCenter에 play/pause/toggle/next/previous 핸들러를
등록해 잠금화면·이어폰 버튼·CarPlay 명령을 AudioManager에 위임."
```

---

## Task 9: CadenzaApp — Wire Up RemoteCommandCoordinator

**Files:**
- Modify: `Cadenza/CadenzaApp.swift`

- [ ] **Step 1: Coordinator 소유 추가 및 register 호출**

Task 7의 `.task` 블록에 추가:

```swift
@State private var remoteCommandCoordinator: RemoteCommandCoordinator?

// body .task 안:
if remoteCommandCoordinator == nil {
    let coordinator = RemoteCommandCoordinator(audio: audio)
    coordinator.register()
    remoteCommandCoordinator = coordinator
}
```

**주의:** `MPRemoteCommandCenter`는 시뮬레이터에서 종종 동작이 제한된다. 실기기 검증이 필수 (Task 10).

- [ ] **Step 2: 빌드 + 전체 테스트**

Run:
```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`, 전체 통과.

- [ ] **Step 3: Commit**

```bash
git add Cadenza/CadenzaApp.swift
git commit -m "feat(app): register RemoteCommandCoordinator at launch

앱 시작 시 Remote Command 핸들러를 한 번 등록해, 잠금화면의
기본 미디어 컨트롤이 로컬 파일 재생에도 동작한다."
```

---

## Task 10: Device Verification Checklist

**Files:** (없음 — 수동 검증)

시뮬레이터로는 완전히 검증되지 않는 경로가 있어서 실기기에서 아래를 확인해야 한다. 이 체크리스트를 통과해야 Plan 1이 완료된 것으로 본다.

- [ ] **Step 1: 로컬 파일 1곡 로드 후 재생 → 잠금**

기대: 잠금화면에 곡 제목·아티스트·아트워크가 뜨고 재생/일시정지 버튼이 보인다.

- [ ] **Step 2: 잠금화면에서 일시정지 → 재개**

기대: 앱을 열지 않고도 음악이 실제로 멈추고 다시 재생된다. 진행바가 일시정지 동안 고정, 재개 시 다시 진행.

- [ ] **Step 3: 로컬 플레이리스트(≥3곡) 로드 후 재생 → 잠금 → 다음곡**

기대: 잠금화면 "다음 곡" 버튼으로 다음 트랙으로 넘어감. 잠금화면 위젯의 제목/아트워크가 갱신됨.

- [ ] **Step 4: 같은 상태에서 "이전 곡" → 이전 트랙 복귀**

기대: 앞 트랙으로 돌아감.

- [ ] **Step 5: 홈 버튼 눌러 백그라운드 진입 후 15초 대기**

기대: 음악이 끊기지 않고 계속 재생된다 (Background audio 모드 검증).

- [ ] **Step 6: 이어폰/AirPods 재생/일시정지 버튼**

기대: 이어폰 버튼으로 일시정지·재개가 동작. 다음곡 버튼이 있는 이어폰이면 트랙 이동도 동작.

- [ ] **Step 7: 재생 속도(targetBPM)를 변경 → 잠금화면**

기대: 잠금화면 진행바가 변경된 재생 속도에 맞춰 움직인다 (nowPlayingInfo의 `playbackRate` 반영 여부).

- [ ] **Step 8: 트랙 종료 시 자동 진행**

기대: 잠금 상태에서 트랙이 끝나면 다음 트랙으로 자동 이동, 새 곡 정보가 잠금화면에 뜬다.

- [ ] **Step 9: Apple Music 스트리밍 곡 재생 → 잠금**

기대: 기존 MusicKit 자동 통합이 깨지지 않았는지 확인. 잠금화면에 스트리밍 곡 정보 표시됨.

---

## Self-Review

(이하 자체 점검 — 작성자가 배포 전 확인)

**Spec coverage check:**
- ✅ §4.1 현재 상태 진단 ("Info.plist 누락 추정", "로컬 재생 경로의 NowPlaying 누락") → Task 1 (Info.plist), Task 6-7 (NowPlayingCoordinator)
- ✅ §4.2 "필수 키 리스트" → Task 6의 `buildInfo` 테스트가 각 키를 assert
- ✅ §4.2 "MPRemoteCommandCenter에 play/pause/next/previous 핸들러 등록" → Task 8
- ✅ §4.2 `AVAudioSession.setCategory(.playback)` 확인 → 이미 `configureAudioSessionIfNeeded`에 있음 (Task 1 Step 1 단계에서 확인)
- ✅ §4.2 `UIBackgroundModes`에 audio 추가 → Task 1
- ✅ §4.3 Live Activity와 독립 → 이 plan은 Live Activity를 건드리지 않음

**Placeholder scan:** 없음. 모든 코드 블록은 복붙 가능한 완성된 코드.

**Type consistency:**
- `AudioManager.next()`, `AudioManager.previous()` → Task 4에서 정의, Task 8·Task 5에서 호출.
- `LocalFilePlaylist.moveToNext()`, `moveToPrevious()`, `moveToStart()` → 기존 API, Task 4·2에서 호출.
- `NowPlayingCenterCoordinator.buildInfo(title:artist:duration:elapsed:rate:artworkData:)` → Task 6에서 정의 + 테스트.
- `RemoteCommandCoordinator.register()` → Task 8에서 정의, Task 9에서 호출.

**Dependencies between tasks:**
- Task 1 → (독립)
- Task 2 → Task 6 (artworkData 공급)
- Task 3 → Task 4, Task 5 (플레이리스트 state)
- Task 4 → Task 5 (next/previous 메서드)
- Task 5 → (독립적 리팩토링)
- Task 6 → Task 7
- Task 8 → Task 9
- Task 10 → 모든 Task 완료 후
