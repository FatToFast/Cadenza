# PR 3: 큐 자동 전진 + Prefetch + 잠금화면 Remote Control

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Apple Music 플레이리스트를 선택하면 전체 트랙이 큐에 적재되고 자동 전진 재생. 백그라운드 + 잠금화면 컨트롤. `targetBPM` 하나로 일관 연습.

**Architecture:** `PlaybackQueue` @MainActor class가 advance/skip/remove/prefetch 상태 머신 + `AudioManager.trackEndedSubject` 구독. `expectedRate > rateHardCap`면 unplayable 마킹 후 스킵. 연속 실패 3회면 큐 클리어. `QueueBanner`/`QueueListView` UI. `UIBackgroundModes: audio` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.

**Tech Stack:** Swift 6 MainActor, Combine, SwiftUI, MediaPlayer (Now Playing/Remote).

**Dependencies:** PR 1, PR 2 머지. PR 0 성공.

---

## File Structure

**Create**: `Cadenza/Models/PlaybackQueue.swift`, `Cadenza/Views/Components/QueueBanner.swift`, `Cadenza/Views/Components/QueueListView.swift`, `Cadenza/Services/NowPlayingCenter.swift`, `Tests/PlaybackQueueTests.swift`, `Tests/PlaybackQueueRateCapTests.swift`, `Tests/PlaybackQueueFailureTests.swift`, `Tests/TestHelpers.swift`

**Modify**: `project.yml` (+`INFOPLIST_KEY_UIBackgroundModes: audio`), `Cadenza/Utilities/Constants.swift` (rate 상수), `Cadenza/Models/AudioManager.swift` (`AudioManagerProtocol` 도입), `Cadenza/Services/AssetResolver.swift` (`AssetResolving` 프로토콜), `Cadenza/Views/AppleMusicLibraryView.swift` (플레이리스트 로드 콜백), `Cadenza/Views/PlayerView.swift` (Queue 주입 + Banner)

## 공통 빌드·테스트

```bash
xattr -cr Cadenza Tests && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project Cadenza.xcodeproj -scheme CadenzaTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/CadenzaDerivedData-pr3 test 2>&1 | tail -10
```

---

## Task 1: Rate 상수

**Files**: Modify `Cadenza/Utilities/Constants.swift`

- [ ] **Step 1**: 추가:
  ```swift
  enum PlaybackRateLimits {
      static let warningThreshold: Double = 1.6
      static let hardCap: Double = 2.0
  }
  ```
- [ ] **Step 2**: `Tests/PlaybackRateLimitsTests.swift`에 threshold < hardCap 검증.
- [ ] **Step 3**: 테스트 통과 확인 → 커밋 `feat(playback): rate warning/hard-cap constants`.

## Task 2: 의존성 프로토콜 (테스트 주입용)

**Files**: Modify `Cadenza/Models/AudioManager.swift`, `Cadenza/Services/AssetResolver.swift`

- [ ] **Step 1**: `AudioManagerProtocol`과 `AssetResolving` 프로토콜 선언 + 기존 타입 adopt:
  ```swift
  protocol AudioManagerProtocol: AnyObject {
      var targetBPM: Double { get set }
      var originalBPM: Double { get }
      var trackDuration: TimeInterval { get }
      var trackEndedSubject: PassthroughSubject<Void, Never> { get }
      var playbackEndBehavior: PlaybackEndBehavior { get set }
      func loadFile(url: URL, analysisIdentity: String) async
      func play()
      func pause()
  }
  extension AudioManager: AudioManagerProtocol {}

  protocol AssetResolving: Sendable {
      func resolve(_ item: QueueItem) async throws -> URL
      func reset() async
  }
  extension AssetResolver: AssetResolving {}
  ```
- [ ] **Step 2**: 빌드 통과 → 기존 40+개 테스트 회귀 없음 확인.
- [ ] **Step 3**: 커밋 `refactor(audio): extract AudioManagerProtocol + AssetResolving for injection`.

## Task 3: PlaybackQueue 기본 상태 머신 + advance

**Files**: Create `Cadenza/Models/PlaybackQueue.swift`, `Tests/TestHelpers.swift`, `Tests/PlaybackQueueTests.swift`

- [ ] **Step 1**: `Tests/TestHelpers.swift`:
  ```swift
  import Combine
  @testable import Cadenza

  extension QueueItem {
      static func fileStub(_ name: String, unplayable: UnplayableReason? = nil) -> QueueItem {
          QueueItem(id: name, title: name, artist: nil,
              source: .file(URL(fileURLWithPath: "/tmp/\(name).wav")),
              unplayableReason: unplayable)
      }
  }

  @MainActor
  final class MockAudio: AudioManagerProtocol {
      var targetBPM: Double = 120
      var originalBPM: Double = 120
      var trackDuration: TimeInterval = 180
      var loadedURLs: [URL] = []
      let trackEndedSubject = PassthroughSubject<Void, Never>()
      var playbackEndBehavior: PlaybackEndBehavior = .loop
      func loadFile(url: URL, analysisIdentity: String) async { loadedURLs.append(url) }
      func play() {}; func pause() {}
      func simulateTrackEnded() { trackEndedSubject.send(()) }
  }

  struct MockResolver: AssetResolving {
      func resolve(_ item: QueueItem) async throws -> URL {
          guard case .file(let u) = item.source else { throw NSError(domain: "x", code: 0) }
          return u
      }
      func reset() async {}
  }
  ```
- [ ] **Step 2**: 테스트 `Tests/PlaybackQueueTests.swift`:
  ```swift
  @MainActor
  final class PlaybackQueueTests: XCTestCase {
      func testAdvanceSkipsUnplayable() async {
          let audio = MockAudio()
          let q = PlaybackQueue(audio: audio, resolver: MockResolver())
          await q.load(items: [.fileStub("A"), .fileStub("B", unplayable: .cloudOnly), .fileStub("C")])
          await q.playCurrent()
          audio.simulateTrackEnded()
          try? await Task.sleep(nanoseconds: 50_000_000)
          XCTAssertEqual(q.currentIndex, 2)
      }
      func testAdvanceAtEndMarksInactive() async {
          let q = PlaybackQueue(audio: MockAudio(), resolver: MockResolver())
          await q.load(items: [.fileStub("A")])
          await q.playCurrent()
          await q.advance()
          XCTAssertFalse(q.isActive)
      }
      func testRemoveCurrentAdvancesToNext() async {
          let audio = MockAudio()
          let q = PlaybackQueue(audio: audio, resolver: MockResolver())
          await q.load(items: [.fileStub("A"), .fileStub("B")])
          await q.playCurrent()
          // remove(at: currentIndex)가 내부적으로 playCurrent 호출 — 별도 수동 호출 불필요
          await q.remove(at: q.currentIndex)
          XCTAssertEqual(audio.loadedURLs.last?.lastPathComponent, "B.wav")
      }
      func testRemoveLastCurrentDeactivatesButKeepsPriorItems() async {
          let q = PlaybackQueue(audio: MockAudio(), resolver: MockResolver())
          await q.load(items: [.fileStub("A"), .fileStub("B")])
          await q.playCurrent()
          await q.advance()            // currentIndex = 1
          await q.remove(at: 1)        // 현재(마지막) 제거 — [A]만 남음, 비활성화
          XCTAssertEqual(q.items.count, 1)
          XCTAssertEqual(q.items.first?.title, "A")
          XCTAssertFalse(q.isActive)
      }
  }
  ```
- [ ] **Step 3**: PlaybackQueue 구현:
  ```swift
  import Combine
  import Foundation

  @MainActor
  final class PlaybackQueue: ObservableObject {
      @Published private(set) var items: [QueueItem] = []
      @Published private(set) var currentIndex: Int = 0
      @Published private(set) var isActive: Bool = false
      private let audio: AudioManagerProtocol
      private let resolver: AssetResolving
      private var trackEndSub: AnyCancellable?
      private var consecutiveFailures: Int = 0
      private var prefetchTask: Task<Void, Never>?

      init(audio: AudioManagerProtocol, resolver: AssetResolving) {
          self.audio = audio; self.resolver = resolver
          trackEndSub = audio.trackEndedSubject.sink { [weak self] _ in
              Task { @MainActor in await self?.advance() }
          }
      }

      func load(items: [QueueItem]) async {
          self.items = items; self.currentIndex = 0; self.isActive = !items.isEmpty
          self.consecutiveFailures = 0
          audio.playbackEndBehavior = .notify
      }

      func playCurrent() async {
          guard isActive, items.indices.contains(currentIndex) else { return }
          let item = items[currentIndex]
          if item.unplayableReason != nil { await advance(); return }
          do {
              let url = try await resolver.resolve(item)
              await audio.loadFile(url: url, analysisIdentity: item.analysisCacheIdentity)
              let rate = audio.targetBPM / max(audio.originalBPM, 1)
              if rate > PlaybackRateLimits.hardCap {
                  items[currentIndex].unplayableReason = .rateOutOfRange(required: rate)
                  await advance()
                  return
              }
              audio.play()
              consecutiveFailures = 0
              prefetchNextIfPossible()
          } catch {
              items[currentIndex].unplayableReason = .decodingFailed
              consecutiveFailures += 1
              if consecutiveFailures >= 3 { clear(); return }
              await advance()
          }
      }

      func advance() async {
          while true {
              currentIndex += 1
              if currentIndex >= items.count {
                  isActive = false
                  audio.playbackEndBehavior = .loop
                  return
              }
              if items[currentIndex].unplayableReason == nil { break }
          }
          await playCurrent()
      }

      func previous() async {
          guard currentIndex > 0 else { return }
          currentIndex -= 1
          await playCurrent()
      }

      func jump(to index: Int) async {
          guard items.indices.contains(index) else { return }
          currentIndex = index
          await playCurrent()
      }

      func remove(at index: Int) async {
          guard items.indices.contains(index) else { return }
          let wasCurrent = (index == currentIndex)
          items.remove(at: index)
          if index < currentIndex { currentIndex -= 1 }
          if items.isEmpty { clear(); return }
          guard wasCurrent else { return }
          // 현재 재생 중이던 항목을 제거 — currentIndex는 이제 "다음 곡"을 가리킴.
          // 끝을 넘어섰다면 큐 종료, 아니면 즉시 로드·재생.
          if currentIndex >= items.count {
              isActive = false
              audio.playbackEndBehavior = .loop
              return
          }
          await playCurrent()
      }

      func clear() {
          items.removeAll(); isActive = false; consecutiveFailures = 0
          prefetchTask?.cancel()
          audio.playbackEndBehavior = .loop
          Task { await resolver.reset() }
      }

      private func prefetchNextIfPossible() {
          let next = currentIndex + 1
          guard items.indices.contains(next),
                items[next].unplayableReason == nil else { return }
          let item = items[next]
          prefetchTask?.cancel()
          prefetchTask = Task.detached(priority: .utility) { [resolver] in
              guard !Task.isCancelled else { return }
              guard let url = try? await resolver.resolve(item) else { return }
              _ = try? BeatAlignmentAnalyzer.loadOrAnalyze(
                  url: url, cacheIdentity: item.analysisCacheIdentity, expectedBPM: nil)
          }
      }
  }
  ```
- [ ] **Step 4**: 테스트 — 이전 대비 +3 통과.
- [ ] **Step 5**: 커밋 `feat(queue): PlaybackQueue state machine with advance/skip/remove/prefetch`.

## Task 4: Rate cap 테스트

**Files**: Create `Tests/PlaybackQueueRateCapTests.swift`

- [ ] **Step 1**:
  ```swift
  @MainActor
  final class PlaybackQueueRateCapTests: XCTestCase {
      func testSkipsWhenRateExceedsHardCap() async {
          let audio = MockAudio(); audio.targetBPM = 120
          // MockAudio.loadFile이 originalBPM을 변경하도록 테스트용 override 지원 필요
          // 간단히 테스트 직전 audio.originalBPM = 50 설정
          audio.originalBPM = 50
          let q = PlaybackQueue(audio: audio, resolver: MockResolver())
          await q.load(items: [.fileStub("slow"), .fileStub("ok")])
          await q.playCurrent()
          if case .rateOutOfRange = q.items[0].unplayableReason {} else { XCTFail() }
          XCTAssertEqual(q.currentIndex, 1)
      }
  }
  ```
- [ ] **Step 2**: 테스트 통과 확인 → 커밋 `test(queue): rate hardcap skip behavior`.

## Task 5: 연속 실패 큐 클리어 테스트

**Files**: Create `Tests/PlaybackQueueFailureTests.swift`

- [ ] **Step 1**:
  ```swift
  @MainActor
  final class PlaybackQueueFailureTests: XCTestCase {
      func testThreeFailuresClearQueue() async {
          struct Failing: AssetResolving {
              func resolve(_: QueueItem) async throws -> URL { throw NSError(domain: "f", code: 1) }
              func reset() async {}
          }
          let q = PlaybackQueue(audio: MockAudio(), resolver: Failing())
          await q.load(items: [.fileStub("a"), .fileStub("b"), .fileStub("c"), .fileStub("d")])
          await q.playCurrent()
          XCTAssertTrue(q.items.isEmpty)
          XCTAssertFalse(q.isActive)
      }
  }
  ```
- [ ] **Step 2**: 테스트 통과 → 커밋 `test(queue): clear after three consecutive failures`.

## Task 6: UIBackgroundModes

**Files**: Modify `project.yml`

- [ ] **Step 1**: `targets.Cadenza.settings.base`에:
  ```yaml
  INFOPLIST_KEY_UIBackgroundModes: audio
  ```
- [ ] **Step 2**: `xcodegen generate` → 빌드 성공. 실기기 수동: 재생 중 잠금 → 오디오 지속.
- [ ] **Step 3**: 커밋 `chore(project): enable background audio via INFOPLIST_KEY_UIBackgroundModes`.

## Task 7: NowPlayingCenter + Remote Commands

**Files**: Create `Cadenza/Services/NowPlayingCenter.swift`

- [ ] **Step 1**: 구현:
  ```swift
  import MediaPlayer

  @MainActor
  final class NowPlayingCenter {
      func update(title: String?, artist: String?, duration: TimeInterval,
                  elapsed: TimeInterval, rate: Double) {
          var info: [String: Any] = [:]
          info[MPMediaItemPropertyTitle] = title ?? ""
          info[MPMediaItemPropertyArtist] = artist ?? ""
          info[MPMediaItemPropertyPlaybackDuration] = duration
          info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
          info[MPNowPlayingInfoPropertyPlaybackRate] = rate
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
      func clear() { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }

      func bindRemoteCommands(
          onPlay: @MainActor @escaping () -> Void,
          onPause: @MainActor @escaping () -> Void,
          onNext: @MainActor @escaping () -> Void,
          onPrevious: @MainActor @escaping () -> Void
      ) {
          let c = MPRemoteCommandCenter.shared()
          c.playCommand.addTarget { _ in Task { @MainActor in onPlay() }; return .success }
          c.pauseCommand.addTarget { _ in Task { @MainActor in onPause() }; return .success }
          c.nextTrackCommand.addTarget { _ in Task { @MainActor in onNext() }; return .success }
          c.previousTrackCommand.addTarget { _ in Task { @MainActor in onPrevious() }; return .success }
      }
  }
  ```
- [ ] **Step 2**: PlaybackQueue에 `private let nowPlaying = NowPlayingCenter()` 필드. `init`에서 `bindRemoteCommands` 호출. `playCurrent` 성공 경로에서 `nowPlaying.update(...)` 호출. `clear()`에서 `nowPlaying.clear()`.
- [ ] **Step 3**: 실기기 수동 — 잠금화면 메타/원격 제어 동작.
- [ ] **Step 4**: 커밋 `feat(queue): lock screen metadata + remote commands`.

## Task 8: QueueBanner + QueueListView

**Files**: Create `Cadenza/Views/Components/QueueBanner.swift`, `Cadenza/Views/Components/QueueListView.swift`

- [ ] **Step 1**: QueueBanner:
  ```swift
  struct QueueBanner: View {
      @ObservedObject var queue: PlaybackQueue
      @State private var expanded = false
      var body: some View {
          HStack {
              VStack(alignment: .leading) {
                  Text(queue.items[safe: queue.currentIndex]?.title ?? "")
                  if let n = queue.items[safe: queue.currentIndex + 1] {
                      Text("다음: \(n.title)").font(.caption).foregroundStyle(.secondary)
                  }
              }
              Spacer()
              Button { Task { await queue.advance() } } label: { Image(systemName: "forward.fill") }
          }
          .padding().contentShape(Rectangle())
          .onTapGesture { expanded = true }
          .sheet(isPresented: $expanded) { QueueListView(queue: queue) }
      }
  }
  extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
  ```
- [ ] **Step 2**: QueueListView:
  ```swift
  struct QueueListView: View {
      @ObservedObject var queue: PlaybackQueue
      @Environment(\.dismiss) private var dismiss
      var body: some View {
          NavigationStack {
              List {
                  ForEach(queue.items) { item in
                      let idx = queue.items.firstIndex(of: item) ?? 0
                      row(for: item, idx: idx).onTapGesture {
                          Task { await queue.jump(to: idx); dismiss() }
                      }
                  }
                  .onDelete { indexSet in
                      Task {
                          for idx in indexSet.sorted(by: >) { await queue.remove(at: idx) }
                      }
                  }
              }
              .navigationTitle("큐")
              .toolbar { ToolbarItem(placement: .cancellationAction) {
                  Button("닫기") { dismiss() } } }
          }
      }
      @ViewBuilder func row(for item: QueueItem, idx: Int) -> some View {
          HStack {
              if idx == queue.currentIndex {
                  Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
              }
              VStack(alignment: .leading) {
                  Text(item.title)
                  if let a = item.artist { Text(a).font(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              if let r = item.unplayableReason { Image(systemName: icon(r)).foregroundStyle(.secondary) }
          }
      }
      func icon(_ r: QueueItem.UnplayableReason) -> String {
          switch r {
          case .cloudOnly: return "icloud"
          case .rateOutOfRange: return "gauge.with.dots.needle.67percent"
          default: return "exclamationmark.triangle"
          }
      }
  }
  ```
- [ ] **Step 3**: 빌드 성공 확인 → 커밋 `feat(ui): QueueBanner + QueueListView`.

## Task 9: PlayerView에 Queue 주입 + AM 피커 플레이리스트 로드

**Files**: Modify `Cadenza/Views/AppleMusicLibraryView.swift`, `Cadenza/Views/PlayerView.swift`

- [ ] **Step 1**: `AppleMusicLibraryView`에 `onPlaylistPicked: ([QueueItem]) -> Void` 콜백 추가. 플레이리스트 디스클로저 옆에 "이 플레이리스트 재생" 버튼:
  ```swift
  Button("이 플레이리스트 재생") {
      Task {
          let items = try await library.fetchItems(in: playlist.id)
          onPlaylistPicked(items); dismiss()
      }
  }
  ```
- [ ] **Step 2**: PlayerView에서 Queue를 `@StateObject`로 보유, AM 피커 콜백에 연결:
  ```swift
  AppleMusicLibraryView(
      library: musicLibrary,
      onTrackPicked: { Task { await handleSingleTrack($0) } },
      onPlaylistPicked: { items in
          Task { await queue.load(items: items); await queue.playCurrent() }
      })
  ```
  `queue.isActive`이면 PlayerView 하단에 `QueueBanner(queue: queue)`.
- [ ] **Step 3**: 빌드·시뮬레이터 기본 동작.
- [ ] **Step 4**: **실기기 E2E**:
  - [ ] "이 플레이리스트 재생" → 자동 전진 재생 (3곡 이상)
  - [ ] targetBPM 조정 → rate > 2.0 트랙 스킵
  - [ ] cloud-only 스킵 + QueueBanner에 다음 곡 표시 정상
  - [ ] 큐 배너 탭 → 리스트 확장, 스와이프 삭제·임의 트랙 점프
  - [ ] 잠금화면 메타/원격 제어
  - [ ] 백그라운드 전환 후 자동 전진 지속
  - [ ] 복귀 시 prefetch 덕에 즉시 재생
  - [ ] 파일 피커 단일 곡 경로 회귀 없음
- [ ] **Step 5**: 커밋 `feat(ui): integrate PlaybackQueue into PlayerView with playlist load path`.

## Exit Criteria

- [ ] 유닛 테스트 전체 통과 (PR 2의 47개 + PR 3 신규 ≈ 53개)
- [ ] 실기기 E2E 체크리스트 전부 PASS
- [ ] 파일 피커 단일 곡 재생·루프·BPM 변경 회귀 없음
- [ ] 설계 문서(`docs/plans/2026-04-19-apple-music-queue-design.md`)의 "에러 매트릭스" 전 항목 동작 관찰됨

## Rollback

각 Task 독립 커밋. prefetch 관련 회귀 시 Task 5 commit revert하고 Queue에서 `prefetchNextIfPossible` 호출 제거 — 자동 전진 자체는 작동. Remote command 루프 발생 시 Task 7 revert 후 잠금화면 기능만 지연 도입.
