# Cadenza Runner-First Redesign

**Date:** 2026-04-23
**Status:** Draft for user review
**Supersedes (partially):** `2026-04-21-design-system-redesign-design.md` — 색/폰트 토큰은 유지, 화면 위계 전제는 이 스펙으로 교체됨.

---

## Context

기존 재설계 스펙(`2026-04-21`)은 "곡이 주인공, BPM은 조용한 상태 표시자"를 전제로 앱 본체 `PlayerView`의 위계를 재편했다. 그러나 이번 재브레인스토밍에서 더 근본적인 전제가 드러났다.

**사용자 관찰:**

1. 타깃 사용자는 **러너 전용**이다. 책상 앞 연습 용도는 고려 대상이 아니다.
2. 러너가 화면을 꺼내는 순간의 빈도는 **(D) 뭔가 잘못됐는지 확인** > **(E) 스킵/일시정지 조작** 순서다. 곡 확인(A)이나 진행 확인(C)은 드물다.
3. "잘못됐는지" 의심의 실제 목록은 **"재생이 멈춘 것 같음(C)"** 과 **"BPM이 내 페이스랑 안 맞음(D)"** 이다.
4. 화면을 꺼낼 때 사용자의 폰은 **잠금화면** 상태다. 앱을 포그라운드로 띄워놓는 사용 패턴이 아니다.

**결론:**
Cadenza의 실제 UI는 **앱 본체 화면이 아니라 잠금화면**이다. 가장 많이 쓰는 UI는 Live Activity와 Now Playing이고, 앱 본체는 "출발 전 세팅 + 멈췄을 때 조정"용 보조 화면이다. 그간 공들여 디자인한 `PlayerView`는 사용자의 실제 사용 빈도에 비해 과투자돼 있었다.

---

## 1. Design Principle

**러너의 실제 UI는 잠금화면이다. 앱 본체는 익숙하면 된다.**

- 잠금화면 Live Activity와 Now Playing 연동이 **P0 (제1순위 UI)**
- 앱 본체 `PlayerView`는 표준 다크 음악 플레이어 톤 — 사용자의 근육 기억에 얹히는 게 목표. 차별화보다 예측 가능성.

**서브 원칙:**

1. **배경이 심박이다.** 재생 중임의 증명은 비트 호흡(±3% 배경 밝기)으로 한다. 숫자·아이콘이 움직이지 않는다.
2. **앨범 아트는 원본 그대로.** 색을 얹지 않는다. 호흡은 커버 밖 여백에서만 일어난다.
3. **엄지 도달 영역이 주인공.** 재생/스킵 버튼은 HIG 최소(44pt)보다 크게. 땀 묻은 엄지를 전제로.
4. **시각 위계:** 곡 정보 ≳ 재생 컨트롤 > BPM. BPM은 상태값이며 주연이 아니다.

---

## 2. Scope

### In scope

- **Part 1. Live Activity** — Expanded (Lock Screen) + Dynamic Island (Compact/Minimal/Expanded)
- **Part 2. Now Playing 연동** — 로컬 파일 재생 경로에 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 보강
- **Part 3. 앱 본체 화면 축소** — 기존 재설계 스펙의 BPM 96pt·브루탈리스트 톤 축소, 표준 플레이어 톤으로 조정

### Out of scope

- 새 기능 추가 (큐 관리 개선, 신규 재생 모드 등)
- 온보딩·설정 화면 재설계
- AOD(Always-On Display) 전용 최적화 — Live Activity의 OS 기본 dim 처리만 따름
- iOS 16 미만 지원 — Live Activity는 iOS 16.1+, 버튼 인터랙션은 iOS 17+ 필요

---

## 3. Part 1 — Live Activity

### 3.1 Expanded (Lock Screen + DI Expanded)

**레이아웃:**

```
┌────────────────────────────────────┐
│  ┌────┐                            │
│  │ 🎵 │    175  SPM                │
│  │ art│    ● ─────── 1:52 / 3:04  │
│  └────┘    Song Title              │
│            Artist                   │
│                                    │
│         ⏮    ⏯    ⏭               │
└────────────────────────────────────┘
```

**치수:**

| 요소 | 크기 | 폰트/스타일 |
|---|---|---|
| 카드 배경 | rounded 20pt, 반투명 다크 `#15151C` @ 0.92 | — |
| 앨범 커버 | 64pt 정사각, rounded 10pt | 원본 이미지, 색 처리 없음 |
| BPM 숫자 | 28pt | IBM Plex Mono Medium |
| SPM 라벨 | 11pt, letter-spacing 1.5 | IBM Plex Mono Medium, `#9A9AA5` |
| 진행바 | 3pt 굵기, 전체 200pt | 트랙 `#2A2A35`, 진행 `#00E5C7` |
| 타임코드 | 10pt | IBM Plex Mono Regular, `#5A5A65` |
| 곡 제목 | 13pt | SF Pro Text Semibold, `#F5F5F7` |
| 아티스트 | 11pt | SF Pro Text Regular, `#9A9AA5` |
| ⏮ ⏭ 버튼 | 36pt 원 | 배경 `#2A2A35`, 아이콘 `#F5F5F7` |
| ⏯ 버튼 | 44pt 원 | 배경 `#00E5C7`, 아이콘 `#08080C` |

**동작:**

- 세 버튼 모두 **탭 가능** (iOS 17+ `Button(intent:)` API). 잠금 해제 없이 조작.
- 일시정지 상태면 ⏯ 아이콘이 ▶로 바뀜.
- 진행바는 재생 상태에 맞춰 애니메이션 업데이트.

### 3.2 배경 호흡 (Breathing Halo)

- **강도:** 카드 주변(외곽 4pt 오프셋)에 시안 `#00E5C7` 할로. 밝기 opacity를 0.0 ↔ 0.08 사이에서 비트에 맞춰 변동.
- **주기:** BPM / 60 Hz. 즉 175 BPM이면 초당 약 2.92회.
- **위상:** 트랙의 감지된 비트 시간에 맞춤 (기존 `currentBeatTimesSeconds` 사용).
- **커버 자체는 고정.** 호흡은 카드 외곽 할로에만 적용.
- **일시정지 시:** 호흡 중단. 할로는 0.0으로 고정.
- **AOD:** iOS의 기본 dim 처리를 따름. 커스텀 AOD 최적화 없음.

### 3.3 Dynamic Island

| 상태 | 레이아웃 |
|---|---|
| **Compact** | 좌 알약: 24pt 앨범커버 아이콘 / 우 알약: `175` (IBM Plex Mono 15pt, `#00E5C7`) |
| **Minimal** | 16pt 앨범커버 정사각 |
| **Expanded** | §3.1과 동일 |

Compact·Minimal은 iOS 제약으로 **탭 불가**. 탭하면 앱이 포그라운드로 열린다.

### 3.4 생명주기

- **시작:** 재생 시작 시 자동으로 Activity 요청.
- **유지:** 일시정지 상태에서도 유지 (표준 음악 플레이어 동작).
- **종료:** (a) 사용자가 stop, (b) 앱 종료, (c) iOS 자동 정리(8~12시간).
- **업데이트:** 곡 변경·재생/일시정지·진행 시간마다 `Activity.update`.

### 3.5 앨범 아트 없을 때

- 로컬 파일 중 아트가 없는 트랙 존재 가능.
- 플레이스홀더: 64pt 정사각, 배경 `#2A2A35`, 중앙에 ♪ 아이콘 (`#5A5A65`).
- DI Compact/Minimal에서도 같은 플레이스홀더 사용.

---

## 4. Part 2 — Now Playing 연동

### 4.1 현재 상태

- 코드 검색 결과 `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 참조가 **코드에는 없음** (문서에만 언급).
- Apple Music 스트리밍은 MusicKit이 내부적으로 Now Playing을 처리하므로 잠금화면 미디어 컨트롤이 자동 연동된다(추정).
- 로컬 파일(AVAudioEngine 기반) 재생 경로에서는 누락됐을 가능성이 높다.

### 4.2 보강 범위

**로컬 파일 재생 경로:**

- `AudioManager`가 재생 시작/변경/일시정지/정지/진행 시 `MPNowPlayingInfoCenter.default().nowPlayingInfo` 업데이트.
  - 필수 키: `MPMediaItemPropertyTitle`, `MPMediaItemPropertyArtist`, `MPMediaItemPropertyArtwork`, `MPMediaItemPropertyPlaybackDuration`, `MPNowPlayingInfoPropertyElapsedPlaybackTime`, `MPNowPlayingInfoPropertyPlaybackRate`.
- `MPRemoteCommandCenter`에 play/pause/next/previous 핸들러 등록.
- `AVAudioSession.setCategory(.playback)` 확인·보장 (로컬 재생 초기화 경로에서).
- **Info.plist에 `UIBackgroundModes` = `[audio]` 추가** — 현 Info.plist에는 해당 키 없음. 잠금 상태 재생 + 잠금화면 미디어 컨트롤 동작의 전제 조건.

**Apple Music 스트리밍:**

- 현재 동작 그대로 유지. 필요 시 보강은 별도 스펙.

### 4.3 Live Activity와의 관계

- Live Activity는 Now Playing과 **독립적으로** 띄운다 (iOS는 두 개를 동시에 허용).
- 잠금화면에는 Live Activity (Cadenza 커스텀) + 기본 Now Playing 위젯 (iOS 제공)이 동시에 보일 수 있다. 이는 애플 정책상 정상이며 러너에게 오히려 조작 옵션이 늘어난다.

---

## 5. Part 3 — 앱 본체 축소

### 5.1 유지

- 방금 재배치한 레이아웃 순서: **헤더 → 곡 정보 → BPM 디스플레이 → BPM 슬라이더 → (조건) 진행·Original BPM·싱크 디버그 → 재생 컨트롤 → 메트로놈 → 플레이리스트 불러오기**
- `2026-04-21` 스펙의 색 팔레트(`#00E5C7` 시안 액센트, `#0A0A0F` 배경 등)
- WCAG AA 대비 기준

### 5.2 조정

- **BPM 디스플레이 크기:** 현 96pt → **56pt**. "계측기처럼 거대한 BPM"이 러너 사용 맥락과 어긋남.
- **브루탈리스트 톤 축소:** 상태 띠 / 대형 모노스페이스 라벨 / 인더스트리얼 배지 등은 과장 요소. IBM Plex Mono는 **상태값(숫자·ON/OFF·타임코드)에만** 유지, 장식 라벨에는 사용 안 함.
- **배경 호흡 미적용:** 앱 본체 `PlayerView`에는 배경 호흡을 넣지 않음. 러너는 이 화면을 멈춰서 볼 때만 본다.
- **헤더 단순화:** 좌측 뒤로가기·우측 설정 외 장식 없음.

### 5.3 덜 변경되는 부분

- 각 기능 버튼·컨트롤의 동작·위치는 최근 리팩토링(`trackSelectionControls` LazyVGrid)을 유지.
- 색 토큰·폰트 스택은 기존 `Constants.swift` + `2026-04-21` 스펙 기반으로 계속 사용.

---

## 6. Open Questions

구현 단계에서 결정할 항목(이 스펙에서는 명시하지 않음):

1. **Live Activity Widget Extension 타겟**의 번들 ID·엔타이틀먼트 네이밍.
2. **배경 호흡 애니메이션의 타이밍 모델:** `withAnimation`의 시간 함수(linear vs easeInOut), 비트 직전 몇 ms부터 시작할지.
3. **아트 로딩 실패 시 재시도** 전략 (단일 실패 → 플레이스홀더 즉시? 1회 재시도?).
4. **Activity 업데이트 빈도:** 진행바는 매초 업데이트하면 ActivityKit 예산(~4~16회/hour 권장)을 초과. `Activity.update` 대신 SwiftUI `TimelineView` 활용 여부.

이 항목들은 구현 계획(Plan) 단계에서 다룬다.

---

## 7. References

- `docs/superpowers/mockups/2026-04-23-live-activity-lockscreen.svg` — 시각 목업 (Expanded, DI Compact/Minimal, 버튼 크기 비교)
- `docs/superpowers/specs/2026-04-21-design-system-redesign-design.md` — 색/타입 토큰 원본
- `DESIGN.md` — 전체 디자인 원칙 (러닝 중 한 손 조작, 고대비, 최소 정보 밀도 등)
- Apple HIG — Live Activities, Dynamic Island
