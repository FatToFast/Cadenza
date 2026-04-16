# Cadenza — Operations

> 배포 전략, 라이센스, 분석/로깅, 버전 관리, 프라이버시 정책.
> 코드 품질이 아닌 "코드 바깥"의 운영 요소를 정의한 문서.

---

## 1. 배포 전략

### 1.1 단계별 배포 채널

| 단계 | 채널 | 대상 | 비고 |
|---|---|---|---|
| v0a~v0c | **Xcode 직접 설치** | 본인 기기만 | 무료 Apple ID 개인 프로비저닝 (7일 갱신) |
| v0.5 | **TestFlight 내부** | 본인 + 테스트용 기기 | Apple Developer Program 가입 필요 ($99/년) |
| v1 | **TestFlight 외부** | 가족/친구 5~10명 | 이메일 초대, 최대 10,000명 |
| v1.5 | TestFlight 외부 확대 | 러닝 커뮤니티 소규모 | 피드백 루프 확립 |
| v2+ | **App Store** (조건부) | 일반 공개 | 주간 활성 100명 이상일 때만 검토 |

### 1.2 Apple Developer Program 가입 시점

- **v0a~v0c**: 가입 불필요. 무료 Apple ID로 실기기 설치 가능 (7일마다 재서명)
- **v0.5 시작 시**: 가입 필요 ($99/년). TestFlight 배포 + 프로비저닝 프로파일 1년 유효
- 이미 가입되어 있으면 즉시 사용 가능

### 1.3 TestFlight 운영 정책

- **빌드 주기**: 기능 단위로 올림 (일일 빌드 아님)
- **베타 만료**: 90일 (TestFlight 기본값)
- **피드백 수집**: TestFlight 내장 피드백 + 간단한 구글폼 링크
- **크래시 리포트**: TestFlight 자동 수집 (Xcode Organizer에서 확인)

### 1.4 App Store 출시 전 체크리스트 (v2+)

해당 시점에 상세화하지만, 미리 인지해둘 항목:

- [ ] 프라이버시 정책 URL (5장 참조)
- [ ] 앱 아이콘 최종 디자인 (1024x1024)
- [ ] 스크린샷 5장 이상 (iPhone 6.7", 6.1")
- [ ] 앱 설명 (한국어 + 영어)
- [ ] 카테고리: Music 또는 Health & Fitness
- [ ] 연령 등급: 4+
- [ ] MusicKit 엔타이틀먼트 (v1 이후)
- [ ] 가격: 무료 (v2 초기), 유료/IAP는 사용자 반응 후 검토
- [ ] App Review 가이드라인 준수 확인

---

## 2. 라이센스

### 2.1 정책

**v0~v1.5: 비공개 (Private Repository)**

근거:
- 개인 도구로 시작. 공개할 이유가 아직 없음
- 오픈소스로 전환은 언제든 가능하지만, 반대는 어려움
- Apple Music 연동 코드에 API 키/토큰이 포함될 수 있음

### 2.2 오픈소스 전환 조건 (미래)

아래 중 하나 이상 해당하면 전환 검토:
- App Store 출시 후 커뮤니티 기여 요청이 있을 때
- 유사 앱을 만들려는 개발자에게 도움이 될 때
- 본인이 프로젝트를 더 이상 유지보수하지 않을 때

전환 시 라이센스 후보: **MIT** (가장 관대, 간단)

### 2.3 서드파티 라이센스 관리

v0에서 외부 라이브러리 사용이 거의 없지만, 추가 시:
- SPM(Swift Package Manager)으로 관리
- 라이센스 호환성 확인 (MIT/Apache/BSD 선호, GPL 피함)
- Settings.bundle에 오픈소스 라이센스 고지 포함 (v1+)

---

## 3. 분석 / 로깅

### 3.1 단계별 도구

| 단계 | 크래시 리포팅 | 사용 분석 | 로깅 |
|---|---|---|---|
| v0 | Xcode 콘솔 + `os_log` | 없음 | `os_log` (`.debug`, `.error`) |
| v0.5~v1 | TestFlight 자동 수집 | 없음 | `os_log` + 파일 로그 (선택) |
| v1.5+ | Firebase Crashlytics 또는 Sentry (검토) | 최소 이벤트 (선택) | 구조화된 로깅 |
| v2+ | 위와 동일 | App Store Connect App Analytics | 위와 동일 |

### 3.2 v0 로깅 정책

```swift
import os

private let logger = Logger(subsystem: "com.cadenza.app", category: "AudioEngine")

// 사용 예시
logger.debug("File loaded: \(url.lastPathComponent)")
logger.info("BPM detected: \(bpm) from metadata")
logger.error("Engine start failed: \(error.localizedDescription)")
```

로그 레벨:
- `.debug`: 개발 중 디버깅 (릴리즈에서 자동 제거)
- `.info`: 주요 이벤트 (파일 로드, BPM 감지, 재생 시작)
- `.error`: 에러 (SPEC.md 2장 에러 카탈로그 ID와 매핑)

### 3.3 이벤트 로그 카탈로그

성공 지표(PLANNING.md 10장)를 실제 의사결정으로 연결하려면 최소한의 이벤트 관측이 필요하다. 아래는 v0부터 `os_log(.info)`로 기록하는 이벤트 목록이다. v0에서는 로컬 저장만. 외부 전송은 v1.5+ 에서 프라이버시 정책(5장) 하에 선택적으로 추가 검토.

| 이벤트 | 기록 시점 | 기록 데이터 | 도입 버전 | 의사결정 활용 |
|---|---|---|---|---|
| `run_started` | 재생 버튼 첫 탭 | targetBPM, hasFile, metronomeOn | v0a | 세션 빈도 추적 |
| `track_loaded` | 파일 선택 완료 | fileFormat, fileSizeMB, hasBPMTag | v0a | 파일 포맷 분포 |
| `bpm_detected` | BPM 확보 성공 | source(metadata/analysis/tap/manual), value, confidence | v0a | 자동 감지 커버리지 |
| `bpm_corrected` | 사용자가 BPM 보정 | oldValue, newValue, correctionType(double/half/manual) | v0b | double-time 빈도 → beat-step 분리 우선순위 판단 |
| `preset_selected` | 프리셋 버튼 탭 | presetValue | v0c | 어떤 케이던스가 가장 많이 쓰이는지 |
| `slider_changed` | 슬라이더 드래그 종료 | fromBPM, toBPM | v0a | 슬라이더 vs 프리셋 사용 비율 |
| `metronome_toggled` | 메트로놈 on/off | isOn, currentVolume | v0b | 메트로놈 실사용률 |
| `analysis_failed` | BPM 자동 분석 실패 | errorReason, fileFormat | v0b | 분석 알고리즘 개선 우선순위 |
| `pitch_warning_seen` | 피치 변화 경고 표시 | playbackRate | v1 | Apple Music 음질 문제 빈도 |
| `session_completed` | 재생 정지 또는 앱 백그라운드 킬 | totalDurationSec, tracksPlayed, targetBPM | v0a | 세션 길이 분포 → "30분 이상 사용" 지표 |
| `remote_command_used` | 락스크린/이어폰 리모트 명령 | commandType(play/pause) | v0b | 리모트 컨트롤 사용 빈도 |

**구현 방식 (v0)**:
```swift
logger.info("[run_started] targetBPM=\(targetBPM) hasFile=\(hasFile) metronomeOn=\(metronomeOn)")
```

**v0.5+ 구조화 (선택)**:
로컬 JSON 파일에 이벤트를 append. Xcode 콘솔에 안 남지만 앱 내에서 조회 가능.

**프라이버시**: 곡 제목, 아티스트, 파일 경로는 기록하지 않음. 파일 포맷과 크기만 기록.

### 3.4 외부 분석 도구 선택 기준 (v1.5+)

도입 검토 시 아래 기준:
- **프라이버시 우선**: 개인 식별 불가 데이터만 수집
- **최소 수집**: 크래시 + 앱 실행 횟수 + 세션 길이 정도
- **GDPR/개인정보보호법 준수**: 한국 개인정보보호법 기준 "개인정보"에 해당하지 않는 범위
- **무료 또는 저비용**: 개인 프로젝트 규모에 맞게

후보:
- Firebase Crashlytics (무료, 크래시만)
- TelemetryDeck (프라이버시 중심, 유럽 서버, 무료 티어)
- App Store Connect (무료, 기본 분석)

### 3.5 수집하지 않는 것

명시적으로 수집하지 않음:
- 사용자 음악 라이브러리 내용
- 재생한 곡 목록
- 위치 정보
- 개인 식별 정보 (이름, 이메일 등)
- 건강/운동 데이터

---

## 4. 버전 관리

### 4.1 버전 넘버링

**Semantic Versioning 변형** — 앱 특성에 맞게 조정

```
마케팅 버전 (CFBundleShortVersionString): X.Y.Z
  X = 메이저 (제품 경계 변화, 예: v2에서 운동 플랫폼 연동)
  Y = 마이너 (기능 추가, 예: Apple Music 통합)
  Z = 패치 (버그 수정)

빌드 넘버 (CFBundleVersion): YYYYMMDD.N
  예: 20260416.1, 20260416.2
```

매핑:
- v0a~v0c → 0.1.0 ~ 0.3.0
- v0.5 → 0.5.0
- v1 → 1.0.0
- v1.5 → 1.5.0
- v2 → 2.0.0

### 4.2 Git 전략

**v0~v1: 단순 trunk-based**

- `main` 브랜치 하나
- 기능 작업 시 짧은 feature 브랜치 → 작업 완료 후 main에 머지
- 태그: `v0.1.0`, `v0.2.0` 등 마일스톤마다

```
main ─────●────●────●────●────●─── ...
           │         │         │
           v0.1.0    v0.3.0    v1.0.0
```

v1.5+ 이후 협업자가 생기면 PR 기반으로 전환 검토.

### 4.3 커밋 컨벤션

```
feat: 새 기능 추가
fix: 버그 수정
refactor: 리팩터링 (기능 변화 없음)
docs: 문서 수정
test: 테스트 추가/수정
chore: 빌드, 설정 등 기타
```

예시:
```
feat: add metadata BPM tag reading (v0a)
fix: audio engine crash on background entry
docs: update PLANNING.md with review feedback
```

---

## 5. 프라이버시 정책

### 5.1 원칙

**"이 앱은 사용자 데이터를 수집하지 않는다"**를 기본 전제로 한다.

### 5.2 데이터 처리 요약

| 데이터 | 저장 위치 | 외부 전송 | 비고 |
|---|---|---|---|
| 선택한 음악 파일 | 기기 내 (security-scoped bookmark) | ❌ | 앱 삭제 시 bookmark도 삭제 |
| BPM 캐시 | 기기 내 (SwiftData) | v1.5+ Supabase 동기화 시 선택적 | 곡 제목/아티스트/BPM만, 파일 자체 아님 |
| 사용자 설정 | 기기 내 (UserDefaults → SwiftData) | v1.5+ Supabase 동기화 시 선택적 | 목표 BPM, 메트로놈 볼륨 등 |
| Apple Music 라이브러리 | Apple 서버 (MusicKit) | Apple만 처리 | v1+, 앱은 메타데이터만 읽음 |
| 크래시 로그 | TestFlight / Crashlytics | ✅ (익명) | v0.5+, 개인 식별 불가 |

### 5.3 App Store 프라이버시 라벨 (v2+)

App Store Connect 제출 시 선택:

- **Data Not Collected** (v0~v1, 외부 분석 없을 때)
- 또는 **Diagnostics → Crash Data** (Crashlytics 사용 시)

### 5.4 프라이버시 정책 문서

App Store 제출 시 URL 필수. 간단한 정적 페이지로 충분.

호스팅 옵션:
- GitHub Pages (무료, 간단)
- Notion 공개 페이지 (더 간단)
- 앱 내 번들 (인터넷 불필요)

내용 골자:
```
Cadenza 프라이버시 정책

1. Cadenza는 개인정보를 수집하지 않습니다.
2. 음악 파일과 설정은 사용자 기기에만 저장됩니다.
3. Apple Music 기능 사용 시 Apple의 프라이버시 정책이 적용됩니다.
4. 크래시 리포트는 익명으로 수집될 수 있으며, 앱 개선에만 사용됩니다.
5. 문의: [이메일 주소]

최종 수정: 2026-04-16
```

> 실제 출시 시 한국어/영어 버전 모두 필요.

### 5.5 Supabase 동기화 프라이버시 (v1.5+)

- 동기화는 사용자가 명시적으로 활성화할 때만
- 동기화 대상: BPM 캐시 + 사용자 설정만 (곡 제목/아티스트 포함)
- 음악 파일 자체는 절대 전송하지 않음
- 사용자가 언제든 동기화 끄기 + 서버 데이터 삭제 가능
- 서버 데이터는 사용자 UUID로만 식별 (이메일/이름 없음)

---

## 6. 릴리즈 체크리스트

각 마일스톤 릴리즈 전 확인 항목.

### 6.1 v0 릴리즈 체크리스트

```
코드
- [ ] 빌드 성공 (Warning 0개 권장, 필수는 아님)
- [ ] SPEC.md 3장 테스트 우선순위 "v0a/v0b 필수" 항목 전부 통과
- [ ] 메모리 누수 없음 (Instruments Leaks)
- [ ] 백그라운드 30분 재생 테스트 통과

문서
- [ ] PLANNING.md 최신 상태
- [ ] README.md 설치 방법 정확
- [ ] 알려진 이슈 목록 작성

검증
- [ ] 5km 이상 실제 러닝 1회 완료
- [ ] 러닝 후 자가 평가: "다음에도 쓸 것인가?" → Y
```

### 6.2 v1 릴리즈 체크리스트 (TestFlight 외부 배포)

```
위 v0 항목 전부 +

코드
- [ ] Apple Music 로그인/로그아웃 정상
- [ ] Apple Music 곡 100곡 플레이리스트 재생 안정
- [ ] 락스크린 Now Playing 정상 표시
- [ ] "피치 변경" 배지 정상 표시

배포
- [ ] TestFlight 빌드 업로드
- [ ] 베타 테스터 초대 메일 발송
- [ ] 피드백 수집 구글폼 준비
- [ ] 알려진 이슈/제한사항 안내 텍스트

법적
- [ ] Apple Developer Program 가입 확인
- [ ] MusicKit 엔타이틀먼트 활성화
```

### 6.3 v2 릴리즈 체크리스트 (App Store)

```
위 v1 항목 전부 +

스토어
- [ ] 앱 아이콘 1024x1024
- [ ] 스크린샷 (6.7", 6.1" 각 5장, 한국어 + 영어)
- [ ] 앱 설명 (한국어 + 영어)
- [ ] 프라이버시 정책 URL
- [ ] 프라이버시 라벨 설정

법적
- [ ] 프라이버시 정책 한국어/영어 게시
- [ ] 오픈소스 라이센스 고지 (Settings.bundle)

QA
- [ ] SPEC.md 3장 전체 테스트 통과
- [ ] 다양한 기기 테스트 (iPhone 15 Pro, SE 3, 구형 모델 1개 이상)
- [ ] iOS 17, 18 모두 테스트
```

---

## 7. 인프라 / 비용

### 7.1 현재 비용 (v0)

| 항목 | 비용 | 비고 |
|---|---|---|
| Xcode | 무료 | |
| Apple ID (개인 프로비저닝) | 무료 | 7일 갱신 |
| Claude Max | 이미 구독 중 | 개발 도구 |
| **합계** | **$0** | |

### 7.2 v0.5~v1 비용

| 항목 | 비용 | 비고 |
|---|---|---|
| Apple Developer Program | $99/년 | TestFlight + App Store 접근 |
| **합계** | **$99/년** | |

### 7.3 v1.5+ 비용 (Supabase 추가 시)

| 항목 | 비용 | 비고 |
|---|---|---|
| Apple Developer Program | $99/년 | |
| Supabase | 무료 티어 (500MB, 50K 요청/월) | 개인 사용 수준이면 충분 |
| 도메인 (프라이버시 정책 호스팅) | ~$12/년 (선택) | GitHub Pages 쓰면 무료 |
| **합계** | **$99~111/년** | |

---

## 8. 결정 기록 (Operations)

| 일자 | 결정 사항 | 근거 |
|---|---|---|
| 2026-04-16 | v0는 Xcode 직접 설치 (TestFlight 안 씀) | Developer Program 가입 전, 빠른 검증 우선 |
| 2026-04-16 | 비공개 리포지토리로 시작 | 개인 도구, API 키 보호, 나중에 오픈소스 전환 가능 |
| 2026-04-16 | v0 분석 도구: os_log만 | 외부 SDK 의존성 0, 디버깅 충분 |
| 2026-04-16 | Git trunk-based 전략 | 1인 개발, 단순함 우선 |
| 2026-04-16 | 프라이버시: "데이터 수집 안 함" 기본 | 최소 수집 원칙, 나중에 필요 시 확장 |

---

*최종 수정: 2026-04-16*
