# PR 2: Apple Music 보관함 읽기·단일 곡 로드

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자가 Apple Music 보관함에서 플레이리스트를 열람하고 **한 곡을 선택해 Cadenza에 로드**. 자동 전진은 PR 3.

**Architecture:** `MusicLibrary` 프로토콜(MPMediaLibrary + MPMediaQuery), `AssetResolver` actor(assetURL → AVAssetReader → tmp WAV + N+1 eviction), `BeatAlignmentAnalyzer.cacheIdentity` 오버로드로 persistentID 기반 캐시, 2-step NavigationStack 피커.

**Tech Stack:** MediaPlayer, AVFoundation, SwiftUI, Swift 6 actor

**Dependencies:** PR 0 성공, PR 1 머지.

---

## File Structure

**Create**: `Cadenza/Services/MusicLibraryService.swift`, `Cadenza/Services/AssetResolver.swift`, `Cadenza/Models/PlaylistSummary.swift`, `Cadenza/Views/AppleMusicLibraryView.swift`, `Tests/QueueItemAppleMusicTests.swift`, `Tests/BeatAlignmentCacheIdentityTests.swift`, `Tests/MusicLibraryServiceTests.swift`, `Tests/AssetResolverEvictionTests.swift`

**Modify**: `project.yml`, `Cadenza/Utilities/BeatAlignmentAnalyzer.swift`, `Cadenza/Models/QueueItem.swift`, `Cadenza/Models/AudioManager.swift`, `Cadenza/Views/PlayerView.swift`

## 공통 빌드·테스트

```bash
xattr -cr Cadenza Tests && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project Cadenza.xcodeproj -scheme CadenzaTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/CadenzaDerivedData-pr2 test 2>&1 | tail -10
```

---

## Task 1: project.yml 권한 키

**Files**: Modify `project.yml`

- [ ] **Step 1**: `targets.Cadenza.settings.base`에:
  ```yaml
  INFOPLIST_KEY_NSAppleMusicUsageDescription: "메트로놈에 맞춰 재생할 Apple Music 보관함 곡을 불러옵니다."
  ```
- [ ] **Step 2**: `xcodegen generate` → 시뮬레이터 빌드 성공 확인.
- [ ] **Step 3**: 커밋 `chore(project): add NSAppleMusicUsageDescription via INFOPLIST_KEY`.

## Task 2: QueueItem에 `.appleMusic` 소스

**Files**: Modify `Cadenza/Models/QueueItem.swift`, Create `Tests/QueueItemAppleMusicTests.swift`

- [ ] **Step 1**: 테스트 작성
  ```swift
  import XCTest
  @testable import Cadenza

  final class QueueItemAppleMusicTests: XCTestCase {
      func testPersistentID() {
          let item = QueueItem(id: "am-42", title: "S", artist: "A",
              source: .appleMusic(persistentID: 42, assetURL: URL(string: "ipod-library://item/42")))
          if case .appleMusic(let pid, _) = item.source { XCTAssertEqual(pid, 42) } else { XCTFail() }
      }
      func testIdentityStableAcrossURLChange() {
          let a = QueueItem(id: "x", title: "s", artist: nil,
              source: .appleMusic(persistentID: 99, assetURL: URL(string: "ipod-library://item/99?v=1")))
          let b = QueueItem(id: "x", title: "s", artist: nil,
              source: .appleMusic(persistentID: 99, assetURL: URL(string: "ipod-library://item/99?v=2")))
          XCTAssertEqual(a.analysisCacheIdentity, b.analysisCacheIdentity)
          XCTAssertEqual(a.analysisCacheIdentity, "applemusic-99")
      }
  }
  ```
- [ ] **Step 2**: 빌드 FAIL 확인(`.appleMusic` case 없음).
- [ ] **Step 3**: `QueueItem.Source`에 `case appleMusic(persistentID: UInt64, assetURL: URL?)` 추가. `analysisCacheIdentity` switch에 `case .appleMusic(let pid, _): return "applemusic-\(pid)"`.
- [ ] **Step 4**: 테스트 — 42개(PR 1의 40 + 2) 통과.
- [ ] **Step 5**: 커밋 `feat(queue): QueueItem supports appleMusic source`.

## Task 3: BeatAlignmentAnalyzer cacheIdentity 오버로드

**Files**: Modify `Cadenza/Utilities/BeatAlignmentAnalyzer.swift`, Create `Tests/BeatAlignmentCacheIdentityTests.swift`

- [ ] **Step 1**: 테스트 작성 (test helper로 빈 WAV 파일 생성 후 동일 identity로 두 번 호출, 두 번째는 cache hit):
  ```swift
  import XCTest
  import AVFoundation
  @testable import Cadenza

  final class BeatAlignmentCacheIdentityTests: XCTestCase {
      func testIdentityBasedHit() throws {
          let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: dir) }
          let urlA = dir.appendingPathComponent("a.wav")
          let urlB = dir.appendingPathComponent("b.wav")
          try writeSilenceWAV(to: urlA, seconds: 3)
          try writeSilenceWAV(to: urlB, seconds: 3)
          let first = try BeatAlignmentAnalyzer.loadOrAnalyze(
              url: urlA, cacheIdentity: "test-1", expectedBPM: 120)
          let second = try BeatAlignmentAnalyzer.loadOrAnalyze(
              url: urlB, cacheIdentity: "test-1", expectedBPM: 120)
          XCTAssertEqual(second.cacheStatus, .hit)
      }
      private func writeSilenceWAV(to url: URL, seconds: Double) throws {
          let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
          let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
          let frames = AVAudioFrameCount(44_100 * seconds)
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
          buf.frameLength = frames
          try file.write(from: buf)
      }
  }
  ```
- [ ] **Step 2**: 빌드 FAIL (오버로드 없음).
- [ ] **Step 3**: BeatAlignmentAnalyzer.swift에 오버로드 추가:
  ```swift
  static func loadOrAnalyze(url: URL, cacheIdentity: String, expectedBPM: Double?)
  throws -> BeatAlignmentLoadResult {
      let file = try AVAudioFile(forReading: url)
      if let cached = loadCachedAnalysis(forIdentity: cacheIdentity) {
          return BeatAlignmentLoadResult(analysis: cached, cacheStatus: .hit)
      }
      let fingerprint = makeFingerprint(for: url, file: file)
      guard let analysis = try analyze(fileURL: url, file: file,
          expectedBPM: expectedBPM, fingerprint: fingerprint) else {
          return BeatAlignmentLoadResult(analysis: nil, cacheStatus: .none)
      }
      try save(analysis: analysis, forIdentity: cacheIdentity)
      return BeatAlignmentLoadResult(analysis: analysis, cacheStatus: .miss)
  }
  private static func loadCachedAnalysis(forIdentity id: String) -> BeatAlignmentAnalysis? {
      guard let url = try? cacheURL(forIdentity: id),
            let data = try? Data(contentsOf: url) else { return nil }
      return try? JSONDecoder().decode(BeatAlignmentAnalysis.self, from: data)
  }
  private static func save(analysis: BeatAlignmentAnalysis, forIdentity id: String) throws {
      let data = try JSONEncoder().encode(analysis)
      let dest = try cacheURL(forIdentity: id)
      try FileManager.default.createDirectory(
          at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: dest, options: .atomic)
  }
  private static func cacheURL(forIdentity id: String) throws -> URL {
      let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
      let digest = SHA256.hash(data: Data(id.utf8))
      let key = digest.map { String(format: "%02x", $0) }.joined()
      return caches.appendingPathComponent("BeatAlignmentCache", isDirectory: true)
                   .appendingPathComponent(key).appendingPathExtension("json")
  }
  ```
  `updateManualNudge`도 동일 cacheIdentity 오버로드 추가.
- [ ] **Step 4**: 테스트 — 43개 통과.
- [ ] **Step 5**: 커밋 `feat(analysis): cacheIdentity overload for logical keys`.

## Task 4: AudioManager.loadFile에 analysisIdentity 파라미터

**Files**: Modify `Cadenza/Models/AudioManager.swift`

- [ ] **Step 1**: 새 시그니처 추가:
  ```swift
  func loadFile(url: URL, generation: Int, analysisIdentity: String? = nil) async {
      self.trackGeneration = generation
      // ...기존 본문...
      // 분석 호출부 분기:
      let analysisHint = metadataBPM ?? pendingPresetBPMHint
      let alignmentResult: BeatAlignmentLoadResult? = try? await Task.detached(
          priority: .userInitiated) {
          if let id = analysisIdentity {
              return try BeatAlignmentAnalyzer.loadOrAnalyze(
                  url: url, cacheIdentity: id, expectedBPM: analysisHint)
          } else {
              return try BeatAlignmentAnalyzer.loadOrAnalyze(
                  url: url, expectedBPM: analysisHint)
          }
      }.value
      // ...기존 결과 처리 동일...
  }
  ```
  기존 `loadFile(url:)`, `loadFile(url:generation:)`는 `analysisIdentity: nil` wrapper 유지. PR 3이나 Task 8에서 쓸 `loadFile(url:analysisIdentity:)` wrapper도 추가 (generation 자동 증가):
  ```swift
  func loadFile(url: URL, analysisIdentity: String) async {
      trackGeneration += 1
      await loadFile(url: url, generation: trackGeneration, analysisIdentity: analysisIdentity)
  }
  ```
- [ ] **Step 2**: 테스트 — 43개 유지.
- [ ] **Step 3**: 커밋 `refactor(audio): loadFile accepts analysisIdentity`.

## Task 5: PlaylistSummary + MusicLibrary

**Files**: Create `Cadenza/Models/PlaylistSummary.swift`, `Cadenza/Services/MusicLibraryService.swift`, `Tests/MusicLibraryServiceTests.swift`

- [ ] **Step 1**: `PlaylistSummary`:
  ```swift
  struct PlaylistSummary: Identifiable, Sendable, Equatable {
      let id: UInt64
      let name: String
      let itemCount: Int
      let artworkThumbnail: Data?
  }
  ```
- [ ] **Step 2**: 프로토콜 + 실구현:
  ```swift
  import MediaPlayer

  protocol MusicLibrary: Sendable {
      func authorizationStatus() -> MPMediaLibraryAuthorizationStatus
      func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus
      func fetchPlaylists() async throws -> [PlaylistSummary]
      func fetchItems(in playlistID: UInt64) async throws -> [QueueItem]
  }

  struct MusicLibraryService: MusicLibrary {
      func authorizationStatus() -> MPMediaLibraryAuthorizationStatus {
          MPMediaLibrary.authorizationStatus()
      }
      func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
          await withCheckedContinuation { c in
              MPMediaLibrary.requestAuthorization { c.resume(returning: $0) }
          }
      }
      func fetchPlaylists() async throws -> [PlaylistSummary] {
          try await Task.detached(priority: .userInitiated) {
              let q = MPMediaQuery.playlists()
              let lists = (q.collections as? [MPMediaPlaylist]) ?? []
              return lists.map { p in
                  let art = p.representativeItem?.artwork?.image(at: CGSize(width: 80, height: 80))
                  return PlaylistSummary(
                      id: p.persistentID,
                      name: (p.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? "Untitled",
                      itemCount: p.count,
                      artworkThumbnail: art?.pngData())
              }
          }.value
      }
      func fetchItems(in playlistID: UInt64) async throws -> [QueueItem] {
          try await Task.detached(priority: .userInitiated) {
              let q = MPMediaQuery.playlists()
              q.addFilterPredicate(MPMediaPropertyPredicate(
                  value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID))
              guard let pl = (q.collections as? [MPMediaPlaylist])?.first else { return [] }
              return pl.items.map { mi in
                  let cloud = mi.assetURL == nil
                  return QueueItem(
                      id: "am-\(mi.persistentID)",
                      title: mi.title ?? "Untitled",
                      artist: mi.artist,
                      source: .appleMusic(persistentID: mi.persistentID, assetURL: mi.assetURL),
                      unplayableReason: cloud ? .cloudOnly : nil)
              }
          }.value
      }
  }
  ```
- [ ] **Step 3**: Mock 기반 테스트:
  ```swift
  struct MockMusicLibrary: MusicLibrary {
      var statusValue: MPMediaLibraryAuthorizationStatus = .authorized
      var playlists: [PlaylistSummary] = []
      var itemsByPlaylist: [UInt64: [QueueItem]] = [:]
      func authorizationStatus() -> MPMediaLibraryAuthorizationStatus { statusValue }
      func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus { statusValue }
      func fetchPlaylists() async throws -> [PlaylistSummary] { playlists }
      func fetchItems(in id: UInt64) async throws -> [QueueItem] { itemsByPlaylist[id] ?? [] }
  }

  final class MusicLibraryServiceTests: XCTestCase {
      func testMockFetchPlaylists() async throws {
          let m = MockMusicLibrary(playlists: [
              .init(id: 1, name: "Run", itemCount: 5, artworkThumbnail: nil)])
          XCTAssertEqual((try await m.fetchPlaylists()).first?.name, "Run")
      }
      func testMockFetchItems() async throws {
          let item = QueueItem(id: "am-1", title: "s", artist: nil,
              source: .appleMusic(persistentID: 1, assetURL: nil),
              unplayableReason: .cloudOnly)
          let m = MockMusicLibrary(itemsByPlaylist: [99: [item]])
          XCTAssertEqual((try await m.fetchItems(in: 99)).first?.unplayableReason, .cloudOnly)
      }
  }
  ```
- [ ] **Step 4**: 테스트 — 45개 통과.
- [ ] **Step 5**: 커밋 `feat(music): MusicLibrary protocol + MPMediaQuery impl`.

## Task 6: AssetResolver actor + eviction

**Files**: Create `Cadenza/Services/AssetResolver.swift`, `Tests/AssetResolverEvictionTests.swift`

- [ ] **Step 1**: 테스트 (file passthrough만 시뮬레이터로 검증; Apple Music export는 실기기 manual):
  ```swift
  final class AssetResolverEvictionTests: XCTestCase {
      func testFileSourcePassthrough() async throws {
          let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
          try Data([0,0,0,0]).write(to: tmp)
          defer { try? FileManager.default.removeItem(at: tmp) }
          let resolver = AssetResolver()
          let item = QueueItem(id: "f", title: "f", artist: nil, source: .file(tmp))
          let resolved = try await resolver.resolve(item)
          XCTAssertEqual(resolved, tmp)
      }
      func testAppleMusicExportRequiresDevice() throws {
          throw XCTSkip("requires real device + Apple Music subscription")
      }
  }
  ```
- [ ] **Step 2**: AssetResolver 구현:
  ```swift
  import Foundation
  import AVFoundation

  actor AssetResolver {
      private var ownedWAVs: [String: URL] = [:]
      private var order: [String] = []
      private let maxCached = 2
      private let tmpDir: URL
      init(tmpDir: URL = FileManager.default.temporaryDirectory
           .appendingPathComponent("CadenzaAssetCache", isDirectory: true)) {
          self.tmpDir = tmpDir
          try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      }
      func resolve(_ item: QueueItem) async throws -> URL {
          switch item.source {
          case .file(let url): return url
          case .appleMusic(let pid, let assetURL):
              guard let assetURL else { throw Err.noAssetURL }
              let key = item.analysisCacheIdentity
              if let cached = ownedWAVs[key], FileManager.default.fileExists(atPath: cached.path) {
                  return cached
              }
              let url = try await exportWAV(assetURL: assetURL, persistentID: pid)
              register(key: key, url: url)
              return url
          }
      }
      func reset() {
          for u in ownedWAVs.values { try? FileManager.default.removeItem(at: u) }
          ownedWAVs.removeAll(); order.removeAll()
      }
      private func register(key: String, url: URL) {
          ownedWAVs[key] = url
          order.removeAll { $0 == key }
          order.append(key)
          while order.count > maxCached {
              let evict = order.removeFirst()
              if let v = ownedWAVs.removeValue(forKey: evict) {
                  try? FileManager.default.removeItem(at: v)
              }
          }
      }
      private func exportWAV(assetURL: URL, persistentID: UInt64) async throws -> URL {
          let asset = AVURLAsset(url: assetURL)
          let reader = try AVAssetReader(asset: asset)
          guard let track = try await asset.loadTracks(withMediaType: .audio).first
          else { throw Err.noAudioTrack }
          let settings: [String: Any] = [
              AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
              AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false,
              AVLinearPCMIsNonInterleaved: false,
              AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2]
          let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
          reader.add(output); reader.startReading()
          let dest = tmpDir.appendingPathComponent("\(persistentID).wav")
          try? FileManager.default.removeItem(at: dest)
          let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
          let file = try AVAudioFile(forWriting: dest, settings: fmt.settings)
          while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
              guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
              var len = 0; var ptr: UnsafeMutablePointer<Int8>?
              if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                  totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr {
                  let frames = AVAudioFrameCount(len / 4)
                  if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) {
                      buf.frameLength = frames
                      memcpy(buf.int16ChannelData?[0], ptr, len)
                      try file.write(from: buf)
                  }
              }
              CMSampleBufferInvalidate(sb)
          }
          if reader.status == .failed { throw reader.error ?? Err.decodingFailed }
          return dest
      }
      enum Err: Error { case noAssetURL, noAudioTrack, decodingFailed }
  }
  ```
- [ ] **Step 3**: 테스트 — 47개 통과(45 + 2, skip 포함).
- [ ] **Step 4**: 커밋 `feat(music): AssetResolver actor with N+1 eviction`.

## Task 7: AppleMusicLibraryView 2-step 피커

**Files**: Create `Cadenza/Views/AppleMusicLibraryView.swift`

- [ ] **Step 1**: SwiftUI View 구현 (설계 문서 섹션 3 인터페이스 참조). 주요 구조:
  - `NavigationStack` 루트, 상태: `playlists`, `items`, `selectedPlaylist`, `authStatus`
  - `authStatus == .notDetermined` → "권한 요청" 버튼 → `library.requestAuthorization()` 호출
  - `.denied`/`.restricted` → "설정 열기" 버튼 → `UIApplication.openSettingsURLString` 딥링크
  - `.authorized` & `selectedPlaylist == nil` → 플레이리스트 목록 (`List(playlists)`)
  - `.authorized` & `selectedPlaylist != nil` → 트랙 목록. `unplayableReason == .cloudOnly` 아이템은 `disabled` + 구름 아이콘, 아니면 체크 아이콘
  - 트랙 탭 → `onTrackPicked(item)` 콜백 → `dismiss()`
  - `.task` modifier로 초기 로드
- [ ] **Step 2**: 빌드 성공 확인.
- [ ] **Step 3**: 커밋 `feat(ui): AppleMusicLibraryView 2-step picker`.

## Task 8: PlayerView 진입 버튼 + 단일 트랙 로드 파이프라인

**Files**: Modify `Cadenza/Views/PlayerView.swift`

- [ ] **Step 1**: State와 dependencies:
  ```swift
  @State private var showAppleMusicPicker = false
  private let musicLibrary: MusicLibrary = MusicLibraryService()
  private let assetResolver = AssetResolver()
  ```
- [ ] **Step 2**: 기존 파일 피커 옆에 버튼:
  ```swift
  Button("Apple Music 가져오기") { showAppleMusicPicker = true }
      .sheet(isPresented: $showAppleMusicPicker) {
          AppleMusicLibraryView(library: musicLibrary) { item in
              Task { await handleAppleMusicPick(item) }
          }
      }
  ```
- [ ] **Step 3**: 로드 핸들러:
  ```swift
  @MainActor
  private func handleAppleMusicPick(_ item: QueueItem) async {
      do {
          let url = try await assetResolver.resolve(item)
          await audio.loadFile(url: url, analysisIdentity: item.analysisCacheIdentity)
      } catch {
          audio.presentError("Apple Music 트랙을 불러오지 못했습니다")
      }
  }
  ```
- [ ] **Step 4**: 빌드 성공 + 시뮬레이터 스모크 (파일 피커 경로는 기존대로 동작).
- [ ] **Step 5**: 실기기 수동 검증: Apple Music 구독 계정으로 "Apple Music 가져오기" → 권한 → 플레이리스트 → 다운로드된 곡 선택 → 로드 → 기존 재생 컨트롤로 재생·템포 변경 확인.
- [ ] **Step 6**: 커밋 `feat(ui): PlayerView Apple Music picker and single-track load`.

## Exit Criteria

- [ ] PR 1의 40개 + PR 2 신규(~7개 + skip 포함) 테스트 통과
- [ ] 실기기에서 Apple Music 보관함 다운로드 곡 선택 → 재생·템포 변경·메트로놈 기존 동작 동일
- [ ] cloud-only 트랙은 구름 아이콘 + 선택 불가
- [ ] 권한 거부 → 설정 딥링크 정상
- [ ] 같은 트랙 두 번째 로드 시 분석 cache `.hit` (persistentID 기반)

## Rollback

각 Task 독립. AssetResolver가 tmp 생성 문제 있으면 PR 0 spike 로직과 1:1 비교. BeatAlignmentAnalyzer 오버로드가 문제면 기존 API만 남기고 되돌린 뒤 identity 설계 재검토.
