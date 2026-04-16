# Cadenza — 러닝 케이던스 음악 플레이어

> 러닝 페이스에 맞춰 음악 BPM을 조절하고, 같은 BPM의 메트로놈을 함께 재생하는 iOS 앱

---

## 1. 한 줄 요약

**달리는 케이던스(spm)에 맞춰 음악을 재생속도 조절해서 들려주고, 메트로놈으로 박자를 보강해주는 러닝 전용 음악 플레이어.**

### 이름의 유래

**Cadenza** — 클래식 음악에서 협주곡 솔로 연주자가 자유롭게 기교를 펼치는 구간. 어원적으로 cadence(케이던스)와 같은 뿌리를 공유한다. 정해진 박자 위에서 연주자가 자신의 리듬을 만들어내듯, 러너도 자신의 케이던스 위에서 자신만의 달리기를 한다.

### 제품 경계

**본 앱의 초기 목표는 러닝 퍼포먼스 분석이 아니라, 목표 케이던스 유지에 도움을 주는 오디오 경험 제공이다.** 운동 효과의 정량 검증(케이던스 측정, 페이스 분석, 심박 연동 등)은 초기 버전에서 다루지 않으며, 사용자는 기존 Garmin, Apple Watch 등 외부 러닝 플랫폼을 통해 사후적으로 확인한다.

이 경계는 v1.5까지 유지한다. v2 이후 운동 플랫폼 연동은 **사용성이 검증된 뒤**에만 검토한다.

---

## 2. 문제 정의

### 2.1 사용자 페인 포인트

러너가 일정한 케이던스(보통 170~180 spm)를 유지하려 할 때:

- **현재 음악 앱의 한계**: Apple Music, Spotify, YouTube Music 모두 곡의 BPM을 사용자가 원하는 케이던스에 맞춰주는 기능 없음
- **수동 큐레이션 부담**: 본인 케이던스에 맞는 BPM 곡만 골라 플레이리스트 만드는 건 큰 노력
- **메트로놈 앱 별도 구동**: 메트로놈 앱은 박자만 제공하고 음악은 따로 재생해야 해서 불편
- **DJ 앱은 과잉**: djay Pro는 가능하지만 4-deck UI는 러닝 중 조작 불가

### 2.2 기존 솔루션 한계 정리

| 솔루션 | 한계 |
|---|---|
| Apple Music / Spotify | BPM 변경 기능 자체 없음 |
| 메트로놈 앱 (Pro Metronome 등) | 음악 통합 안 됨, 별도 앱 |
| djay Pro | DJ용 UI라 러닝 중 조작 불가, 케이던스 특화 UX 아님 |
| RockMyRun, Weav Run | 사전 큐레이션된 곡만 가능, 본인 라이브러리 사용 불가 |

### 2.3 우리의 차별점

**"본인 음악 라이브러리 + 본인 목표 케이던스 + 메트로놈 보조"** 조합을 한 화면에서 처리. 러닝 중 한 손으로 조작 가능한 단순한 UI.

---

## 3. 타겟 사용자

### 3.1 Primary Persona

**케이던스를 의식적으로 관리하는 중급 러너**

- 주 3회 이상 러닝, 월 80km 이상
- 목표 케이던스가 명확함 (예: "180 spm으로 달리고 싶다")
- 본인 음악 취향이 강해서 큐레이션된 러닝 플레이리스트로는 만족 못함
- Apple Music 또는 본인 MP3 라이브러리 보유
- 가벼운 러닝워치(Garmin, Apple Watch) 사용

### 3.2 Secondary Persona

**케이던스 트레이닝 입문자**

- 케이던스라는 개념을 막 알게 됨
- 본인 자연 케이던스(160~165)를 점진적으로 올리고 싶음
- 음악과 함께 자연스럽게 훈련하고 싶음

### 3.3 Out of Scope

- 인터벌 트레이닝/심박존 트레이닝 (별도 앱 영역)
- DJ/믹싱 (djay Pro 영역)
- 음악 발견/추천 (Apple Music 영역)
- **운동 퍼포먼스 분석** — 러닝 기록/페이스/실제 케이던스 측정/심박 분석은 Garmin·Apple Watch·Strava 등 외부 플랫폼이 담당. 앱은 순수 오디오 도구
- **자동 러닝 감지** — 러닝 시작/종료 자동 인식은 운동 앱 영역

---

## 4. 핵심 사용자 시나리오

### 시나리오 A: 자기 MP3 라이브러리 활용 (v0.5+)

> 토요일 아침 LSD 30km. 케이던스 175 spm 유지가 목표.
> Cadenza 앱 실행 → 본인 MP3 폴더에서 좋아하는 록 플레이리스트 선택
> → 목표 BPM 175 입력 → 재생 → 모든 곡이 175 BPM으로 자동 조정되어 재생됨
> → 메트로놈도 175 BPM으로 함께 들려서 발걸음을 박자에 맞춰 30km 완주

> *(v0에서는 단일 곡 반복 재생만 지원. 플레이리스트는 v0.5부터)*

### 시나리오 B: Apple Music 플레이리스트 활용

> 평일 저녁 8km. 좋아하는 K-pop 플레이리스트로 달리고 싶음.
> Apple Music 플레이리스트 "Running K-pop" 선택 → 목표 BPM 170
> → 곡들이 자동으로 170으로 조정됨 (피치 변화 감수)
> → "다람쥐 소리" 배지가 떠서 미리 알림

### 시나리오 C: 점진적 케이던스 향상

> 자연 케이던스 162 → 목표 175로 올리고 싶음.
> 첫 주: 목표 BPM 165 → 다음 주 168 → 점진적 상승
> 메트로놈 볼륨을 음악보다 살짝 크게 설정해서 박자 의식 강화

---

## 5. 기능 명세

각 단계는 **검증할 가설**을 명확히 하고, 그 가설에 필요한 최소 기능만 담는다.

### 5.1 v0 (MVP, 2주 목표) — 검증

**가설**: 피치 유지 템포 변경 + 메트로놈 동시 재생이 실제 러닝에서 유용하다.

**성공 기준 (현실적 수준)**
- 5km 이상 실제 러닝에서 1회 이상 사용
- 백그라운드 재생 30분 이상 끊김 없음
- **메트로놈 드리프트가 러닝 실사용을 저해하지 않음** (10분에 ±300ms 이내 — 사용자가 체감 못 하는 수준)
- 0.85x ~ 1.15x 구간에서 음질 만족스러움

> 정확한 sample-accurate 메트로놈은 v2 또는 백로그 12.1로. v0는 Timer 기반으로 충분.

v0는 구현 분량이 많아서 내부적으로 3단계로 분해한다.

#### v0a — 최소 재생 (Must)

최소 기능. 이것만 돼도 "기술 가설 검증"의 절반은 확인됨.

- 로컬 MP3/M4A/WAV 단일 파일 선택 (파일 피커)
- **파일 메타데이터에서 BPM 자동 읽기** (ID3 TBPM 태그 / M4A tempo 태그)
  - 있으면 자동 적용, 없으면 기본값 120으로 + 수동 입력 가능
  - 코드 10줄 수준, 비용 0
- 목표 BPM 슬라이더 (140~200)
- 피치 유지 템포 변경 (`AVAudioUnitTimePitch`)
- 재생 / 정지
- 반복 재생 (단일 곡)

#### v0b — 러닝 사용성 (Should)

v0a를 러닝에서 실제로 쓸 수 있게 만드는 레이어.

- **오디오 기반 BPM 자동 분석** — 메타데이터에 BPM 없는 파일용
  - AVAudioFile → PCM 버퍼 → 에너지 기반 비트 감지 (Swift Accelerate FFT)
  - 30초 분량 → 1~2초 분석
  - 더블/하프 BPM 의심 시 사용자에게 "87 vs 174" 선택지 제시
- 메트로놈 on/off, 볼륨 조절
- 메트로놈 BPM = 음악 BPM 강제 동기화
- 4/4박자 + 강박/약박 구분
- 백그라운드 재생 (Info.plist `UIBackgroundModes: audio`)
- 오디오 인터럽트 처리 (전화/알림 시 일시정지/재개)
- AVAudioSession `.playback` 카테고리 설정
- 헤드폰 언플러그 시 자동 일시정지
- **최소 Now Playing + 리모트 컨트롤** — `MPNowPlayingInfoCenter`에 곡 제목/BPM 표시, `MPRemoteCommandCenter`로 play/pause 대응. 락스크린/이어폰 버튼으로 재생·정지 가능. 아트워크/next/prev는 v1. 러닝 중 화면 안 켜고 조작하는 핵심 UX (~20줄)

#### v0c — 편의성 (Could, 시간 남으면)

- 케이던스 프리셋 버튼 (160/165/170/175/180/185)
- **탭 템포 UI** — 자동 분석 실패 시 fallback. 화면 탭탭탭 → BPM 자동 계산
- 메트로놈 단독 모드 (곡 안 골라도 메트로놈만 재생)
- 마지막 사용 설정 UserDefaults에 저장
- 화면 항상 켜기 토글

**BPM 확보 파이프라인 (v0 전체)**

```
파일 로드
  ↓
① 메타데이터 TBPM 태그 확인 ← 즉시, 비용 0 (v0a)
  ↓ 없음
② 자동 분석 (에너지 기반 비트 감지) ← 1~2초 (v0b)
  ↓ 실패 또는 신뢰도 낮음
③ 탭 템포 UI 제시 ← 사용자 4~8회 탭 (v0c)
  ↓ 건너뜀
④ 수동 숫자 입력 ← 최후 수단, 거의 안 씀
```

> 예상: 메타데이터 + 자동 분석으로 90%+ 커버. 탭 템포/수동 입력까지 가는 경우는 극소.

**제외 기능 (v0 전체 제외)**
- Apple Music
- 플레이리스트/큐
- 락스크린 아트워크/상세 메타데이터 (v1) — 단, 기본 Now Playing(곡 제목 + play/pause 리모트)은 v0b에 포함
- BPM 캐시 DB (v0.5에서 SwiftData 도입)

**메트로놈 정책 (v0)**
- 상세는 6.7장 참조

### 5.2 v0.5 (3주차) — 정확도 + 다중 파일

**가설**: BPM 정확도 향상과 다중 파일 재생이 재사용률을 높인다.

**추가 기능**
- BPM 캐시 (SwiftData, 6.8장 스키마) — 한 번 분석한 곡은 다시 분석 안 함
- BPM 분석 정확도 개선 (알고리즘 튜닝, 더 긴 분석 구간, 복합 장르 대응)
- 더블/하프 BPM 에러 보정 UI 개선 (사용자가 "x2" 버튼으로 보정)
- 재생 위치 표시 + 스크러빙
- 다중 파일 선택 + 셔플 큐 (정교한 플레이리스트 관리는 v1)

**성공 기준**
- 80% 이상 곡에서 자동 BPM이 ±3 이내 정확도
- 수동 입력/탭 템포 사용 빈도가 전체의 10% 미만

### 5.2.1 Apple Music Technical Spike (v0.5 완료 후, v1 시작 전, 1일)

**목적**: v1 로드맵 진행 여부를 결정하는 기술 리스크 소각.

**검증 항목**:
- [ ] `ApplicationMusicPlayer` 재생/정지
- [ ] `playbackRate` 변경 (0.9x ~ 1.1x)
- [ ] 백그라운드 진입/복귀 시 재생 유지
- [ ] 이어폰 리모트(play/pause) 대응
- [ ] 앱의 AVAudioEngine 메트로놈과 동시 재생 시 체감 문제
- [ ] iOS 26 beta `playbackRate` 리그레션 상태 확인 (9.1 참조)

**판정**:
- 전부 통과 → v1 로드맵 유지
- 일부 실패 → 실패 항목에 따라 v1 범위 축소 (예: playbackRate 불가 시 Apple Music은 1.0x 고정 + 메트로놈 보조만)
- 전부 실패 → Apple Music 통합 무기한 연기, 로컬 파일 경험 강화로 방향 전환

### 5.3 v1 (4~6주차) — Apple Music 통합

**가설**: Apple Music 연동이 "본인 음악 라이브러리 쓰고 싶다"는 진입장벽을 크게 낮춘다.

**전제**: 5.2.1 spike 통과 필수.

**추가 기능**
- MusicKit 통합 (Apple Music 로그인)
- 사용자 Apple Music 플레이리스트 로드
- Apple Music 곡 재생 (`ApplicationMusicPlayer.playbackRate`)
- "피치 변화" 배지 표시 (Apple Music 곡)
- 락스크린 Now Playing (`MPNowPlayingInfoCenter`) — 곡명/아트워크/재생 컨트롤
- 백그라운드 재생 안정화 강화
- 곡 자동 진행 (플레이리스트 연속 재생)

**실험 기능 (핵심 경로 아님)**
- ⚠️ Apple Music 프리뷰 URL 기반 BPM 분석은 **실험 기능**으로 제공
  - 프리뷰 가용성/길이/품질 리스크가 있어 필수 경로에서 제외
  - 사용자가 "자동 분석 시도" 버튼을 눌렀을 때만 동작
  - 실패 시 조용히 fallback → 수동 입력

**BPM 데이터 우선순위 (수정됨)**
1. 로컬 캐시
2. 사용자 수동 입력 (탭 템포 또는 숫자)
3. (선택) 자동 분석 실험 기능

**성공 기준**
- Apple Music 플레이리스트 100곡 이상에서 안정 재생
- 백그라운드 30분 이상 끊김 없음

### 5.4 v1.5 (7~9주차) — 외부 연동

**가설**: Apple Watch 제어가 러닝 중 조작성을 개선한다.

**추가 기능**
- Apple Watch 컴패니언 앱 (BPM 조절, 재생/정지)
- Supabase 동기화 (캐시된 BPM 데이터, 사용자 설정)
- "내가 가진 같은 곡 자동 매칭" — Apple Music 곡과 같은 제목의 로컬 MP3가 있으면 로컬 우선 재생 옵션 (피치 유지 효과)
- 곡별 사용 횟수 통계 (앱 내 UI용, 외부 전송 없음)

> 이 단계까지는 제품 경계 유지 — 운동 분석은 여전히 하지 않음

### 5.5 v2 (10주+) — 조건부 확장

**가설**: 핵심 오디오 UX가 검증된 상태에서, 운동 플랫폼 연동이 추가 가치를 만든다.

> **v2는 v1.5까지의 사용성이 검증된 후에만 진행.** 앞 단계가 흔들리면 v2는 무기한 연기.

**아이디어 풀**
- HealthKit 케이던스 사후 조회 (러닝 후 Garmin/Apple Watch 데이터 가져와 비교)
- Apple Watch 가속도계 실시간 케이던스 측정 → 음악 BPM 자동 동기화
- 본인 라이브러리에서 목표 BPM 곡 자동 큐레이션
- 메트로놈 sample-accurate 재구현 (정확도 ±1ms)

**(이 단계는 v1.5 사용 데이터 보고 결정)**

---

## 6. 기술 결정

### 6.1 플랫폼

**Native iOS (SwiftUI) 선택**

| 비교 항목 | Web (PWA) | Native iOS | 결정 |
|---|---|---|---|
| 백그라운드 오디오 | ⚠️ Safari 제약 많음 | ✅ 표준 | iOS |
| 락스크린 컨트롤 | ❌ | ✅ MPNowPlayingInfoCenter | iOS |
| Apple Watch 연동 | ❌ | ✅ | iOS |
| 피치 유지 타임스트레치 | SoundTouch.js (외부) | ✅ AVAudioUnitTimePitch (내장) | iOS |
| MusicKit 접근 | JS 가능하지만 제약 | ✅ Swift 풀 액세스 | iOS |
| 개발 속도 | 빠름 | SwiftUI면 비슷 | 동률 |
| 러닝 실사용 | ⚠️ | ✅ | iOS |

**결정 근거**: 러닝 중 백그라운드 재생, 락스크린 컨트롤, 워치 연동은 러닝 앱의 필수 요건. 웹앱은 이걸 못 채움.

### 6.2 오디오 엔진

**`AVAudioEngine` + `AVAudioUnitTimePitch`**

- Apple 공식 제공, 외부 라이브러리 불필요
- DJ 앱들이 쓰는 zplane élastique Pro V3만큼은 아니지만 러닝 용도엔 충분 (0.7x~1.4x 구간 양호)
- 메트로놈 노드를 같은 mainMixer에 연결해 단일 출력으로 통합

**대안 검토**
- SoundTouch (오픈소스 LGPL, 실시간 가능) → 통합 복잡도 높음, v2에서 재고려
- Rubber Band (GPL/상용, 최고 품질) → 라이센스 비용, v2에서 재고려
- Bungee (오픈소스 C++, 2025년 신규, 고품질 실시간) → github.com/kupix/bungee, v2 후보로 주시
- 자체 Phase Vocoder → 시간 낭비

### 6.3 Apple Music 처리 정책

**Apple Music 곡은 피치 변경 감수**

- DRM 보호로 피치 유지 타임스트레치 불가능 (Apple "DJ with Apple Music" 엔타이틀먼트는 djay/Serato 등 공식 파트너만 받음)
- `MusicKit.ApplicationMusicPlayer.playbackRate`만 사용 가능 (피치 같이 변함, "다람쥐 소리")
- UX에서 "⚠️ 피치 변함" 배지로 사용자에게 명확히 알림
- 0.9x ~ 1.1x 구간에서는 청취 가능, 그 이상 벗어나면 사용자에게 경고

### 6.4 BPM 데이터 소스 우선순위

```
1순위: 로컬 캐시 (SwiftData, v0.5+)
   ↓ miss
2순위: 메타데이터 태그 (ID3 TBPM / M4A tempo)
   - 코드 10줄, 비용 0, 즉시
   - iTunes/Apple Music에서 분석된 파일이면 대부분 있음
   ↓ 없음
3순위: 자체 오디오 분석 (v0b+)
   - 로컬 파일: AVAudioFile → PCM → 에너지 기반 비트 감지
   - Apple Music (v1 실험 기능): 프리뷰 URL 분석 (리스크 있음)
   ↓ 실패 또는 신뢰도 낮음
4순위: 탭 템포 (v0c)
   - 곡 재생하며 화면 4~8회 탭 → 자동 계산
   ↓ 건너뜀
5순위: 수동 숫자 입력 (최후 수단)
```

> 2~3순위가 v0에서 작동하면, 사용자가 수동 입력을 하는 일은 거의 없어야 한다.

**Spotify Audio Features API 미사용**: 2024년 11월부터 신규 앱 접근 차단됨.
**GetSongBPM API 미사용**: 백링크 의무 + 한국 곡 커버리지 약함.

### 6.5 데이터 저장

**v0**: UserDefaults만 (단일 곡이라 풀 DB 불필요)
**v0.5~v1**: SwiftData (iOS 17+ 기본, CoreData보다 모던)
**v1.5+**: SwiftData + Supabase 동기화 (BPM 캐시 공유, 사용자 설정 동기화)

> 상세 스키마는 6.8장 참조

### 6.6 개발 도구

- **IDE**: Xcode 26+ (Claude 네이티브 통합)
- **AI 코딩**: Claude Code CLI (기존 vibe-sunsang 플러그인, 슬래시 커맨드 활용)
- **UI 프레임워크**: SwiftUI (iOS 17+)
- **최소 지원**: iOS 17

### 6.7 메트로놈 상세 사양

#### 음색 (M1-c)

- **소스**: 우드블록 풍 짧은 타격음
  - v0 임시: 합성음 (필터링된 노이즈 + 빠른 어택 + 짧은 감쇠)으로 우드블록 흉내
  - v0.5+: 실제 우드블록 샘플(.wav, ~30~50ms) 번들 포함
- **이유**: 사인파는 러닝 환경(이어폰 + 외부 소음 + 음악 위)에서 묻힘. 트랜지언트가 강한 타격음이 인지율 압도적으로 높음
- **두 가지 톤**: 강박용(약간 높음, 예: 1200Hz 중심) + 약박용(약간 낮음, 예: 800Hz 중심)

#### 박자 패턴 (M2-b)

- **고정 4/4박자**: |강·약·약·약|강·약·약·약|...
- **강박 강조 방식**:
  - 음색이 약간 높음 + 볼륨 약간 큼(예: 약박 대비 +3dB)
- 박자 패턴 선택(3/4, 6/8 등)은 백로그 12.1로

#### 첫 클릭 타이밍 (M3-a)

- **음악 재생과 동시에 첫 클릭** (음악 비트 위치 정렬 안 함)
- 음악 비트 정렬은 백로그(미작성, 12.1에 추가 검토 필요)
- 사용자가 박자가 어긋나는 게 거슬리면 정지 후 재시작

#### 단독 모드 (M4-a)

- 음악 파일 안 고른 상태에서도 메트로놈 단독 재생 가능
- 메트로놈 단독 시 BPM은 "목표 BPM" 슬라이더가 그대로 사용됨
- 워밍업/쿨다운/박자 연습에 유용

#### 정확도

- v0~v1: Timer 기반 (구현 단순, 장시간(10분+) 사용 시 ±수십~수백 ms 드리프트 가능)
- v2 또는 백로그 12.1: AVAudioEngine sampleTime 기반 재구현 (드리프트 ±1ms 이내)

### 6.8 데이터 모델

#### v0: UserDefaults만 (D1-b)

데이터 저장이 거의 필요 없음. 마지막 사용 설정만 복원.

| Key | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `lastTargetBPM` | Double | 170 | 마지막 목표 BPM |
| `lastOriginalBPM` | Double | 120 | 마지막 입력한 원곡 BPM |
| `metronomeEnabled` | Bool | true | 메트로놈 on/off |
| `metronomeVolume` | Float | 0.6 | 메트로놈 볼륨 (0.0~1.0) |
| `lastFileBookmark` | Data? | nil | 마지막 재생 파일 security-scoped bookmark (선택) |

#### v0.5+: SwiftData (D2-b, D3-b)

iOS 17+ SwiftData 사용. Track은 통합 테이블 + source 필드로 로컬/Apple Music 구분.

```swift
// Track: 곡 메타데이터 + BPM 캐시
@Model
final class Track {
    @Attribute(.unique) var id: String         // source별로 unique한 키
    var source: TrackSource                    // .local / .appleMusic
    var title: String
    var artist: String?
    var album: String?
    var durationSec: Double?

    // BPM
    var detectedBPM: Double?                   // 자동 감지 결과
    var userOverrideBPM: Double?               // 사용자가 수정한 값 (우선)
    var bpmSource: BPMSource?                  // BPM 값의 출처 (v0.5+)
    var bpmConfidence: BPMConfidence?          // 신뢰도 (v0.5+)
    var bpmAnalyzedAt: Date?                   // 분석 시점

    // 통계 (v1.5+)
    var playCount: Int = 0
    var lastPlayedAt: Date?

    // source별 식별 정보
    var localFileBookmark: Data?               // .local일 때 security-scoped bookmark
    var appleMusicSongID: String?              // .appleMusic일 때 MusicKit Song.ID

    // 매칭 (v1.5)
    var matchedTrackID: String?                // 같은 곡의 다른 source 버전 ID

    // 효과적으로 사용할 BPM
    var effectiveBPM: Double? {
        userOverrideBPM ?? detectedBPM
    }

    init(id: String, source: TrackSource, title: String) {
        self.id = id
        self.source = source
        self.title = title
    }
}

enum TrackSource: String, Codable {
    case local
    case appleMusic
}

// BPM 출처 (v0.5+): 이 값이 어디서 왔는지 기록
enum BPMSource: String, Codable {
    case metadata       // ID3 TBPM 태그 / M4A tempo 태그
    case analysis       // 자체 오디오 분석
    case tapTempo       // 사용자 탭 템포
    case manual         // 사용자 직접 숫자 입력
    case userOverride   // 자동 감지 결과를 사용자가 보정 (B-03 등)
}

// BPM 신뢰도 (v0.5+): UX에서 보정 다이얼로그 표시 여부 판단에 사용
enum BPMConfidence: String, Codable {
    case high           // metadata 또는 analysis 성공 (편차 낮음)
    case medium         // analysis 성공했지만 double/half 의심
    case low            // analysis 실패 근접, 탭 템포 편차 큼
    case explicit       // 사용자가 직접 입력/보정 (무조건 신뢰)
}

// PlaybackSession: 러닝 세션 기록 (v1.5+)
@Model
final class PlaybackSession {
    var startedAt: Date
    var endedAt: Date?
    var targetBPM: Double
    var totalDurationSec: Double = 0

    // v1.5 초기: trackIDs로 시작해도 되지만, 도입 시 SessionTrack 정규화 권장
    // var trackIDs: [String]  // ← 이 구조는 "어떤 곡이 있었는지"만 알고
    //                         //    "무슨 일이 있었는지"는 기록 못 함

    init(startedAt: Date, targetBPM: Double) {
        self.startedAt = startedAt
        self.targetBPM = targetBPM
    }
}

// SessionTrack: 세션 내 곡별 재생 기록 (v1.5+ PlaybackSession 도입 시 함께 추가)
// PlaybackSession과 1:N 관계. 재생 순서, 실제 적용된 rate, 스킵 여부 등을 기록.
@Model
final class SessionTrack {
    var sessionID: String                      // PlaybackSession 참조
    var trackID: String                        // Track 참조
    var orderIndex: Int                        // 재생 순서
    var startedAt: Date
    var endedAt: Date?
    var playedDurationSec: Double = 0
    var targetBPM: Double                      // 이 곡 재생 중 목표 BPM (세션 중간에 변경 가능)
    var effectiveBPM: Double                   // 적용된 원곡 BPM
    var playbackRate: Double                   // 실제 적용된 재생 속도 비율
    var skipped: Bool = false                  // 사용자가 곡을 건너뛰었는지
}

// UserPreferences: 단일 인스턴스 설정 (v0.5에서 UserDefaults에서 마이그레이션)
@Model
final class UserPreferences {
    var defaultTargetBPM: Double = 170
    var metronomeVolume: Float = 0.6
    var metronomeEnabled: Bool = true
    var preferLocalOverAppleMusic: Bool = true  // v1.5: 같은 곡 매칭 시 로컬 우선
}
```

#### Track ID 생성 규칙

- **Apple Music 곡**: `am:{Song.ID}` 형식 (예: `am:1465839849`) — 안정적, 변화 없음

- **로컬 파일 (v0.5)**: SHA-256(파일 경로 + 파일 크기) 첫 16바이트 hex
  - 장점: 구현 단순, 캐시 무효화 명확
  - 단점: 파일 이동/이름 변경 시 같은 곡이 다른 ID → 중복 캐시
  - v0.5에선 이대로 감수

- **로컬 파일 (v1+, 휴리스틱 매칭 추가)**:
  1. 1차 키: 파일 bookmark 기반 고유 ID (security-scoped, 이동 감내)
  2. 2차 매칭: `(duration ± 1s, title, artist, size ± 1%)` 튜플로 같은 곡 판별
  3. 매칭되면 기존 캐시 재사용 + 파일 위치만 업데이트
  4. 음향 fingerprint(Chromaprint 등)는 v2에서 필요 시 검토

#### 마이그레이션 정책

- v0 → v0.5: UserDefaults 값을 SwiftData `UserPreferences`로 1회 복사 후 UserDefaults 키 삭제
- v0.5 → v1: 스키마 변경 시 SwiftData `Schema` 버전 관리 (Apple 공식 마이그레이션)

#### 외부 동기화 (v1.5+, Supabase)

- 동기화 대상: `Track.detectedBPM`, `Track.userOverrideBPM`만 (메타데이터 + BPM 캐시)
- 동기화 제외: 로컬 파일 bookmark, 사용자 통계 (프라이버시)
- 트리거: 수동 ("동기화" 버튼) 또는 백그라운드 주기 (1일 1회)
- 충돌 해결: 최신 `bpmAnalyzedAt`이 이김 (last-write-wins)

---

## 7. UX 원칙

### 7.1 러닝 중심 디자인

1. **큰 터치 타겟**: 모든 주요 컨트롤 최소 44pt × 60pt
2. **한 손 조작**: 엄지로 닿는 영역에 핵심 컨트롤 배치
3. **고대비**: 햇빛 아래 야외 가독성 우선
4. **최소 정보 밀도**: 한 화면에 핵심 정보만 (BPM, 곡명, 재생 상태)

### 7.2 정직한 상태 표시

- Apple Music 곡: "⚠️ 피치 변경됨" 배지
- 로컬 파일 + 피치 유지: "🎵 키 락 ON" 배지
- 큰 BPM 변경(±15% 이상): 음질 저하 경고

### 7.3 학습 곡선 최소화

- 첫 실행 시 3단계 온보딩: ① 파일 선택 ② 목표 BPM 설정 ③ 재생
- 케이던스 개념 설명은 "더 알아보기" 링크로 숨김

---

## 8. 비기능 요구사항

### 8.1 성능

**측정 기준 디바이스**: iPhone 15 Pro, iOS 18.x 이상, 로컬 6MB AAC/MP3 파일 기준

| 항목 | 목표 | 측정 방법 |
|---|---|---|
| 앱 콜드 스타트 → 재생 가능 상태 | ≤ 2초 | Xcode Instruments App Launch template |
| 곡 로드 (파일 선택 → 재생 가능) | ≤ 1초 | 수동 측정, 30초 곡 5회 평균 |
| BPM 자동 분석 (30초 샘플) | median ≤ 5초 | 10곡 분석 median 값 |
| 백그라운드 재생 안정성 | 30분 무중단 | 실기기에서 홈 화면 → 앱 → 락 전환 |
| 메트로놈 드리프트 | 10분 누적 ± 300ms 이내 | 외부 메트로놈 앱과 비교 측정 |

> v0에선 "측정 가능한 상태를 만드는 것"이 먼저. 위 수치는 **목표**이며 v0 검증 후 재조정.

### 8.2 안정성

- 백그라운드 30분 이상 끊김 없음
- 메트로놈 드리프트: v0~v1 **10분 재생 후 ±300ms 이내 허용** (러닝 실사용에 영향 없는 수준). ±50ms 이내 정확도는 v2에서 sampleTime 기반 재구현 시 목표
- 오디오 인터럽트 처리 (전화, 알림): 자동 일시정지/재개

### 8.3 프라이버시

- Apple Music 라이브러리 접근 권한만 요청
- 사용자 음원 파일은 로컬에만 저장, 외부 전송 없음
- 분석 데이터(BPM 캐시)는 익명화 후 선택적으로 Supabase 동기화

---

## 9. 알려진 제약 및 리스크

### 9.1 기술적 제약

| 제약 | 영향 | 대응 |
|---|---|---|
| Apple Music 피치 유지 불가 | Apple Music 사용자 경험 저하 | "다람쥐" 배지로 명시, 로컬 파일 우선 권장 |
| YouTube Music 접근 불가 | YouTube Music 사용자 배제 | 지원 안 함, 명시 |
| BPM 자동 감지 정확도 한계 | 발라드/복잡 리듬 곡 부정확 | 수동 보정 UI 제공 |
| 메트로놈 Timer 드리프트 | 장시간 재생 시 박자 어긋남 | v1에서 sampleTime 기반 재구현 |
| iOS 26 beta `playbackRate` 리그레션 | Apple Music 곡(v1) rate 변경이 0/1.0으로 강제 복귀, 노이즈 아티팩트 | iOS 18.5에서는 정상. v1 개발 시점(4~6주차)에 iOS 26 정식 출시 상태 확인 필요. 로컬 파일 `AVAudioUnitTimePitch`(v0)에는 영향 없음 |

### 9.2 사업적 리스크

- **Apple Music 정책 변경**: MusicKit `playbackRate`가 다시 막힐 가능성 (2022년 iOS 15.4에 한 번 막혔다 15.5에 복원된 이력 있음). **2026년 4월 기준 iOS 26 beta에서 리그레션 발생 중** (9.1 참조)
- **djay Pro 등 기존 솔루션**: 피치 유지가 결정적이면 이쪽이 우위. 우리는 "러닝 특화 단순함"으로 차별화
- **사용자 풀 제한**: 케이던스를 의식하는 러너는 전체 러너의 일부

### 9.3 음질 현실 검증 — 제품 가설의 핵심 리스크

**이 앱의 핵심 가설은 "피치 유지 템포 변경이 러닝에서 유용하다"인데, 대부분의 대중음악에서 이 기능의 음질이 기대만큼 좋지 않을 수 있다.**

#### rate 범위와 실제 음악 BPM 분포

목표 케이던스 175 spm 기준, "음질 만족 구간" (rate 0.85x~1.15x)에 들어가려면 원곡 BPM이 152~206 범위여야 한다.

| 장르 | 일반적 BPM 범위 | 목표 175 시 rate | 음질 기대 |
|---|---|---|---|
| EDM/댄스 | 120~150 | 1.17x~1.46x | ⚠️ 구간 경계~밖 |
| K-pop | 90~130 | 1.35x~1.94x | ❌ 음질 저하 뚜렷 |
| 팝 | 100~130 | 1.35x~1.75x | ❌ 음질 저하 뚜렷 |
| 록 | 110~140 | 1.25x~1.59x | ⚠️~❌ |
| 힙합 | 70~100 | 1.75x~2.50x | ❌ 심한 저하 |

**현실**: 사용자가 좋아하는 곡 10곡 중 7~8곡은 rate 1.3x 이상이 필요하고, 이 범위에서 AVAudioUnitTimePitch의 음질은 눈에 띄게 나빠진다 (소리가 얇아지고, 아티팩트 발생).

#### rate 범위별 음질 기대치

| rate 범위 | 음질 | UX 표시 |
|---|---|---|
| 0.85x~1.15x | ✅ 양호, 차이 거의 못 느낌 | 표시 없음 |
| 1.15x~1.30x | ⚠️ 약간의 변화 감지, 수용 가능 | 없음 또는 경미한 표시 |
| 1.30x~1.50x | ⚠️ 뚜렷한 변화, 장르에 따라 불편 | "속도 변경 큼" 경고 |
| 1.50x 이상 | ❌ 부자연스러움, 장시간 청취 불편 | "음질 저하 가능" 배지 + 대안 안내 |
| 0.70x 미만 | ❌ 느려서 부자연스러움 | 동일 |

#### 대응 전략 (v0~v0.5)

1. **double-time 활용**: 87 BPM 곡을 174 spm으로 쓰면 rate ≈ 1.0x. beat-step mapping(백로그 12.1, 🔥)으로 "곡은 원래 속도, 메트로놈만 2배"가 가능해지면 음질 문제 해소
2. **BPM 근접 곡 선호 안내**: v0.5에서 "목표 BPM에 가까운 내 곡 보기" 큐레이션(백로그 12.4)이 들어가면 자연스럽게 음질 좋은 곡 위주로 사용
3. **메트로놈 중심 사용**: 음악은 원래 속도로, 메트로놈만 목표 BPM. beat-step 분리의 또 다른 형태
4. **경고 UI 강화**: rate 1.3x 이상에서 "이 곡은 원래 속도와 차이가 커서 음질이 달라질 수 있어요" + "원래 속도로 듣기" 원탭 옵션

#### v0 검증 시 확인 사항

- [ ] rate 1.2x, 1.3x, 1.5x, 1.8x에서 각각 음질 주관 평가 (곡 3종 이상)
- [ ] "음질이 나빠도 리듬 맞춰 달리는 게 더 좋은가?" 정성 판단
- [ ] double-time 곡(원곡 85~95 BPM)에서 rate ≈ 1.0x 경험이 월등히 좋은지 확인
- [ ] 경고 배지가 뜨는 빈도: 본인 라이브러리 20곡 중 몇 곡?

> 이 검증이 v0의 가장 중요한 테스트다. 음질이 너무 나쁘면 "피치 유지 템포 변경"이라는 핵심 기능의 가치가 대폭 줄어들고, 메트로놈 + double-time 조합이 실제 주력 사용 패턴이 될 수 있다. 그 경우 beat-step 분리(12.1)의 우선순위가 v0.5로 올라가야 한다.

### 9.4 법적 회색 지대

- 로컬 MP3 파일 재생: 본인 소유 음원 한정. 제3자 음원 공유 기능은 절대 안 만듦
- "Apple Music 곡과 같은 제목 로컬 MP3 자동 매칭" (v1.5): 본인 소유 음원 매칭만, 다운로드/공유 기능 없음

---

## 10. 성공 지표

초기 단계에서는 **정량 지표보다 정성 판단**을 중심으로 한다. 이 앱의 핵심 질문은 단 하나다:

> **"이 앱을 켜고 달리면, 내가 리듬 유지에 도움이 된다고 느끼는가?"**

운동 효과의 정량 검증은 앱 내부에서 하지 않는다 (Garmin 등 외부 플랫폼에서 사후 확인).

### 10.1 v0~v0.5 (개인 사용 단계)

정성 지표 (자가 평가):
- 러닝 중 30분 이상 안정 재생됨
- 목표 BPM 설정과 조작이 불편하지 않음
- 메트로놈이 거슬리지 않고 보조 역할을 함
- 다음 러닝에도 다시 쓸 의향이 있음

정량 지표:
- 본인이 매주 1회 이상 러닝에 사용
- 자동 BPM 감지 정확도 80% 이상 (v0.5)

### 10.2 v1 (가족/친구 베타)

- 베타 테스터 5~10명 모집
- 주 1회 이상 사용자 비율 50%
- 크래시율 1% 미만
- 정성 피드백: "리듬 유지에 도움이 된다" 응답 다수

### 10.3 v2+ (공개 출시 검토, 조건부)

- v1.5까지의 사용성이 검증된 상태에서만 검토
- 주간 활성 사용자 100명 이상이면 App Store 출시 검토
- 그 미만이면 개인 도구로 유지

---

## 11. 로드맵 요약

| 단계 | 기간 | 검증 가설 | 주요 산출물 |
|---|---|---|---|
| v0a | 1주차 | 피치 유지 템포 변경 엔진이 동작하는가 | 로컬 파일 + 메타데이터 BPM 자동 읽기 + 재생/정지 |
| v0b | 2주차 전반 | 메트로놈 + 자동 BPM + 백그라운드가 러닝에서 쓸 만한가 | 오디오 BPM 분석 + 메트로놈 + 백그라운드 + 인터럽트 |
| v0c | 2주차 후반 | 러닝 중 조작성 | 프리셋 + 탭 템포 + 단독 모드 + 화면 켜기 |
| v0 검증 | 2주차 말 | 전체 가설 검증 | **5km 이상 러닝에서 실사용** |
| v0.5 | 3주차 | BPM 정확도 + 다중 파일이 재사용률을 높이는가 | BPM 정확도 개선 + 캐시 + 다중 파일 큐 |
| v1 | 4~6주차 | Apple Music 연동이 진입장벽을 낮추는가 | Apple Music + 락스크린 + Now Playing |
| v1.5 | 7~9주차 | Watch 제어가 조작성을 개선하는가 | Apple Watch + Supabase 동기화 |
| v2 | 조건부 | 오디오 UX 검증 후 운동 플랫폼 연동 가치 | HealthKit, 실시간 케이던스 (v1.5 사용성 확인 후 결정) |

---

## 12. 백로그 (Someday/Maybe)

> 대화 중 나왔지만 정식 로드맵에 넣지 않은 아이디어. 잊지 않기 위해 기록.
> 우선순위 라벨: 🔥 가까운 미래 / 💭 검토 / ❄️ 먼 미래

### 12.1 메트로놈 고도화

- 🔥 **메트로놈 BPM 분리 설정 (double-time 지원)** — 음악과 다른 BPM으로 메트로놈 재생. 예: 음악 87.5 BPM(원곡 그대로), 메트로놈 175 BPM (더블 타임 케이던스). **v0.5 데이터 모델에서 `targetCadence`와 `musicBPM` 개념을 분리해두고, v0에서는 동일값 강제. UI 분리는 v0.5 설정으로 제공 검토.** B-03 보정 다이얼로그가 이미 half-time/double-time 문제를 다루고 있으므로, 이건 백로그가 아니라 핵심 모델의 일부
- 💭 **박자 패턴 선택** — 3/4, 6/8 등 (참고: 4/4 강박/약박 구분은 이미 v0b 스펙에 포함, 6.7 M2-b 참조)
- ❄️ **메트로놈 sampleTime 기반 재구현** — 현재 Timer 기반은 장시간 드리프트 가능. AVAudioEngine sampleTime으로 정확도↑

### 12.2 케이던스 측정/분석

- ❄️ **HealthKit 케이던스 사후 조회** — 러닝 후 실제 케이던스를 HealthKit에서 가져와 목표 vs 실제 비교
- ❄️ **Apple Watch 가속도계로 실시간 케이던스 측정** → 음악 BPM 자동 동기화 (v2 핵심)
- 💭 **세션 기록** — 러닝마다 사용한 곡, 목표 BPM, 실제 케이던스 로깅

### 12.3 음악 소스 확장

- 💭 **"같은 곡 자동 매칭"** — Apple Music 곡과 같은 제목의 로컬 MP3 자동 매칭해서 피치 유지 효과 (v1.5에 일부 포함)
- 💭 **iCloud Drive 음원 폴더 동기화** — Mac에서 추가한 곡 자동 반영
- ❄️ **Spotify 통합 재검토** — Spotify가 audio-features API 정책 완화하면

### 12.4 큐레이션/추천

- ❄️ **본인 라이브러리에서 목표 BPM 곡 자동 큐레이션** — "175 BPM에 가까운 내 곡 보기"
- ❄️ **"워밍업 → 메인 → 쿨다운"** 구간별 자동 BPM 변화
- ❄️ **AI 기반 곡 추천** — 본인 라이브러리 + 케이던스 + 분위기

### 12.5 UX/소셜

- 💭 **위젯** — 홈 화면에서 빠른 BPM 변경
- ❄️ **Live Activity** — 다이내믹 아일랜드에 현재 BPM 표시
- ❄️ **러닝 친구와 케이던스 공유** — "친구가 175로 달리는 중"
- ❄️ **세션 공유** — 어떤 곡으로 어떤 페이스로 달렸는지 SNS 공유

### 12.6 오디오 품질

- ❄️ **SoundTouch / Rubber Band 통합** — AVAudioUnitTimePitch보다 더 좋은 품질이 필요해질 때
- ❄️ **EQ / 이퀄라이저** — 러닝 중 저역 강화 (이어폰 환경 보정)

### 12.7 기타 후보

- 💭 **온보딩에 "내 자연 케이던스 측정" 단계** — 30초간 제자리 뛰기 → 자동 측정
- 💭 **앱 아이콘 다크/라이트 모드 전환**
- ❄️ **iPad / Mac Catalyst 지원**

> 새 아이디어 나오면 위 카테고리 중 하나에 추가. 정식 로드맵으로 승격할 때는 5장으로 이동.

---

## 13. 의사결정 기록

| 일자 | 결정 사항 | 근거 |
|---|---|---|
| 2026-04-16 | Native iOS (SwiftUI) 선택 | 백그라운드 오디오, 락스크린, Watch 연동 필수 |
| 2026-04-16 | Apple Music은 피치 변경 감수 | DJ 엔타이틀먼트 접근 불가, 우회로 없음 |
| 2026-04-16 | YouTube Music 미지원 | 공식 API 부재, 비공식 스크래핑 ToS 위반 |
| 2026-04-16 | BPM 자동 감지 자체 구현 | Spotify API 차단, 외부 API 의존성 회피 |
| 2026-04-16 | v0는 로컬 파일 단일 곡만 | 핵심 가설(피치 유지 + 메트로놈)부터 검증, 플레이리스트는 v0.5 |
| 2026-04-16 | v0에 백그라운드 재생 포함 | Info.plist 토글만으로 가능, 5km 러닝 검증 위해 필수 |
| 2026-04-16 | 메트로놈 BPM = 음악 BPM 강제 동기화 (v0~v1) | 단순함 우선, 분리 옵션은 백로그 12.1로 |
| 2026-04-16 | 메트로놈 음색: 우드블록 풍 타격음 | 사인파는 러닝 환경에서 묻힘. 트랜지언트 강한 소리 필요 |
| 2026-04-16 | 메트로놈 4/4박자 + 강박/약박 구분 | 마디 인식 도움. 박자 패턴 선택은 백로그 |
| 2026-04-16 | 메트로놈 단독 모드 지원 | 워밍업/쿨다운 사용성. 추가 비용 적음 |
| 2026-04-16 | v0 저장은 UserDefaults | v0는 단일 곡이라 풀 DB 불필요. 마지막 설정만 복원 |
| 2026-04-16 | v0.5+ 데이터: SwiftData | iOS 17 최소 타겟에 자연스러움. CoreData보다 모던 |
| 2026-04-16 | Track 모델: source 필드로 통합 | 별도 테이블 분리는 매칭 로직 복잡. ISRC는 로컬에 거의 없어 과잉 |
| 2026-04-16 | 앱 이름 "Cadenza" 확정 | cadence와 어원 공유, 음악적 의미, 차별화 |
| 2026-04-16 | **제품 경계: 오디오 도구로 한정** | 운동 분석은 Garmin/Apple Watch 등 외부 플랫폼이 담당. 앱이 모든 걸 먹으려 하면 핵심이 흐려짐 |
| 2026-04-16 | **v0 메트로놈 드리프트 허용 ±300ms (10분 기준)** | Timer 기반 구현 현실성 반영. 러닝 실사용에 영향 없음. sample-accurate는 v2로 |
| 2026-04-16 | **v0를 v0a/v0b/v0c로 분해** | 2주 안에 현실적 달성 위해 Must/Should/Could 분할 |
| 2026-04-16 | **Apple Music 자동 BPM 분석을 실험 기능으로 강등** | 프리뷰 URL 가용성/품질 리스크가 v1 핵심 경로에 들어가면 안 됨 |
| 2026-04-16 | **각 버전에 검증 가설 명시** | 기능 나열이 아닌 검증 중심 개발로 전환 |
| 2026-04-16 | **v0.5+ Track ID 휴리스틱 매칭 추가** | 파일 이동 시 중복 캐시 문제 완화 |
| 2026-04-16 | **성능 지표에 측정 조건 명시** | 수치만으론 acceptance criteria가 되지 못함 |
| 2026-04-16 | **BPM 수동 입력을 최후 수단으로 강등** | UX 킬러. 메타데이터 태그 → 자동 분석 → 탭 템포 → 수동 순으로 파이프라인 구성 |
| 2026-04-16 | **자동 BPM 감지를 v0.5에서 v0b로 앞당김** | 로컬 파일은 raw PCM 접근 가능하므로 v0에서 충분히 구현 가능. 사용자 경험 핵심 |
| 2026-04-16 | **BPM 출처(bpmSource) + 신뢰도(bpmConfidence) 필드 추가** | BPM 값의 출처를 기록해야 보정 다이얼로그, UI 배지, 향후 정확도 개선에 활용 가능 |
| 2026-04-16 | **beat-step mapping: 데이터 모델에서 targetCadence/musicBPM 분리 방향 확정** | double-time 곡(87 BPM 곡을 174 spm으로 달리기)에서 불필요한 2배속을 피하기 위해. v0에서는 동일값 강제, v0.5에서 UI 분리 검토 |
| 2026-04-16 | **최소 Now Playing + 리모트 play/pause를 v0b로 앞당김** | 러닝 중 락스크린/이어폰 컨트롤은 장식이 아니라 핵심 UX. 코드 ~20줄 |
| 2026-04-16 | **Apple Music technical spike: v0 freeze 후 1일** | ApplicationMusicPlayer + playbackRate + 백그라운드 + 메트로놈 동시 재생을 실기기에서 검증. 통과 시 v1 로드맵 유지, 실패 시 보수적 조정 |
| 2026-04-16 | **AudioManager: @StateObject로 앱 루트에서 소유** | 싱글턴은 테스트 불편. @StateObject + @EnvironmentObject 패턴이 SwiftUI 수명주기에 맞고 테스트 가능 |
| 2026-04-16 | **루핑: completion handler 재스케줄 방식** | scheduleBuffer(.loops)는 전체 PCM 로드로 메모리 이슈. completion handler 재스케줄이 메모리 효율적이고 v0.5 다중 파일 확장에도 자연스러움 |

---

## 14. 참고 자료

- [Apple Developer: AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch)
- [Apple Developer: MusicKit](https://developer.apple.com/musickit/)
- [Spotify Web API 변경사항 (2024-11-27)](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)
- [djay Pro 기능 비교 참고](https://www.algoriddim.com/)
- [Web Audio Beat Detector 알고리즘 참고](https://github.com/chrisguttandin/web-audio-beat-detector) (Swift 포팅 시)

---

*최종 수정: 2026-04-16*
