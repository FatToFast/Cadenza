# Cadenza Design System Redesign

**Date:** 2026-04-21
**Status:** Draft for user review
**Scope:** Design system only. Player/library/component redesigns follow in separate specs.

---

## Context

Cadenza는 러닝 중 BPM 매칭 재생을 돕는 iOS 앱이다. 현재 `DESIGN.md`에 다크 베이스 + 시안 라임 액센트가 정의되어 있으나, 실제 코드 `Constants.swift`는 핫 핑크 `#FF4F7A`를 쓰고 있어 문서-코드가 어긋나 있다. 더 중요한 것은 기존 디자인 철학이 **BPM 수치를 96pt 대형 디스플레이로 주인공화**하는 데 맞춰져 있다는 점이다.

이번 재설계의 트리거는 사용자 관찰이다:

> "지금 무슨 노래가 나오는지가 더 중요할 것 같아. 180은 한 번 세팅해놓으면 안 바꿔."

즉 실제 사용 맥락에서 **BPM은 설정값(한 번 고르면 끝)**이고, 달리는 중 힐끗 보는 순간 사용자가 알고 싶은 것은 **"지금 뭐 나와?"**이다. 기존 디자인 전제(BPM = 주인공)가 사용 맥락과 어긋나 있었다.

**이 재설계가 해결하는 것:**
- 위계 재배치: 곡 정보가 주인공, BPM은 조용한 상태 표시자
- 정체성 명확화: Cadenza가 "평범한 다크 + 액센트 하나" 템플릿에서 벗어나 고유 지문을 가짐
- 문서-코드 불일치 해소

---

## 1. Identity Principle

**곡이 주인공. BPM은 조용한 상태 표시자.**

목표 BPM은 앱을 켤 때 한 번 설정하면 거의 바꾸지 않는다. 달리는 중 화면을 힐끗 볼 때 사용자가 알고 싶은 것은 순서대로:
1. 지금 무슨 곡이 나오는가 (제목·아티스트·아트워크)
2. 좋냐/별로냐 → 스킵 여부
3. BPM/피치 상태가 정상인가 (배경 확인)

따라서 아트워크·제목·아티스트·재생 컨트롤이 **Level 1**이고, BPM·레이트·키 락은 **Level 3**이다. 크기·대비·위치 모두 이 위계를 따른다.

**앱 정체성 DNA:** "계측 도구로서의 솔직함". 단, 이 DNA는 **과장된 브루탈리스트 포스터 감성이 아니라** 상태 표시 타이포그래피(IBM Plex Mono)와 케이던스 시각화 폴백에 한정해서 표현된다. 곡 중심 플레이어의 위에 은은히 덧씌워진 레이어.

---

## 2. Color

### 2.1 팔레트

| 역할 | Hex | 용도 |
|---|---|---|
| Background | `#0A0A0F` | 앱 전체 배경 |
| Surface | `#1A1A22` | 카드·섹션·하단 상태 띠 |
| Divider | `#2A2A35` | 구분선 |
| Accent | `#00E5C7` | 재생 버튼, 진행바, BPM 배지, 액티브 상태 |
| Warning | `#FF8A3D` | "피치 변경됨" 경고 배지 |
| Text Primary | `#F5F5F7` | 곡 제목, 주요 텍스트 |
| Text Secondary | `#9A9AA5` | 아티스트명, 타임코드 |
| Text Tertiary | `#5A5A65` | 라벨, 비활성 상태 |

### 2.2 사용 규칙

- **액센트는 한 역할만.** 재생 버튼(대표 액션), 진행바, BPM 배지, 모노스페이스 상태값(ON/× 1.00)에만. 그 외 장식 목적 사용 금지.
- **아트워크 색은 건드리지 않는다.** 곡 아트워크 자체가 곡마다 배경 분위기를 만든다. Cadenza가 아트워크 위에 색을 칠하지 않는다.
- **경고는 상태에만.** Warning(오렌지)은 "피치 변경됨" 배지에만. 에러·파괴적 액션 확인에는 시스템 표준을 따른다(향후 정의).
- **색만으로 정보 전달 금지** (DESIGN.md 기존 a11y 규칙 유지): 배지는 색 + 텍스트 + 아이콘 조합.

### 2.3 대비 (WCAG AA 이상)

| 조합 | 대비 | 결과 |
|---|---|---|
| `#F5F5F7` on `#0A0A0F` | 18:1 | AAA |
| `#00E5C7` on `#0A0A0F` | 12:1 | AAA |
| `#9A9AA5` on `#0A0A0F` | 7.8:1 | AAA |
| `#5A5A65` on `#0A0A0F` | 4.6:1 | AA |

### 2.4 변경 요약

- `Constants.swift`의 `cadenzaAccent`를 `#FF4F7A` → `#00E5C7`로 되돌림
- 다른 팔레트 값은 `DESIGN.md` 4.2와 동일 유지

---

## 3. Typography

### 3.1 폰트 스택

| 역할 | 폰트 | 용도 |
|---|---|---|
| Display / Title | SF Pro Display · Heavy/Bold | 곡 제목, 화면 제목 |
| Body / UI | SF Pro Text · Regular/Medium | 아티스트명, 일반 텍스트 |
| Monospace (Status) | **IBM Plex Mono** · Regular/Medium | BPM 배지, 상태 띠, 타임코드, 라벨, 수치 |

### 3.2 스케일

| 이름 | 폰트 | 크기 | 용도 |
|---|---|---|---|
| Track Title | SF Pro Display Heavy | 26pt | 플레이어 곡 제목 (아트워크 오버랩) |
| Screen Title | SF Pro Display Bold | 28pt | 화면 전체 제목 (라이브러리 등) |
| Section Title | SF Pro Display Semibold | 20pt | 섹션 제목 |
| Body | SF Pro Text Regular | 16pt | 아티스트명, 본문 |
| Body Small | SF Pro Text Regular | 14pt | 리스트 보조 정보 |
| Mono Value | IBM Plex Mono Medium | 13pt | 상태값 (180, 1.00, ON) |
| Mono Timecode | IBM Plex Mono Regular | 12pt | 진행 시간 (1:52 / 3:04) |
| Mono Label | IBM Plex Mono Regular | 10pt, tracking 2px | 라벨 (TGT, KLK, SPM) |
| Mono Pill | IBM Plex Mono Medium | 11pt, tracking 1.5px | BPM 배지 (175 SPM) |

**숫자 렌더링:** IBM Plex Mono는 고정폭이지만, `tabular-nums` 피처를 명시해 숫자가 변해도 너비가 흔들리지 않음을 보장한다.

### 3.3 폰트 번들링

- IBM Plex Mono를 앱에 번들 (Regular + Medium 두 웨이트만)
- 예상 용량: ~200KB
- 라이선스: SIL Open Font License (상용 OK)
- 다운로드: https://fonts.google.com/specimen/IBM+Plex+Mono
- `Info.plist` `UIAppFonts` 등록, `Font.custom("IBMPlexMono-Regular", size:)` 헬퍼 제공
- 실제 렌더 샘플은 iOS 빌드에서 확인 필요 (웹 미리보기와 다를 수 있음)

### 3.4 변경 요약

- 기존 "BPM Display 96pt SF Pro Rounded Bold" **제거** (BPM은 더 이상 대형 디스플레이 주인공이 아님)
- 기존 Numeric(SF Mono) → **IBM Plex Mono로 교체**
- 나머지 SF Pro 스케일은 `DESIGN.md` 4.3과 근접 유지

---

## 4. Visual Hierarchy

세 단계. Level이 낮을수록 크고 강하게, 높을수록 작고 조용하게.

### Level 1 — 곡 정보 (주인공)

- **아트워크**: 화면 상단을 꽉 채우는 풀블리드 이미지 영역 (아래 5.1 Immersive 레이아웃)
- **곡 제목**: SF Pro Display Heavy 26pt, `#F5F5F7`, 아트워크 하단 오버랩
- **아티스트**: SF Pro Text Regular 16pt, `#9A9AA5`

### Level 2 — 핵심 액션

- **재생 버튼**: 지름 72pt 원형, `#00E5C7` 배경, `#0A0A0F` 아이콘. 화면에서 유일한 컬러 대형 원.
- **이전/다음 버튼**: 지름 56pt, 투명 배경, `#F5F5F7` 아이콘
- **진행바**: 높이 3pt, 트랙 `#2A2A35`, 진행 `#F5F5F7`

### Level 3 — 상태 표시 (조용)

- **BPM 배지**: 곡 제목 우측 pill, IBM Plex Mono 11pt, 배경 `rgba(0,229,199,0.12)`, 텍스트 `#00E5C7`. 예: `175 SPM`
- **하단 상태 띠**: Surface 배경, IBM Plex Mono 10–13pt. `TGT 180 · KLK ON · × 1.00` 형식. 라벨은 Tertiary, 값은 Primary 또는 Accent.
- **타임코드**: IBM Plex Mono 12pt, `#9A9AA5`

Level 3은 의도적으로 작고 건조하게 — **설정값이지 지금 바꾸라는 호출이 아님**을 형태로 전달.

---

## 5. Layout Primitives

### 5.1 Player Screen (Immersive)

```
┌─────────────────────────────┐
│  ⌵                  [175 SPM]│ ← 상단 바 (뒤로가기 + BPM 배지 · 반투명 오버레이)
│                              │
│                              │
│      [ ARTWORK 풀블리드 ]     │ ← 높이 약 50% · 하단으로 그라디언트
│                              │
│                              │
│▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔│
│  Midnight Run               │ ← 제목이 그라디언트 위로 떠오름
│  Daft Punk                  │
│                              │
│  ──────●────────── 1:52/3:04 │ ← 진행바 + 타임코드
│                              │
│       ⏮     ▶     ⏭         │ ← 컨트롤 (재생 버튼만 시안 원형)
│                              │
│──────────────────────────────│
│  TGT 180 · KLK ON   × 1.00  │ ← 상태 띠 (IBM Plex Mono, 작음)
└─────────────────────────────┘
```

### 5.2 아트워크 폴백 (로컬 파일, 아트워크 없음)

Immersive 레이아웃의 아트워크 영역이 케이던스 시각화로 대체된다:

- **Surface 배경** (`#0F0F14`)에 **4겹 동심원**: 바깥부터 안쪽으로 opacity 15% → 25% → 50% → filled
- **중앙 도트**: 지름 약 22% of 영역, `#00E5C7`, 희미한 글로우
- **좌상단 라벨**: IBM Plex Mono 8–9pt, tracking 2px, Tertiary, `CADENCE`
- **곡 제목 자리 (메타데이터 폴백 순서)**:
  1. ID3 Title 태그가 있으면 사용
  2. 없으면 파일명 (확장자 제거, 언더스코어→공백)
  3. 구현 spec에서 추출 로직 위치 결정 (기존 `QueueItem` 또는 별도 유틸)

시각화 자체가 "이 앱은 케이던스 맞추는 앱이다"라는 정체성을 말없이 보여준다.

### 5.3 Spacing

8pt 그리드. 일반 규칙:

| 용도 | 값 |
|---|---|
| 컴포넌트 내부 padding | 8, 12, 16pt |
| 카드/섹션 사이 | 16, 24pt |
| 화면 가장자리 여백 | 20–24pt |
| 상태 띠 상하 | 14pt |
| 메인 컨트롤 간격 | 24pt |

---

## 6. Motion

절제된 모션. 장식 애니메이션 없음.

- **비트 펄스**: 케이던스 시각화 중앙 도트만 목표 BPM에 맞춰 미세하게 발광 (scale 0.95–1.05, opacity 0.7–1.0). 그 외 요소는 정적.
- **곡 변경 전환**: 아트워크 크로스페이드 200ms. 제목·아티스트는 즉시 교체.
- **탭 피드백**: 재생/컨트롤 버튼 누름에 즉시 스케일 다운 (0.95) + 햅틱 `.impact(.light)`.
- **BPM 배지 갱신**: 즉시 교체, 전환 애니메이션 없음 (설정값이므로 조용히).

### 6.1 Reduce Motion 준수

`@Environment(\.accessibilityReduceMotion)` 활용:
- 비트 펄스 → 정적 표시 (중앙 도트가 발광하지 않고 고정)
- 아트워크 크로스페이드 → 즉시 교체

---

## 7. Accessibility (a11y)

### VoiceOver
- 아트워크: `accessibilityLabel` = "앨범 아트: {곡 제목}" 또는 폴백일 땐 "케이던스 175 SPM 시각화"
- 재생 버튼: "재생" / "정지" (상태 기반)
- BPM 배지: "곡 BPM 175, 목표 180"
- 하단 상태 띠: 묶어서 "키 락 켜짐, 재생 속도 1.00배"

### Dynamic Type
- 곡 제목·아티스트·본문: 시스템 Dynamic Type 따름 (최대 xxxLarge 지원)
- 상태 띠 모노스페이스: 고정 크기 (위계 유지 위해). `accessibility*` 카테고리에서는 하단 상태 띠가 2줄로 wrap되도록 레이아웃 허용.

### 컬러 대비 (2.3 참조)
모든 텍스트 AA 이상, 주요 텍스트 AAA.

### 색 의존 금지
"피치 변경됨" 배지 = 오렌지색 + 아이콘 + 텍스트 3중 표기.

---

## 8. Out of Scope (이번 spec에서 다루지 않음)

이번 재설계는 **디자인 시스템(색·타입·위계·기본 레이아웃 원칙)**에만 한정한다. 다음은 후속 spec으로 분리:

- Apple Music 라이브러리/검색/플레이리스트 화면 리디자인
- BPM 슬라이더/디스플레이 컴포넌트 내부 구현 디테일
- 온보딩 플로우
- 앱 아이콘 실제 디자인
- 라이트 모드 (v0~v1 다크 only 유지)
- 세팅 화면

---

## 9. Files Touched (예상)

이 스펙을 구현하는 후속 플랜이 건드릴 파일들:

- `Cadenza/Utilities/Constants.swift` — 액센트 컬러 되돌리기, Font 스택 재정의 (IBM Plex Mono 추가)
- `Cadenza/Info.plist` — `UIAppFonts`에 IBM Plex Mono 등록
- `Cadenza/Resources/Fonts/` (신규) — `IBMPlexMono-Regular.ttf`, `IBMPlexMono-Medium.ttf`
- `Cadenza/Views/PlayerView.swift` — Immersive 레이아웃 재구성, 96pt BPM 제거, 아트워크 풀블리드, 하단 상태 띠
- `Cadenza/Views/Components/BPMDisplayView.swift` — 96pt 대형 디스플레이가 더 이상 존재하지 않음. 구현 spec에서 결정: (a) 하단 상태 띠 내부 컴포넌트로 축소 재사용, (b) 완전 폐기 후 상태 띠에 인라인. 어느 쪽이든 현 형태는 제거.
- `Cadenza/Views/Components/BPMSliderView.swift` — 메인 플레이어에서 제거, 목표 BPM 변경은 세팅/모달에서만 접근 가능하도록 이동
- `Cadenza/Views/Components/` (신규) — `CadenceVisualization.swift` (아트워크 폴백), `StatusStrip.swift` (하단 상태 띠)
- `DESIGN.md` — 4.2, 4.3 섹션 업데이트 (BPM 주인공 전제 삭제, IBM Plex Mono 반영, 위계 새로 정의)

---

## 10. Verification

이 디자인 시스템이 실제로 의도대로 작동하는지 확인하는 방법:

### 기능 검증
1. **위계 테스트** (달리며 힐끗): 플레이어 스크린샷을 1초간 보고 아트워크·제목·아티스트·재생 버튼이 즉시 인지되는지. 그 다음 2초 간 BPM/레이트/키 락 상태 확인 가능한지.
2. **폴백 테스트**: 아트워크 없는 로컬 파일(예: 시뮬레이터 fixture)을 재생했을 때 케이던스 시각화가 올바른 BPM으로 렌더되는지.
3. **폰트 렌더**: 실제 iOS 빌드에서 IBM Plex Mono가 번들·등록·적용되는지 (`UIFont.fontNames(forFamilyName:)` 확인).
4. **대비 검증**: Xcode Accessibility Inspector로 모든 텍스트 쌍의 contrast ratio가 명세와 일치하는지.
5. **VoiceOver**: 모든 인터랙티브 요소가 올바른 레이블을 가지는지.
6. **Reduce Motion**: 설정 ON 상태에서 비트 펄스가 꺼지고 크로스페이드가 즉시 교체되는지.

### 디자인 검증
7. **A/B 감각 비교**: 새 디자인과 기존 96pt BPM 디자인을 같이 열어 "지금 뭐 나오지?" 인지 속도를 직접 비교.
8. **Apple Music 곡·로컬 파일·Apple Music 라이선스로 피치 변경 상태** 세 케이스에서 상태 표시가 일관되는지.

### 자동 테스트
기존 스냅샷/유닛 테스트는 색·폰트 값 변경으로 깨질 수 있다. 업데이트 대상:
- 색 관련: `Tests/` 내 Constants 참조 테스트 (있는 경우)
- 뷰 스냅샷: 구현 spec에서 결정 (snapshot testing이 프로젝트에 없다면 도입 검토는 별도 논의)

---

## 11. Open Questions (구현 spec에서 결정)

- IBM Plex Mono `tabular-nums` / `ss01` 등 feature 활성화 방식
- 비트 펄스 애니메이션 구현 방식 (`TimelineView` vs `Animation.linear(duration:).repeatForever`)
- 케이던스 시각화가 Metal/Canvas/SwiftUI 순수 도형 중 어느 방식이 배터리 효율적인지
- 아트워크 그라디언트의 정확한 높이·색 stop (곡마다 아트워크 대비 다름 → 제목 가독성)
