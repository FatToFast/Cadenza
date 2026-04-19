# Apple Music 보관함 플레이리스트 큐 import 설계

날짜: 2026-04-19  
상태: 초안 (브레인스토밍 완료, 구현 계획 작성 대기)

## Context

사용자는 djay Pro처럼 Apple Music 보관함에서 플레이리스트를 불러와 자신의 목표 BPM으로 연속 재생하는 경험을 원한다. 현재 Cadenza는 파일 피커로 한 곡씩만 로드할 수 있고, 한 곡 재생 + 루프가 주 동작이다. 본 설계는 Apple Music 보관함(라이브러리)에 저장된 플레이리스트를 읽고, 자동 전진 큐로 연속 재생하는 기능을 추가한다. Apple Music 카탈로그 직접 스트리밍은 범위 외 — 일반 개발자 앱은 카탈로그 곡의 PCM 샘플에 접근할 수 없다. 보관함에 추가된 트랙만 대상이다.

## 결정된 제품 요구사항

- **병렬 추가** — 기존 파일 피커는 유지, Apple Music 버튼을 별도로 추가
- **보관함 기반** — 카탈로그 검색 없음, 사용자가 보관함에 추가한 플레이리스트만
- **플레이리스트 큐잉** — 선택한 플레이리스트의 모든 곡이 큐에 들어감
- **자동 전진** — 곡 끝 → 다음 재생 가능한 곡으로 자동 전환
- **targetBPM 유지** — 트랙 전환 시에도 사용자 설정 유지 (연습 모드)
- **자동 스킵** — 재생 불가 트랙(cloud-only, 디코딩 실패, rate 초과)은 토스트만 띄우고 스킵
- **Prefetch** — 다음 곡을 백그라운드에서 미리 디코드·분석
- **큐 UI** — 현재+다음 미니 표시, 탭으로 전체 큐 펼침, 큐에서 제거만 가능 (재정렬 없음)
- **권한 거부 시** — 설명 + iOS 설정 딥링크

**명시적 v1 비포함**: 드래그 재정렬, 플레이리스트 편집, 트랙별 targetBPM 저장, 카탈로그 검색, 보관함 필터, iPad 레이아웃 최적화.

## 근본 원인 / 기술적 불확실성

1. **Apple Music URL 호환성** — `MPMediaItem.assetURL`은 `ipod-library://` 커스텀 스킴. `AVAudioFile(forReading:)`이 이 스킴을 직접 지원하는지 iOS 버전/트랙별로 달라질 수 있음. 안전하게 `AVURLAsset` → `AVAssetReader`로 PCM을 임시 WAV 파일로 추출하는 중간 단계를 거친다.

2. **Swift 6 동시성** — `PlaybackQueue`가 `@MainActor`에서 `@Published` 상태를 관리하면서 백그라운드 prefetch 결과를 수신해야 함. Sendable 경계 명시 필요.

3. **타이밍 race** — 기존 `scheduleLoop` completion handler는 private audio thread에서 실행 후 MainActor로 hop. 큐 모드 전환 시점에 따라 stale completion이 발생할 수 있음.

## 아키텍처

### 노드·모듈 구성

```
PlayerView
  ├─ NowPlayingInfo (읽기 전용 표시 단일 소스)
  ├─ QueueBanner (Queue 있을 때만)
  └─ "Apple Music 가져오기" 버튼
        ↓ tap
     AppleMusicLibraryView (2-step 피커)
        ↓ 선택 확정
     PlaybackQueue (@MainActor, ObservableObject)
        ├─ holds → AssetResolver (actor)
        ├─ observes → AudioManager.trackEndedSubject
        └─ commands → AudioManager
     AudioManager (@MainActor, 기존)
        ├─ trackGeneration: Int
        ├─ playbackEndBehavior: .loop | .notify
        └─ publishes trackEndedSubject
     AssetResolver (actor)
        ├─ file URL → passthrough
        └─ ipod-library URL → AVAssetReader → tmp/<hash>.wav (N+1 eviction)
     MusicLibraryService (프로토콜 `MusicLibrary` 주입)
        ├─ MPMediaLibrary.requestAuthorization (MediaPlayer 보관함 권한)
        └─ MPMediaQuery (플레이리스트·트랙·assetURL 취득)
```

### 핵심 타입

```swift
struct QueueItem: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let source: Source
    var unplayableReason: UnplayableReason?

    enum Source: Sendable {
        case file(URL)
        case appleMusic(persistentID: UInt64, assetURL: URL?)
    }

    enum UnplayableReason: Sendable {
        case cloudOnly
        case decodingFailed
        case rateOutOfRange(required: Double)
        case subscriptionLapsed
    }
}

struct NowPlayingInfo: Sendable {
    let title: String?
    let artist: String?
    let originalBPM: Double
    let originalBPMSource: OriginalBPMSource
    let playbackProgress: Double
    let playbackDuration: TimeInterval
    let queueContext: QueueContext?

    struct QueueContext: Sendable {
        let currentIndex: Int
        let totalCount: Int
        let nextTitle: String?
    }
}

protocol MusicLibrary: Sendable {
    func authorizationStatus() -> MPMediaLibraryAuthorizationStatus
    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus
    func fetchPlaylists() async throws -> [PlaylistSummary]
    func fetchItems(in playlistID: UInt64) async throws -> [QueueItem]
}

// 권한 API 주의: MPMediaQuery를 데이터 소스로 쓰므로
// MPMediaLibrary.requestAuthorization()이 정답. MusicKit의 MusicAuthorization은
// MusicKit 전용 API (MusicLibraryRequest 등)를 쓸 때만 필요하며 본 설계는 쓰지 않음.

actor AssetResolver {
    func resolve(_ item: QueueItem) async throws -> URL
    func release(after index: Int)
    func reset()
}

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isActive: Bool = false
    let nowPlayingUpdates: AnyPublisher<NowPlayingInfo, Never>
    // 내부: consecutiveFailureCount, prefetchTask, resolver, audio
}

enum PlaybackEndBehavior { case loop, notify }
```

### AudioManager 변경점

- 새 필드: `private var trackGeneration: Int = 0`, `@Published var playbackEndBehavior: PlaybackEndBehavior = .loop`, `let trackEndedSubject = PassthroughSubject<Void, Never>()`
- `loadFile(url:generation:)` — 매 호출마다 generation 증가
- `scheduleLoop` completion closure는 `capturedGeneration`을 캡처 — 현 generation과 다르면 drop. `.loop`면 기존 재스케줄, `.notify`면 trackEndedSubject 발행
- 기존 파일 피커 경로도 "크기 1 큐"로 포장 → NowPlayingInfo를 Queue에서 단일 발행

## 데이터 플로우

### 재생 시작 → 자동 전진

1. 사용자가 "Apple Music 가져오기" tap
2. `MusicAuthorization.request()` — 최초 1회 권한 시스템 팝업
3. granted → `MusicLibraryService.fetchPlaylists()` → `AppleMusicLibraryView` 표시
4. 플레이리스트 선택 → `fetchItems(in:)` → 트랙 리스트 (cloud/downloaded 아이콘)
5. 확정 → `PlaybackQueue.load(items:)` → `currentIndex = 0`, `isActive = true`
6. `playCurrent()`:
   a. `trackGeneration` 증가
   b. `resolvedURL = await AssetResolver.resolve(item)`
   c. `audio.loadFile(url: resolvedURL, generation: currentGen)`
   d. `expectedRate = audio.targetBPM / audio.originalBPM`
   e. `expectedRate > rateHardCap` → item.unplayableReason = .rateOutOfRange → `advance()`
   f. `audio.play()`
   g. `Task.detached { prefetch(currentIndex + 1) }`
7. 곡 재생 중: scheduleLoop completion 대기
8. 곡 끝 → completion 콜백:
   - `capturedGeneration != audio.trackGeneration` → 무시
   - `playbackEndBehavior == .notify` → `trackEndedSubject.send()`
9. Queue가 `trackEndedSubject` 구독 → `advance()` → `playCurrent()` 재귀

### Skip / Advance 공통 루틴

```
advance():
  loop:
    currentIndex += 1
    if currentIndex >= items.count:
      emit queueCompleted event; isActive = false; return
    if items[currentIndex].unplayableReason != nil:
      continue
    break
  playCurrent()
```

### Prefetch

```
prefetch(at:):
  prefetchTask?.cancel()
  prefetchTask = Task.detached {
    guard !Task.isCancelled else { return }
    let url = try await resolver.resolve(items[at])
    _ = try? BeatAlignmentAnalyzer.loadOrAnalyze(url: url, expectedBPM: nil)
    // 분석 결과 JSON 캐시에 저장 → 다음 loadFile이 cache hit
  }
```

백그라운드 진입 시 **prefetch 취소하지 않음** (복귀 시 즉시 재생 우선).

## 에러 매트릭스

| 상황 | 처리 | UI |
|---|---|---|
| 권한 `denied`/`restricted` | 버튼 비활성 상태 | 설명 + "설정 열기" 시트 (iOS 설정 딥링크) |
| 권한 `notDetermined` | 버튼 탭 시 시스템 권한 팝업 (`MPMediaLibrary.requestAuthorization`) | 허용 시 플레이리스트 로드, 거부 시 위 행으로 |
| 보관함 비어있음 | 피커 초기 상태 | "보관함이 비어있습니다" |
| 플레이리스트 모두 cloud-only | 큐 구성 안 함 | "재생 가능한 곡이 없습니다. 다운로드 후 재시도" |
| 특정 곡 assetURL nil | QueueItem.unplayableReason = .cloudOnly | 큐 아이템에 구름 아이콘 |
| AVAssetReader 실패 | `.decodingFailed` | 경고 아이콘 |
| 분석 실패 | 120 BPM fallback (기존) | "확인 필요" 배지 (기존) |
| expectedRate > hardCap | `.rateOutOfRange` | 토스트 "N곡이 템포 범위 초과로 스킵됨" |
| 연속 실패 3회 | 큐 클리어, 파일 피커 모드 복귀 | 배너 "Apple Music 접근 이슈 — 구독 확인" |

## 속도 한계

- `rateWarningThreshold = 1.6` — 경고 배너 (계속 재생)
- `rateHardCap = 2.0` — 해당 트랙 자동 스킵
- 기존 `BPMRange.rateMax = 2.5`는 수동 BPM 입력 상한으로 유지, 큐 자동 전진만 hardCap 적용

## 백그라운드·잠금화면

### 빌드 설정 (`project.yml`) 변경

본 프로젝트는 `GENERATE_INFOPLIST_FILE: true`로 Info.plist를 생성한다. 따라서 직접 plist 파일을 편집하지 않고 `project.yml`의 타겟 settings에 `INFOPLIST_KEY_*` 를 추가한다.

```yaml
targets:
  Cadenza:
    settings:
      base:
        INFOPLIST_KEY_NSAppleMusicUsageDescription: "메트로놈에 맞춰 재생할 Apple Music 보관함 곡을 불러옵니다."
        INFOPLIST_KEY_UIBackgroundModes: audio
        # 기존 키는 유지
```

`INFOPLIST_KEY_UIBackgroundModes` 는 xcodegen이 배열로 변환해 `UIBackgroundModes: [audio]` 로 plist에 들어간다. 추가 모드가 필요해지면 `"audio mixed-audio"` 처럼 공백 구분.

### 런타임 동작
- `AVAudioSession.Category.playback` — 기존 설정 그대로 (SPEC.md §1.1에 따라 이미 선언됨)
- `MPNowPlayingInfoCenter.default().nowPlayingInfo` — 현재 곡 메타데이터, 큐 전환 시 업데이트
- `MPRemoteCommandCenter.shared()` — play/pause/next/prev 원격 명령을 Queue 액션에 바인딩

### SPEC.md §1.5와의 관계 (세션 공존)

SPEC.md §1.5는 v1 가설로 `ApplicationMusicPlayer` + `.mixWithOthers` 기반 세션 공존을 기록했다. 본 설계는 PCM 추출로 전환하면서 **이 가설을 폐기한다**. 이유:
- `ApplicationMusicPlayer`는 `AVAudioEngine`과 독립 출력이라 메트로놈과의 **샘플 정확도 동기 불가**
- 템포 변경(time-stretching)이 ApplicationMusicPlayer에 직접 노출되지 않음
- 본 프로젝트의 핵심 기능(메트로놈 동기 + 템포 변경)을 위해 PCM 레벨 접근 필수

대신 모든 오디오는 앱의 단일 `AVAudioEngine`으로 흐른다. `.mixWithOthers` 옵션은 사용하지 않는다. SPEC.md §1.5는 본 설계 머지 후 후속 커밋에서 업데이트한다.

## 분석 캐시 identity (BeatAlignmentAnalyzer 확장)

### 문제
현재 `BeatAlignmentAnalyzer.loadOrAnalyze(url:expectedBPM:)`는 내부에서 URL path + 파일 fingerprint(size + modifiedAt + duration)로 캐시 키를 만든다. Apple Music 트랙은 매번 다른 tmp WAV로 export되므로 fingerprint가 매번 달라져 **cache miss 상시 발생**. manualNudge 영속성도 같은 이유로 유지 안 됨.

### 해결
`BeatAlignmentAnalyzer`에 **논리 캐시 키**를 명시적으로 받는 오버로드 추가:

```swift
enum BeatAlignmentAnalyzer {
    // 기존 API (파일 URL 기반, 그대로 유지)
    static func loadOrAnalyze(url: URL, expectedBPM: Double?) throws -> BeatAlignmentLoadResult

    // 신규: 논리 키 기반
    static func loadOrAnalyze(
        url: URL,
        cacheIdentity: String,   // 예: "applemusic-\(persistentID)"
        expectedBPM: Double?
    ) throws -> BeatAlignmentLoadResult
}
```

신규 오버로드 동작:
- cache 키로 `cacheIdentity` 사용 (URL hash 대신)
- fingerprint 대신 `cacheIdentity` 일치 여부만 확인 — tmp 파일 재생성되어도 hit
- 저장은 기존 `BeatAlignmentCache` 하위에 다른 파일명 스킴 사용: `cacheIdentity` SHA256 → `.json`

### QueueItem 확장
```swift
struct QueueItem {
    var analysisCacheIdentity: String {
        switch source {
        case .file(let url): return "file-\(url.path)"     // 기존 동작과 호환
        case .appleMusic(let persistentID, _): return "applemusic-\(persistentID)"
        }
    }
}
```

AudioManager.loadFile이 큐 경로일 때 해당 identity를 analyzer로 전달. 파일 피커 경로는 기존 API(URL 기반) 그대로 호출 — 기존 캐시 유효성 유지.

### ManualNudge 영속성
`updateManualNudge` 함수도 동일한 분기 필요:
```swift
static func updateManualNudge(
    _ manualNudge: TimeInterval,
    cacheIdentity: String,
    analysis: BeatAlignmentAnalysis
) throws -> BeatAlignmentAnalysis
```

Apple Music 트랙의 수동 beat 보정이 세션을 넘어 `persistentID` 기반으로 유지된다.

### AudioManager 배선
`loadFile(url:generation:)`에 `analysisIdentity: String?` 파라미터 추가. nil이면 기존 URL 기반 API 사용 (파일 피커 호환), 값 있으면 논리 키 API 사용. Queue 경로만 identity 전달.

## AssetResolver 캐시 정책

- 최대 2개 WAV 파일 유지 (current + prefetched next)
- 저장 위치: `FileManager.default.temporaryDirectory/CadenzaAssetCache/`
- 새 prefetch 시작 시 이전 N-1 WAV 삭제 — 단, 파일 핸들 (AVAudioFile) 열려 있으면 보류
- `reset()` — 큐 해제 시 모두 삭제
- iOS가 메모리 압박 시 자동 회수 가능하도록 `.tmp` 하위

## 파일 레이아웃

```
Cadenza/
  Services/                           # 신규
    MusicLibraryService.swift         # MusicLibrary 프로토콜 + 구현
    AssetResolver.swift               # actor
  Models/
    PlaybackQueue.swift               # 신규
    QueueItem.swift                   # 신규
    NowPlayingInfo.swift              # 신규
    AudioManager.swift                # 수정
  Views/
    AppleMusicLibraryView.swift       # 신규 (2-step 피커)
    PlayerView.swift                  # NowPlayingInfo 사용으로 전환
    Components/
      QueueBanner.swift               # 신규 (미니 UI)
      QueueListView.swift             # 신규 (확장 모달)
Tests/
  PlaybackQueueTests.swift            # 신규
  AssetResolverEvictionTests.swift    # 신규
  AudioManagerGenerationTests.swift   # 신규
  NowPlayingInfoTests.swift           # 신규
```

## 테스트 전략

**순수 유닛** — Simulator, 빠른 반복
- `PlaybackQueueTests` — advance, skip unplayable, remove, jump, 큐 끝, 연속 실패 3회 집계. MockMusicLibrary + MockAudioManager 주입.
- `AssetResolverEvictionTests` — N+1 캐시, 열린 파일 핸들 보류
- `QueueItemTests` — UnplayableReason 판정
- `NowPlayingInfoTests` — 양쪽 소스 populate 일관성

**통합** — Simulator
- `AudioManagerGenerationTests` — generation 기반 stale completion drop
- `PlaybackQueueIntegrationTests` — 실제 AudioManager + 가짜 AssetResolver end-to-end

**수동** — 실기기 필수
- Apple Music 구독 계정, 3곡 이상 플레이리스트 자동 전진
- cloud-only 스킵 토스트
- targetBPM 110 + 원곡 50 BPM 트랙 → rate 초과 스킵
- 잠금화면 remote control
- 백그라운드 트랙 전환 지속
- 구독 만료는 테스트 플래그로 에러 분기 트리거

## 작업 분할

**PR 0 — Spike: Apple Music 라이브러리 트랙 PCM 추출 검증** (실기기 필수)

본 설계는 SPEC.md §1.5의 ApplicationMusicPlayer 방향을 폐기하고 PCM 추출 쪽으로 선회한다. 이 선회가 실현 가능한지 **본 구현 시작 전에 실기기에서 검증**해야 한다.

- 검증 시나리오:
  1. Apple Music 구독 계정으로 실기기에서 앱 실행
  2. 임의 보관함 곡 1개를 "기기에 다운로드" 상태로 두기
  3. `MPMediaLibrary.requestAuthorization` → `MPMediaQuery.songs().items?.first { $0.assetURL != nil }` 로 곡 찾기
  4. 해당 `assetURL`로 `AVURLAsset` 생성 → `AVAssetReader`로 PCM 읽기 시도
  5. 성공하면 임시 WAV 생성 후 `AVAudioFile(forReading:)` 로드 확인
- 성공 조건: 오디오 샘플을 실제로 읽고, BeatAlignmentAnalyzer가 값 반환
- 실패 조건: DRM 에러, assetURL 접근 불가, 재생 중단 등
- 결과물: 짧은 개발 브랜치에 spike 스크립트/테스트 코드, 결과 노트
- spike 성공 → PR 1로 진행
- spike 실패 → 설계 재검토 (ApplicationMusicPlayer 방향으로 재선회 또는 범위 축소)

**PR 1 — 인프라 리팩터 (외부 동작 변경 없음)**
- `QueueItem`, `NowPlayingInfo`, `PlaybackEndBehavior` 타입 도입
- `AudioManager.trackGeneration` + generation-race-free `scheduleLoop`
- 기존 파일 피커 경로를 size-1 큐로 포장
- PlayerView → NowPlayingInfo 구독으로 전환
- `AudioManagerGenerationTests` 신규 ~6개 + 기존 30개 테스트 회귀

**PR 2 — Apple Music 읽기 전용**
- `MusicLibraryService` + 프로토콜 + 주입
- `AssetResolver` actor + eviction
- `AppleMusicLibraryView` 2-step 피커
- 권한 거부 UX + `Info.plist` 업데이트
- 단일 곡 선택 → 큐 크기 1 로드까지. 자동 전진 없음.

**PR 3 — 큐 자동 전진 + prefetch + 잠금화면**
- `PlaybackQueue` 전체 구현 (`advance`, `prefetch`, `trackEndedSubject` 구독)
- `QueueBanner`, `QueueListView`
- Rate cap 스킵, 연속 실패 처리
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`

## 리스크 및 주의

- **`MPMediaItem.assetURL` 런타임 검증 불가** — iOS 버전·지역·구독 상태별로 동작 차이 가능. AssetResolver의 decoding 실패 경로가 견고해야 함.
- **Prefetch와 메인 재생 I/O 경합** — 동일 디스크·CPU 사용. 실기기 관측 후 필요 시 prefetch를 `.utility` QoS로 낮춤.
- **`AVAudioFile`의 임시 WAV 파일 수명** — AssetResolver가 재생 중인 파일 핸들을 추적해야 함. 해지 시점에 AudioManager가 "done" 시그널 필요할 수 있음 (현재 설계에는 단순 "next prefetch가 N-1 삭제" 정책. 실기기 검증 필요).
- **Swift 6 Sendable** — `QueueItem`은 간단한 Sendable이지만 `URL`, `UInt64` 모두 Sendable이라 OK. `NowPlayingInfo`도 마찬가지.
- **Background audio entitlement** — 빠뜨리면 잠금화면 시 재생 중단. Info.plist 변경 확인 필수.
- **구독 만료 탐지** — iOS는 앱에 명시적 알림을 주지 않음. 연속 실패 카운트가 유일한 간접 신호.

## 인터페이스 계약 명세 (리뷰 보강)

### `AssetResolver.resolve` async 계약
`resolve(_:)`는 **tmp WAV 파일이 디스크에 완전히 쓰여지고 경로가 안정화된 뒤**에만 반환한다. 부분 쓰기·쓰기 중 상태의 URL을 돌려주지 않는다. 호출자는 반환된 URL을 즉시 `AVAudioFile(forReading:)`에 전달해도 안전하다는 전제를 갖는다. 파일 URL(소스가 `.file`)인 경우는 즉시 passthrough, Apple Music URL인 경우는 AVAssetReader가 모든 프레임을 write 후 `close()` 완료 뒤 반환한다.

### `AudioManager.loadFile` 시그니처 마이그레이션
기존 `func loadFile(url: URL) async` 는 유지하되 내부적으로 `loadFile(url:generation:)`를 호출한다:

```swift
func loadFile(url: URL) async {
    await loadFile(url: url, generation: nextGeneration())
}
func loadFile(url: URL, generation: Int) async { ... }
private func nextGeneration() -> Int { trackGeneration += 1; return trackGeneration }
```

모든 call site(PlayerView의 파일 피커 경로, loadSampleTrack)는 변경 없이 동작하며 generation은 자동 부여된다. Queue 경로만 명시적으로 `generation:` 오버로드를 사용한다.

### Play 버튼을 prefetch 완료 전에 누른 경우
Queue의 `isActive = true` 직후 첫 `playCurrent()`는 `resolve` 대기 중이다. 이 구간은 **AudioManager.state = .loading** 을 그대로 사용 (기존 loadFile이 state를 .loading으로 세팅하는 경로). UI는 기존 loading 표시 재사용 — PlayerView에 별도 로딩 상태 추가하지 않는다. 사용자가 그 사이 play 버튼을 추가로 누르면 무시한다(기존 AudioManager.play 가드 `canResumeTrack || canStartMetronomeOnly`가 .loading 상태를 제외).

### 재생 중인 트랙을 큐에서 제거
`remove(at: currentIndex)` 호출:
1. 해당 인덱스 항목 삭제
2. currentIndex는 고정 (이제 그 인덱스에 새 트랙이 있음, 즉 원래 다음 곡)
3. `playCurrent()` 호출 → 새 현재 트랙 로드·재생
4. currentIndex가 `items.count` 이상이면 queue complete 경로

즉 "현재 곡 제거 = 다음 곡으로 전진". 명시적 선택.

### 파일 피커 트랙 재생 중 Apple Music import
시나리오: 사용자가 파일 A를 재생 중인데 "Apple Music 가져오기" 탭 후 플레이리스트 B 선택.

동작: 기존 크기 1 큐(파일 A)가 **플레이리스트 B 큐로 대체**된다. A 재생은 즉시 멈추고, B의 첫 재생 가능한 트랙이 load·play된다. 사용자가 실수를 방지할 수 있도록 피커 확정 직전에 "현재 재생 중지됩니다" 안내를 **표시하지 않는다 (v1)** — 일반 음악 앱 관례상 새 선택은 대체 동작이 자연스러움.

### 로컬라이제이션 컨벤션
DESIGN.md §6에 따라 **한국어 + 영어 병행, iOS 17+ String Catalog(`.xcstrings`) 사용**. 본 기능에서 새로 추가되는 모든 사용자 노출 문자열(UI 라벨, 에러 메시지, 토스트, 권한 설명)은 **처음부터 String Catalog에 등록**한다.

- `Localizable.xcstrings` 파일이 없다면 PR 1에서 함께 추가
- 새 문자열은 Swift 코드에서 `Text("apple_music_picker_title")` 같은 키 호출 형태
- Info.plist 권한 설명(`NSAppleMusicUsageDescription`)은 xcodegen settings에서 한국어 기본값 지정, 이후 String Catalog로 확장
- 기존 인라인 한국어(Constants.swift 등) 마이그레이션은 본 설계 범위 외 (별도 작업)

### 테스트 케이스 구체 예시 (카테고리당 1개)

**`PlaybackQueueTests`**
```swift
func testAdvanceSkipsUnplayableTracks() async {
    let queue = PlaybackQueue(audio: MockAudio(), resolver: MockResolver())
    await queue.load(items: [playable("A"), unplayable("B"), playable("C")])
    await queue.playCurrent()     // index=0, A 로드 시도
    audio.simulateTrackEnded()    // → advance
    XCTAssertEqual(queue.currentIndex, 2)     // B 스킵, C 도달
}
```

**`AssetResolverEvictionTests`**
```swift
func testN1EvictionDeletesOldestAfterTwoResolves() async throws {
    let resolver = AssetResolver(tmpDir: testTmpDir)
    let first = try await resolver.resolve(item("A"))  // tmp/A.wav 생성
    let second = try await resolver.resolve(item("B")) // tmp/B.wav + A.wav 삭제
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
}
```

**`AudioManagerGenerationTests`**
```swift
func testStaleCompletionHandlerIsDiscarded() async {
    let audio = AudioManager()
    await audio.loadFile(url: fileA)          // generation=1
    let capturedGen = audio.trackGeneration
    await audio.loadFile(url: fileB)          // generation=2
    audio.simulateCompletionHandler(generation: capturedGen)
    // assert: trackEndedSubject did NOT emit, scheduleLoop not reinvoked
}
```

**`NowPlayingInfoTests`**
```swift
func testQueueContextIsNilWhenSingleFilePickerTrack() {
    let info = NowPlayingInfo.fromAudioManager(audio, queue: size1Queue)
    XCTAssertNil(info.queueContext)
    XCTAssertEqual(info.title, "File A")
}
```

나머지 테스트는 위 예시를 템플릿 삼아 구현 중 채운다.

## 검증 방법 (요약)

1. **유닛**: `xcodebuild test -scheme CadenzaTests -destination 'iPhone 17 Pro' -derivedDataPath /tmp/...` 전부 통과
2. **시뮬레이터 통합**: 파일 피커 모드가 회귀 없이 동작, generation race 테스트 통과
3. **실기기**:
   - 3곡 이상 자동 전진
   - cloud-only 스킵 토스트 표시
   - rate > 2.0 곡 스킵
   - 잠금화면 remote control 작동
   - 백그라운드 복귀 시 즉시 다음 곡 재생 (prefetch 성공)
   - 권한 거부 → 설정 딥링크 → 허용 후 복귀 플로우
