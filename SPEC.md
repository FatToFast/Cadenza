# Cadenza — Technical Spec

> 오디오 세션 정책, 에러/엣지케이스 카탈로그, 테스트 계획, 용어집.
> PLANNING.md의 기술 결정을 구현 수준까지 구체화한 문서.

---

## 1. 오디오 세션 정책

이 앱의 핵심은 오디오다. AVAudioSession 설정이 잘못되면 백그라운드 끊김, 블루투스 문제, 인터럽트 후 복구 실패 등 치명적 이슈가 생긴다. 여기서 모든 정책을 명시한다.

### 1.1 기본 설정

```swift
// 앱 시작 시 1회 설정
let session = AVAudioSession.sharedInstance()
try session.setCategory(
    .playback,                    // 무음 스위치 무시, 백그라운드 재생
    mode: .default,               // 일반 음악 재생
    options: []                   // 다른 앱 오디오와 믹싱 안 함
)
try session.setActive(true)
```

| 설정 | 값 | 근거 |
|---|---|---|
| Category | `.playback` | 무음 스위치 무시 + 백그라운드 재생 필수 |
| Mode | `.default` | 음악 재생 표준. `.measurement`나 `.voiceChat`은 불필요 |
| Options | 없음 | `.mixWithOthers` 안 씀 — 다른 앱 음악과 섞이면 메트로놈 의미 없음 |

### 1.2 mixWithOthers를 안 쓰는 이유

러닝 앱(Nike Run Club, Strava 등)은 보통 `.mixWithOthers` + `.duckOthers`로 음성 안내를 음악 위에 겹친다. Cadenza는 **음악 자체가 핵심 출력**이므로 다른 앱 오디오를 끼워넣으면 안 된다.

단, 다른 러닝 앱의 음성 안내가 Cadenza 위에 나오는 건 **그 앱이 duck을 요청하는 것**이므로 우리가 통제할 수 없음 → Cadenza 볼륨이 잠시 줄었다 복구되는 건 허용.

### 1.3 인터럽트 처리

| 인터럽트 원인 | 동작 | 복구 |
|---|---|---|
| **전화 수신** | 즉시 일시정지 (음악 + 메트로놈 모두) | 통화 종료 후 **자동 재개** |
| **Siri 활성화** | 즉시 일시정지 | Siri 종료 후 자동 재개 |
| **알림 소리** (짧은) | 볼륨 duck → 복구 (시스템이 처리) | 자동 |
| **알람 (시계 앱)** | 즉시 일시정지 | 알람 해제 후 자동 재개 |
| **다른 앱이 오디오 세션 가져감** | 일시정지 | Cadenza로 돌아왔을 때 **사용자가 수동 재개** (자동 재개하면 의도치 않은 소리 발생 위험) |
| **타이머/스톱워치 알림** | 볼륨 duck | 자동 복구 |

구현:

```swift
NotificationCenter.default.addObserver(
    forName: AVAudioSession.interruptionNotification,
    object: nil, queue: .main
) { notification in
    guard let info = notification.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    
    switch type {
    case .began:
        // 일시정지 (UI 상태도 동기화)
        pausePlayback()
    case .ended:
        let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            // 자동 재개 가능한 인터럽트 (전화, Siri 등)
            resumePlayback()
        }
        // shouldResume 없으면 사용자 수동 재개 대기
    @unknown default:
        break
    }
}
```

### 1.4 오디오 라우트 변경 처리

| 이벤트 | 동작 | 근거 |
|---|---|---|
| **헤드폰/이어폰 언플러그** | **즉시 일시정지** | Apple HIG 표준. 갑자기 스피커로 소리 나면 안 됨 |
| **블루투스 이어폰 연결** | 자동 전환 (시스템 처리) | 추가 작업 불필요 |
| **블루투스 이어폰 연결 끊김** | 즉시 일시정지 | 헤드폰 언플러그와 동일 |
| **AirPlay 전환** | 자동 (시스템 처리) | 러닝 중 AirPlay 쓸 일은 적지만 지원 |
| **CarPlay 연결** | 자동 전환 | 기본 동작 유지 |

구현:

```swift
NotificationCenter.default.addObserver(
    forName: AVAudioSession.routeChangeNotification,
    object: nil, queue: .main
) { notification in
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
    
    switch reason {
    case .oldDeviceUnavailable:
        // 헤드폰/블루투스 끊김 → 즉시 일시정지
        pausePlayback()
    default:
        break
    }
}
```

### 1.5 Apple Music 곡과의 세션 공존 (v1)

v1에서 MusicKit `ApplicationMusicPlayer`를 쓸 때:
- `ApplicationMusicPlayer`는 **시스템 음악 플레이어**를 제어하므로, 앱의 `AVAudioEngine`과 별도 오디오 세션
- 메트로놈은 앱의 `AVAudioEngine`에서 재생
- 두 오디오 출력이 동시에 나감 → 이때는 메트로놈 쪽에 `.mixWithOthers` 필요할 수 있음
- **v1 설계 시 재검토 필요** — 여기서는 v0(로컬 파일 only) 기준으로만 확정

**v1 세션 공존 방향성 (사전 기록)**

v1에서 예상되는 구조:
- 메트로놈: 앱의 `AVAudioEngine`에서 재생, `.mixWithOthers` 옵션 사용
- Apple Music 곡: `ApplicationMusicPlayer`가 시스템 세션에서 재생
- 두 출력이 동시에 나감 (시스템 믹서에서 합쳐짐)
- 이 변경은 v0의 "다른 앱 오디오와 믹싱 안 함" 정책의 **예외**
- v1 설계 시 `AVAudioSession.setCategory(.playback, options: [.mixWithOthers])` 프로토타입 테스트 필수
- 부작용: `.mixWithOthers` 사용 시 다른 러닝 앱(NRC 등) 음성 안내와도 섞일 수 있음 → 의도된 동작인지 v1에서 판단

### 1.6 오디오 엔진 상태 머신

플레이어의 가능한 상태와 전이 규칙을 명시한다.

```
IDLE ──(파일 선택)──▶ LOADING ──(성공)──▶ READY
  ▲                     │                    │
  │                (실패)│                (재생)│
  │                     ▼                    ▼
  │                   ERROR            PLAYING
  │                                     │   │
  │                                 (정지) (인터럽트)
  │                                    │    │
  │                                    ▼    ▼
  │                                 PAUSED  INTERRUPTED
  │                                    │        │
  │                               (재생)│    (복구)│
  └────────────────────────────────────┴────────┘
```

**전이 규칙**

| 현재 상태 | 이벤트 | 다음 상태 | 비고 |
|---|---|---|---|
| IDLE | 파일 선택 | LOADING | 파일 피커에서 URL 받음 |
| LOADING | 로드 성공 | READY | AVAudioFile 생성 + 노드 연결 완료 |
| LOADING | 로드 실패 | ERROR | F-01~F-05 에러 표시 |
| LOADING | 다른 파일 선택 | LOADING | 현재 로딩 취소, 새 파일로 재시작 |
| READY | 재생 버튼 | PLAYING | 엔진 start + 스케줄링 |
| PLAYING | 정지 버튼 | PAUSED | 엔진 pause |
| PLAYING | 인터럽트 발생 | INTERRUPTED | 1.3장 인터럽트 처리 참조 |
| PLAYING | 곡 끝 | PLAYING | 자동 반복 (v0), 다음 곡 (v0.5+) |
| PAUSED | 재생 버튼 | PLAYING | 엔진 resume |
| PAUSED | 파일 선택 | LOADING | 새 파일 로드 |
| INTERRUPTED | shouldResume | PLAYING | 자동 재개 (전화, Siri 등) |
| INTERRUPTED | shouldResume 없음 | PAUSED | 사용자 수동 재개 대기 |
| INTERRUPTED | 정지 버튼 | PAUSED | 인터럽트 상태에서 명시적 정지 |
| ERROR | 파일 재선택 | LOADING | 에러 해소 시도 |
| ERROR | 아무 조작 없음 | IDLE | 타임아웃 또는 닫기 |
| * | 앱 백그라운드 킬 | IDLE | S-01 참조, 다음 실행 시 마지막 설정 복원 |

**불가능한 전이 (명시적 차단)**
- PLAYING → LOADING: 재생 중 파일 변경 불가 (UI에서 파일 선택 버튼 비활성)
- LOADING → PLAYING: 로드 완료 전 재생 불가 (재생 버튼 비활성)

### 1.7 BPM 분석 스레딩 정책

BPM 자동 분석(v0b)은 메인 스레드에서 실행하면 안 된다. 30초 분량 PCM 처리에 1~5초 소요.

**정책**:
- BPM 분석은 **Swift Concurrency `Task { }`** 또는 별도 `DispatchQueue(label: "com.cadenza.bpm-analysis", qos: .userInitiated)`에서 실행
- 분석 시작 시 UI는 진행 상태 표시 (DESIGN.md 2.3 참조)
- 분석 완료 시 `@MainActor`에서 결과를 UI에 반영
- 사용자가 "건너뛰기" 누르면 `Task.cancel()` 또는 분석 플래그로 중단
- 분석 중 앱이 백그라운드로 가면: 분석은 계속 진행 (CPU 작업이므로 짧은 시간 허용됨)

### 1.8 앱 상태 매트릭스

각 상태에서 사용자가 보는 것, 활성화된 컨트롤, fallback, 이벤트 로그를 정의.

| 상태 | 사용자가 보는 것 | 활성 컨트롤 | fallback | 이벤트 |
|---|---|---|---|---|
| **no_file_selected** | empty state (DESIGN 2.2.1), "음악을 선택하거나 메트로놈만 사용하세요" | 파일 선택, BPM 슬라이더, 프리셋, 메트로놈 토글, 재생(메트로놈 전용) | — | — |
| **file_selected_bpm_known** | 곡 제목 + 원곡 BPM + 목표 BPM + "키 락 ON" | 전체 컨트롤 | — | `track_loaded`, `bpm_detected` |
| **file_selected_bpm_analyzing** | 곡 제목 + 분석 진행 바 (DESIGN 2.3) | 건너뛰기, BPM 슬라이더(목표만), 메트로놈 | 건너뛰기 → 탭 템포/수동 입력 | — |
| **analysis_failed** | "BPM을 감지하지 못했습니다" + 탭 템포 UI | 탭 템포, 수동 입력, 파일 재선택 | 수동 입력 | `analysis_failed` |
| **playback_active** | 곡 정보 + BPM + 재생 중 표시 | BPM 슬라이더, 프리셋, 메트로놈 토글/볼륨, 정지 버튼. **파일 선택 비활성** | — | `run_started` |
| **playback_paused** | 곡 정보 + BPM + 일시정지 표시 | 전체 컨트롤 (파일 선택 포함) | — | — |
| **background** | 락스크린 Now Playing (v0b+): 곡 제목, play/pause | 이어폰 리모트 play/pause (v0b+) | 앱 복귀 후 수동 재개 | — |
| **interrupted** | (화면 안 보임, 전화/Siri 등) | 없음 (시스템이 제어) | shouldResume 시 자동 재개 | — |
| **headphone_unplugged** | 자동 일시정지, 별도 메시지 없음 | 재생 버튼으로 재개 | — | — |
| **error** | 에러 배너 (DESIGN 2.2.2) + 복구 버튼 | 복구 액션 (파일 재선택 등) | SPEC 2장 에러 카탈로그 참조 | 에러 ID 로깅 |
| **metronome_only** | 메트로놈 단독 모드 (DESIGN 2.2) | BPM 슬라이더, 프리셋, 메트로놈 볼륨, 재생(메트로놈), 파일 선택 | — | `run_started` (hasFile=false) |

**불가능한 상태 조합** (방어 필요):
- `playback_active` + `no_file_selected`: 발생 불가. 파일 없이 음악 재생 불가 (메트로놈 단독은 별도 상태)
- `bpm_analyzing` + `playback_active`: 분석 완료 전 재생 시작 불가 (재생 버튼 비활성)
- `background` + `bpm_analyzing`: 분석은 계속 진행되지만 UI 업데이트는 복귀 시

---

## 2. 에러 / 엣지케이스 카탈로그

각 에러 상태별로 **원인 → 사용자 메시지 → 복구 액션**을 정의.

### 2.1 파일 관련

| ID | 에러 상태 | 원인 | 사용자 메시지 (ko) | 복구 액션 |
|---|---|---|---|---|
| F-01 | 파일 로드 실패 | 파일 손상, 읽기 권한 없음 | "파일을 열 수 없습니다" | 다른 파일 선택 유도 |
| F-02 | 지원하지 않는 포맷 | WMA, OGG 등 AVAudioFile 미지원 | "지원하지 않는 파일 형식입니다. MP3 또는 M4A 파일을 선택해주세요" | 파일 선택으로 돌아감 |
| F-03 | Security-scoped bookmark 만료 | 앱 재시작 후 파일 접근 토큰 만료 | "파일 접근 권한이 만료되었습니다" | 파일 다시 선택 |
| F-04 | 파일 삭제됨 | 사용자가 외부에서 파일 삭제 | "파일을 찾을 수 없습니다" | 파일 선택으로 돌아감 |
| F-05 | iCloud 파일 미다운로드 | iCloud Drive 파일이 로컬에 없음 | "파일이 아직 다운로드되지 않았습니다. 파일 앱에서 먼저 다운로드해주세요" | 파일 선택으로 돌아감 |

### 2.2 오디오 엔진

| ID | 에러 상태 | 원인 | 사용자 메시지 | 복구 액션 |
|---|---|---|---|---|
| A-01 | 엔진 시작 실패 | AVAudioSession 설정 실패, 하드웨어 문제 | "오디오 재생을 시작할 수 없습니다. 앱을 재시작해주세요" | 앱 재시작 안내 |
| A-02 | 재생 중 엔진 정지 | 시스템 리소스 부족, 백그라운드 킬 | 앱 복귀 시 "재생이 중단되었습니다" | 재생 버튼으로 재시작 |
| A-03 | TimePitch rate 범위 초과 | originalBPM이 극단적으로 작거나 큼 | "이 곡은 목표 BPM과 차이가 너무 큽니다" | rate를 클램핑하고 경고 배지 표시 |
| A-04 | playbackRate 계산 불가 | originalBPM이 0 또는 nil (모든 BPM 소스 실패 + 사용자가 입력 건너뜀) | (내부) rate를 1.0으로 폴백 | 기본값 120 BPM 적용 + "원곡 BPM을 설정해주세요" 배너 표시. `targetBPM / 0` division by zero 절대 방지 |
| A-05 | 메트로놈 백그라운드 정확도 저하 | iOS가 백그라운드에서 Timer를 throttle함 | (사용자에게 별도 안내 없음) | **알려진 제약**. v0~v1은 Timer 기반이므로 장시간 백그라운드에서 메트로놈 간격이 부정확해질 수 있음. v2에서 AVAudioEngine sampleTime 기반으로 해결 예정. PLANNING.md 6.7 참조 |

### 2.3 BPM 분석

| ID | 에러 상태 | 원인 | 사용자 메시지 | 복구 액션 |
|---|---|---|---|---|
| B-01 | 메타데이터 BPM 없음 | 태그에 TBPM 미기록 | (사용자에게 안 보임, 자동으로 레이어 2로 진행) | 자동 분석 시도 |
| B-02 | 자동 분석 실패 | 비트 없는 앰비언트/클래식, 극단적 장르 | "BPM을 자동으로 감지하지 못했습니다" | 탭 템포 UI 자동 표시 |
| B-03 | 더블/하프 BPM 의심 | 분석 결과가 70~95 구간 (하프) 또는 극단값 | "감지된 BPM: 87. 혹시 174가 맞나요?" | 두 선택지 버튼 (87 / 174) |
| B-04 | 분석 시간 초과 | 파일이 매우 크거나 디코딩 느림 | "분석 시간이 오래 걸리고 있습니다" | 건너뛰기 → 탭 템포 |

### 2.4 오디오 출력

| ID | 에러 상태 | 원인 | 사용자 메시지 | 복구 액션 |
|---|---|---|---|---|
| O-01 | 헤드폰 언플러그 | 유선 이어폰 빠짐 | (자동 일시정지, 별도 메시지 없음) | 재생 버튼으로 재개 |
| O-02 | 블루투스 연결 끊김 | 이어폰 배터리 소진, 범위 이탈 | "블루투스 연결이 끊겼습니다" | 자동 일시정지, 재연결 후 수동 재개 |
| O-03 | 블루투스 전환 중 끊김 | A2DP → HFP 전환 (Siri 등) | 일시적 오디오 끊김 (시스템 처리) | 자동 복구 |

### 2.5 시스템 / 라이프사이클

| ID | 에러 상태 | 원인 | 사용자 메시지 | 복구 액션 |
|---|---|---|---|---|
| S-01 | 백그라운드 킬 | iOS 메모리 압박으로 앱 종료 | (다음 실행 시) "이전 재생이 중단되었습니다" | 마지막 설정 복원 (UserDefaults), 파일 재선택 필요 |
| S-02 | 포그라운드 복귀 시 엔진 상태 불일치 | 오래 백그라운드 후 복귀 | (자동 감지, 엔진 재시작 시도) | 실패 시 A-01과 동일 |

### 2.6 Apple Music (v1)

| ID | 에러 상태 | 원인 | 사용자 메시지 | 복구 액션 |
|---|---|---|---|---|
| M-01 | Apple Music 권한 거부 | 사용자가 라이브러리 접근 거부 | "Apple Music에 접근할 수 없습니다. 설정에서 권한을 허용해주세요" | 설정 앱 열기 버튼 + 로컬 파일 모드 사용 안내 |
| M-02 | Apple Music 구독 없음 | 무료 사용자 | "Apple Music 구독이 필요합니다. 로컬 파일은 계속 사용할 수 있습니다" | 로컬 파일 모드로 전환 |
| M-03 | 곡 재생 실패 | 지역 제한, 곡 삭제됨 | "이 곡을 재생할 수 없습니다" | 다음 곡으로 자동 건너뛰기 (플레이리스트 모드 시) |
| M-04 | 프리뷰 URL 없음 (실험 기능) | 카탈로그에 프리뷰 미제공 | (사용자에게 안 보임) | 자동으로 수동 입력 fallback |

### 2.7 에러 표시 원칙

1. **조용히 해결할 수 있으면 조용히** — 사용자에게 불필요한 에러 팝업 안 띄움
2. **복구 액션은 반드시 1개 이상** — "확인" 버튼만 있는 에러 다이얼로그 금지
3. **러닝 중엔 최소한의 시각 표시** — 배너 노티 스타일 (3초 후 자동 사라짐). 전체 화면 모달 안 씀
4. **연쇄 에러 방지** — 같은 에러 3회 반복 시 추가 알림 안 함 (세션당)

### 2.8 BPM 입력 검증 규칙

사용자가 직접 입력하는 BPM 값에 대한 검증 정책.

| 입력 필드 | 유효 범위 | 범위 밖 동작 | 빈 입력 동작 |
|---|---|---|---|
| 원곡 BPM 수동 입력 | 30~300 | 입력 거부 + 빨간 테두리 + "30~300 사이 값을 입력해주세요" | 기본값 120 유지 |
| 목표 BPM 슬라이더 | 140~200 | 슬라이더 자체가 범위 제한 (UI 레벨 차단) | N/A |
| 목표 BPM 프리셋 | 고정값 (160/165/170/175/180) | N/A | N/A |

**division by zero 방어**: `playbackRate` 계산 시 `originalBPM`이 0 이하이면 기본값 120을 강제 적용하고 A-04 에러 처리.

### 2.9 탭 템포 상세 사양 (v0c)

사용자가 곡에 맞춰 화면을 반복 탭하여 BPM을 추정하는 기능.

| 항목 | 값 | 근거 |
|---|---|---|
| 최소 탭 횟수 | 4회 | 3회 이하는 편차가 커서 신뢰도 낮음 |
| 유효 BPM 범위 | 60~220 | 범위 밖 탭 간격은 무시 (실수 탭으로 간주) |
| 리셋 타임아웃 | 마지막 탭 후 3초 | 3초 동안 탭 없으면 측정 완료 → 결과 제시 |
| 신뢰도 판정 | 탭 간격 표준편차 > 20% | "측정이 불안정합니다. 다시 탭해주세요" 표시, 재탭 유도 |
| 재생 중 사용 | 가능 | 곡을 들으며 박자에 맞춰 탭 가능 |
| 결과 표시 | 소수점 없이 정수 BPM | 예: 173, 87 등. 더블/하프 의심 시 B-03 처리 |

**동작 흐름**:
1. 탭 템포 UI 진입 (자동 분석 실패 시 자동 또는 사용자 선택)
2. 사용자 탭 시작 → 2번째 탭부터 실시간 BPM 표시
3. 4회 이상 탭 후 3초 무탭 → 최종 BPM 확정
4. 신뢰도 낮으면 재탭 유도, 높으면 결과 적용
5. "이 BPM 사용" / "다시 측정" 선택

---

## 3. 테스트 계획

이 앱은 시뮬레이터보다 **실기기 + 실제 러닝** 테스트가 훨씬 중요하다.

### 3.1 단위 테스트 (XCTest)

| 영역 | 테스트 항목 | v0 적용 |
|---|---|---|
| BPM 계산 | `playbackRate = target / original` 경계값 (0, 극단값, 동일값) | ✅ |
| 메타데이터 읽기 | TBPM 태그 있는/없는 파일 | ✅ |
| BPM 분석 | 알려진 BPM 곡에 대해 ±3 정확도 | v0b |
| 메트로놈 간격 | BPM 60~200 범위에서 interval 계산 정확성 | v0b |
| UserDefaults | 저장/복원 정상 동작 | v0c |

### 3.2 통합 테스트 (수동, 실기기)

#### 재생 기본

| # | 시나리오 | 기대 결과 | v0 단계 |
|---|---|---|---|
| P-01 | MP3 파일 선택 → 재생 | 소리 나옴, 피치 유지 템포 변경 적용 | v0a |
| P-02 | M4A 파일 선택 → 재생 | 동일 | v0a |
| P-03 | FLAC 파일 선택 | 에러 메시지 F-02 표시 | v0a |
| P-04 | 재생 중 BPM 슬라이더 변경 | 즉시 속도 변경, 끊김 없음 | v0a |
| P-05 | rate 0.85x (120→175) | 음질 수용 가능 | v0a |
| P-06 | rate 1.15x (200→175) | 음질 수용 가능 | v0a |
| P-07 | rate 0.5x (극단) | 경고 배지 표시, 재생은 됨 | v0a |
| P-08 | 곡 끝까지 재생 | 자동 반복 | v0a |

#### 메트로놈

| # | 시나리오 | 기대 결과 | v0 단계 |
|---|---|---|---|
| M-01 | 메트로놈 ON + 재생 | 음악과 메트로놈 동시 출력 | v0b |
| M-02 | 메트로놈 볼륨 0 | 메트로놈 안 들림, 음악만 | v0b |
| M-03 | 메트로놈 볼륨 1.0 | 클릭이 음악보다 잘 들림 | v0b |
| M-04 | 재생 중 메트로놈 토글 | 즉시 on/off, 끊김 없음 | v0b |
| M-05 | 강박/약박 구분 | 4박 중 1박이 더 높은 톤/크기 | v0b |
| M-06 | BPM 변경 시 메트로놈 동기 | 메트로놈도 즉시 새 BPM | v0b |
| M-07 | 메트로놈 단독 모드 | 곡 없이 메트로놈만 재생 | v0c |

#### 백그라운드 / 인터럽트

| # | 시나리오 | 기대 결과 | v0 단계 |
|---|---|---|---|
| BG-01 | 재생 중 홈 버튼 | 소리 계속 나옴 | v0b |
| BG-02 | 재생 중 잠금 화면 | 소리 계속 나옴 | v0b |
| BG-03 | 백그라운드 30분 유지 | 끊김 없음 | v0b |
| BG-04 | 재생 중 전화 수신 → 끊기 | 일시정지 → 자동 재개 | v0b |
| BG-05 | 재생 중 Siri 활성화 → 종료 | 일시정지 → 자동 재개 | v0b |
| BG-06 | 재생 중 알람 울림 → 해제 | 일시정지 → 자동 재개 | v0b |
| BG-07 | 유선 이어폰 빼기 | 즉시 일시정지 | v0b |
| BG-08 | 블루투스 이어폰 끊김 | 즉시 일시정지 | v0b |
| BG-09 | 다른 음악 앱 재생 시작 | Cadenza 일시정지. 돌아오면 수동 재개 | v0b |

#### BPM 분석

| # | 시나리오 | 기대 결과 | v0 단계 |
|---|---|---|---|
| BPM-01 | TBPM 태그 있는 MP3 | 자동으로 원곡 BPM 표시, 분석 안 함 | v0a |
| BPM-02 | 태그 없는 MP3, 전자음악 (비트 명확) | 자동 분석 성공, ±3 이내 | v0b |
| BPM-03 | 태그 없는 MP3, 발라드 (비트 불명확) | 분석 실패 또는 부정확 → 탭 템포 제시 | v0b→v0c |
| BPM-04 | 태그 없는 MP3, 하프타임 곡 | 더블/하프 BPM 선택지 제시 | v0b |

### 3.3 오디오 출력 디바이스 테스트

| # | 출력 | 테스트 포인트 |
|---|---|---|
| D-01 | iPhone 내장 스피커 | 재생 동작 확인 (러닝엔 안 쓰지만 기본 확인) |
| D-02 | 유선 이어폰 (Lightning/USB-C) | 정상 재생 + 언플러그 처리 |
| D-03 | AirPods (Pro/Max) | 블루투스 재생 + 연결 끊김 처리 + Spatial Audio 영향 없음 확인 |
| D-04 | 타사 블루투스 이어폰 | 연결/끊김 처리 |
| D-05 | CarPlay (선택) | 연결 시 자동 전환 |

### 3.4 파일 포맷 테스트

| # | 포맷 | 기대 결과 |
|---|---|---|
| FF-01 | MP3 CBR 128kbps | 정상 재생 |
| FF-02 | MP3 VBR 320kbps | 정상 재생 |
| FF-03 | M4A (AAC) 256kbps | 정상 재생 |
| FF-04 | M4A (ALAC) lossless | 정상 재생 |
| FF-05 | WAV 16bit 44.1kHz | 정상 재생 |
| FF-06 | FLAC | 에러 F-02 (AVAudioFile 미지원) |
| FF-07 | OGG | 에러 F-02 |
| FF-08 | DRM 보호 M4P | 에러 F-01 |

### 3.5 러닝 필드 테스트

**가장 중요한 테스트.** 시뮬레이터로는 알 수 없는 것들.

| # | 시나리오 | 체크 포인트 |
|---|---|---|
| R-01 | 5km 러닝 (야외, 이어폰) | 30분 끊김 없는 재생 |
| R-02 | 위와 동일 | 메트로놈이 음악 위에 잘 들리는가 |
| R-03 | 위와 동일 | 달리면서 BPM 숫자가 읽히는가 (햇빛 아래) |
| R-04 | 위와 동일 | 프리셋 버튼이 한 손으로 탭 가능한가 |
| R-05 | 10km 러닝 (~50분) | 메트로놈 드리프트 체감 여부. 참고: ±300ms/10분 기준이면 50분 후 ±1.5초(약 4비트 @175spm). 외부 메트로놈 앱과 동시 재생해서 비교 |
| R-06 | 러닝 중 전화 수신 → 끊기 → 재개 | 자동 재개 정상 동작 |
| R-07 | 러닝 후 Garmin 데이터와 비교 | 목표 케이던스 유지에 주관적으로 도움이 됐는가 |
| R-08 | 러닝 후 총평 | "다음에도 쓸 것인가?" (Y/N) |

### 3.6 장시간 재생 테스트

| # | 시나리오 | 체크 포인트 |
|---|---|---|
| L-01 | 1시간 연속 재생 (실기기, 백그라운드) | 끊김, 메모리 누수, 배터리 소모율 |
| L-02 | 2시간 연속 재생 (LSD 러닝 시뮬레이션) | 위와 동일 + 메트로놈 드리프트. 기준: 30분 후 ±1초, 1시간 후 ±2초, 2시간 후 ±5초 이내면 Timer 기반으로 충분. 초과 시 v2 sampleTime 기반 재구현 우선순위 상향 |
| L-03 | 밤새 재생 (극한 테스트) | 메모리 증가 추이, 크래시 여부 |

### 3.7 Eng Review 추가 테스트 항목

Eng Review에서 식별된 커버리지 갭. 기존 테스트 계획에 추가.

| # | 시나리오 | 기대 결과 | v0 단계 |
|---|---|---|---|
| ENG-01 | 0바이트 MP3 파일 선택 | 에러 F-01 표시, 크래시 없음 | v0a |
| ENG-02 | DRM 보호 M4P 파일 선택 | 에러 F-01 표시, 크래시 없음 | v0a |
| ENG-03 | 곡 끝 → completion handler 재스케줄 | 갭 없이 반복 재생, 크래시 없음 | v0a |
| ENG-04 | originalBPM=0 (메타데이터 BPM이 0인 파일) | 기본값 120 적용, A-04 배너, division by zero 없음 | v0a |
| ENG-05 | 메타데이터에 TBPM=0 또는 TBPM=-1인 파일 | 값 무시, 자동 분석 또는 기본값으로 진행 | v0a |
| ENG-06 | 온보딩 건너뛰기 → 메인 화면 | empty state 화면 (DESIGN 2.2.1) 정상 표시 | v0a |

### 3.8 테스트 우선순위

**v0a 출시 전 필수**: P-01~P-06, P-08, BPM-01, FF-01~FF-05, ENG-01, ENG-03, ENG-04, ENG-05, ENG-06
**v0b 출시 전 필수**: M-01~M-06, BG-01~BG-09, BPM-02~BPM-04, D-02~D-04
**v0 검증 전 필수**: R-01~R-08, L-01

---

## 4. 용어집

개발 중 혼선을 막기 위한 용어 정의. PLANNING.md, DESIGN.md, 코드 주석에서 동일한 의미로 사용.

| 용어 | 정의 | 비고 |
|---|---|---|
| **BPM** | Beats Per Minute. 1분당 박자 수. 음악의 템포를 나타내는 단위 | 음악 맥락에서 사용 |
| **spm** | Steps Per Minute. 1분당 보수(발걸음 수). 러닝 케이던스 단위 | 러닝 맥락에서 사용 |
| **케이던스 (cadence)** | 러닝에서 1분당 발걸음 수. 보통 160~190 spm 범위. "케이던스 175"는 175 spm을 의미 | 이 앱에서는 spm과 동의어 |
| **목표 BPM / 목표 케이던스** | 사용자가 달리고 싶은 케이던스. 이 값에 맞춰 음악 속도와 메트로놈을 조절 | UI에서 가장 큰 숫자 |
| **원곡 BPM** | 음악 파일의 원래 템포. 메타데이터 태그, 자동 분석, 탭 템포 등으로 확보 | |
| **playbackRate** | 재생 속도 비율. `목표 BPM / 원곡 BPM`으로 계산. 1.0 = 원래 속도 | |
| **피치 (pitch)** | 소리의 높낮이. 재생 속도를 바꾸면 보통 피치도 같이 변함 | |
| **피치 락 (key lock)** | 재생 속도를 바꿔도 피치를 유지하는 기술. 타임스트레치의 한 형태 | DJ 용어: "master tempo" |
| **타임스트레치 (time-stretch)** | 오디오의 시간축만 늘이거나 줄이는 기술. 피치를 유지하면서 속도 변경 | AVAudioUnitTimePitch가 이걸 함 |
| **다람쥐 소리** | 피치 락 없이 재생 속도만 올렸을 때 높아진 음성. Apple Music 곡에서 발생 | |
| **강박 (downbeat)** | 마디의 첫 번째 박자. 메트로놈에서 더 강조됨 | |
| **약박 (upbeat)** | 강박이 아닌 나머지 박자. 메트로놈에서 상대적으로 약함 | |
| **DRM** | Digital Rights Management. Apple Music 스트리밍 곡에 적용된 저작권 보호 기술 | 이 때문에 Apple Music 곡은 피치 락 불가 |
| **프리뷰 URL** | Apple Music 카탈로그 곡의 30초 미리듣기 오디오 파일 URL. DRM 없음 | BPM 분석용으로 사용 가능 (v1 실험 기능) |
| **탭 템포 (tap tempo)** | 사용자가 음악에 맞춰 화면을 반복 탭하면 탭 간격으로 BPM을 추정하는 방식 | 자동 분석 실패 시 fallback |
| **MusicKit** | Apple의 음악 프레임워크. Apple Music 카탈로그 접근, 재생 등 | Swift 버전과 JS 버전 있음 |
| **AVAudioEngine** | Apple의 실시간 오디오 처리 엔진. 노드 그래프 기반 | 로컬 파일 재생 + 메트로놈에 사용 |
| **AVAudioUnitTimePitch** | AVAudioEngine의 노드. rate(속도)와 pitch(음높이)를 독립 제어 | rate 변경 시 pitch=0으로 피치 락 |

---

*최종 수정: 2026-04-16*
