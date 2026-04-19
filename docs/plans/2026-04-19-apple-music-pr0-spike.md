# PR 0: Apple Music 라이브러리 PCM 추출 Spike

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실기기에서 다운로드된 Apple Music 보관함 트랙 1개를 PCM으로 디코드하고 `AVAudioFile`로 읽어 `BeatAlignmentAnalyzer`가 값을 반환하는지 검증한다. 이후 PR 2~3의 진행 여부를 결정하는 게이트.

**Architecture:** 임시 spike 코드로 권한 요청 → `MPMediaQuery` → `AVAssetReader` → tmp WAV export → `AVAudioFile` + `BeatAlignmentAnalyzer` 체인을 실행. 검증 후 **코드는 삭제**하고 결과만 문서에 남긴다.

**Tech Stack:** MediaPlayer 프레임워크, AVFoundation, iOS 17+ 실기기

**Dependencies:** 설계 문서 `docs/plans/2026-04-19-apple-music-queue-design.md`. Apple Music 구독 계정, 최소 1곡 다운로드.

---

## 사전 조건

- [ ] 실기기 준비: iOS 17.0+ 디바이스, Apple ID에 Apple Music 구독 활성
- [ ] 구독 계정으로 임의 곡 1개를 기기에 **다운로드 완료**(구름 아이콘 사라진 상태)
- [ ] Xcode 프로젝트가 실기기에 설치 가능해야 함 (본 세션 이전 논의대로 유료 개발자 계정 또는 무료 계정 인증 상태)

## Task 1: 스파이크 브랜치와 디버그 진입점 준비

**Files:**
- Create: `Cadenza/Debug/AppleMusicSpike.swift` (임시, 최종 삭제)
- Modify: `Cadenza/Views/PlayerView.swift` (#if DEBUG 블록으로 버튼 1개 추가)

- [ ] **Step 1: 브랜치 생성**

```bash
git checkout -b spike/apple-music-pcm
```

- [ ] **Step 2: 임시 스파이크 파일 생성**

`Cadenza/Debug/AppleMusicSpike.swift`:

```swift
#if DEBUG
import Foundation
import MediaPlayer
import AVFoundation
import os

enum AppleMusicSpike {
    private static let logger = Logger(subsystem: "com.cadenza.app", category: "AppleMusicSpike")

    static func run() async {
        let status = await MPMediaLibrary.requestAuthorization()
        logger.info("auth status=\(status.rawValue)")
        guard status == .authorized else {
            logger.error("authorization not granted")
            return
        }

        let query = MPMediaQuery.songs()
        let items = query.items ?? []
        logger.info("library song count=\(items.count)")

        guard let target = items.first(where: { $0.assetURL != nil }) else {
            logger.error("no song with assetURL found — ensure at least one track is downloaded")
            return
        }
        logger.info("picked: \(target.title ?? "?") / \(target.artist ?? "?") / persistentID=\(target.persistentID)")
        guard let assetURL = target.assetURL else { return }

        do {
            let tmpWAV = try await exportToTmpWAV(assetURL: assetURL, persistentID: target.persistentID)
            logger.info("tmp WAV exported to \(tmpWAV.path)")

            let file = try AVAudioFile(forReading: tmpWAV)
            logger.info("AVAudioFile opened: length=\(file.length) sampleRate=\(file.processingFormat.sampleRate)")

            let result = try BeatAlignmentAnalyzer.loadOrAnalyze(url: tmpWAV, expectedBPM: nil)
            if let analysis = result.analysis {
                logger.info("analysis OK: bpm=\(analysis.estimatedBPM) offset=\(analysis.beatOffsetSeconds) confidence=\(analysis.confidence) cache=\(result.cacheStatus.rawValue)")
            } else {
                logger.error("analysis returned nil")
            }

            try FileManager.default.removeItem(at: tmpWAV)
            logger.info("tmp WAV removed")
        } catch {
            logger.error("spike failed: \(error.localizedDescription)")
        }
    }

    private static func exportToTmpWAV(assetURL: URL, persistentID: UInt64) async throws -> URL {
        let asset = AVURLAsset(url: assetURL)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio track"])
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CadenzaAppleMusicSpike", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmpURL = dir.appendingPathComponent("\(persistentID).wav")
        try? FileManager.default.removeItem(at: tmpURL)

        // AVAssetReaderTrackOutput가 16-bit interleaved PCM을 뱉으므로
        // 버퍼 포맷도 그와 동일하게 맞춰야 int16ChannelData에 정상 memcpy 가능.
        // `standardFormatWithSampleRate`는 non-interleaved Float32이라 호환 안 됨.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 2,
            interleaved: true
        ) else { throw NSError(domain: "Spike", code: 3) }
        let file = try AVAudioFile(forWriting: tmpURL, settings: format.settings)

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
               let dataPointer {
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                let frameCount = AVAudioFrameCount(length / bytesPerFrame)
                if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                    buffer.frameLength = frameCount
                    // interleaved Int16이면 int16ChannelData[0]가 (L, R, L, R, ...) 로 배치됨
                    if let dest = buffer.int16ChannelData?[0] {
                        memcpy(dest, dataPointer, length)
                    }
                    try file.write(from: buffer)
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Spike", code: 2)
        }
        return tmpURL
    }
}
#endif
```

- [ ] **Step 3: PlayerView에 디버그 진입 버튼 추가**

`Cadenza/Views/PlayerView.swift`의 `body` 아무 위치에 (추후 삭제):

```swift
#if DEBUG
Button("[Spike] Apple Music PCM 테스트") {
    Task { await AppleMusicSpike.run() }
}
#endif
```

- [ ] **Step 4: project.yml에 권한 키 임시 추가**

`project.yml` `targets.Cadenza.settings.base`에 한 줄 추가:

```yaml
INFOPLIST_KEY_NSAppleMusicUsageDescription: "[Spike] Apple Music 보관함 PCM 추출 검증"
```

`xcodegen generate` 실행.

- [ ] **Step 5: 실기기 빌드·설치, Console.app으로 `com.cadenza.app` 로그 필터**

## Task 2: Spike 실행과 결과 기록

- [ ] **Step 1: 앱 실행 → "[Spike] Apple Music PCM 테스트" 탭**

첫 실행이면 권한 팝업. 허용.

- [ ] **Step 2: Console.app 로그 관찰**

기대 출력(성공 시):
```
auth status=3
library song count=<N>
picked: <Title> / <Artist> / persistentID=<ID>
tmp WAV exported to /var/.../CadenzaAppleMusicSpike/<ID>.wav
AVAudioFile opened: length=<frames> sampleRate=44100
analysis OK: bpm=<BPM> offset=<sec> confidence=<0~1> cache=miss
tmp WAV removed
```

- [ ] **Step 3: 결과 기록**

`docs/plans/2026-04-19-apple-music-pr0-spike-results.md` 생성:

```markdown
# PR 0 Spike 결과

일시: YYYY-MM-DD
기기: <모델, iOS 버전>
구독: 활성 / 비활성
테스트 곡: <제목 / 아티스트 / persistentID>

## 결과

- [ ] 권한 요청 성공
- [ ] assetURL이 nil이 아닌 곡 발견
- [ ] AVAssetReader 초기화 성공
- [ ] 샘플 버퍼 읽기 전부 성공 (에러 없음)
- [ ] tmp WAV export 성공
- [ ] AVAudioFile 로드 성공
- [ ] BeatAlignmentAnalyzer 분석 값 반환

## 측정값

- export 소요시간: <초>
- tmp WAV 크기: <MB>
- 분석 결과 BPM / confidence: <값>

## 관찰된 이슈

<있으면 여기 기록. DRM 에러, 권한 거부, 분석 실패 등>

## 결론

☐ PR 2/3 진행 가능 (모든 체크박스 PASS)
☐ 재검토 필요 (일부 FAIL) — 다음 대응 방안:
  ...
```

- [ ] **Step 4: 실패 시나리오 대응**

결과에 따라:
- 권한 실패: 설정 확인, 앱 재설치
- assetURL nil: 다른 곡으로 재시도, 구독 상태 확인
- AVAssetReader 실패: DRM 에러 코드 확인 → 설계 재검토 트리거
- 분석 실패: 곡 자체의 파형 이슈 가능, 다른 곡으로 재시도

- [ ] **Step 5: 스파이크 결과 커밋**

```bash
git add docs/plans/2026-04-19-apple-music-pr0-spike-results.md
git commit -m "docs(plans): apple music PCM spike results"
```

## Task 3: Spike 정리

- [ ] **Step 1: 스파이크 코드 제거**

```bash
git rm Cadenza/Debug/AppleMusicSpike.swift
# PlayerView의 DEBUG 버튼 제거
# project.yml의 INFOPLIST_KEY_NSAppleMusicUsageDescription 제거 (PR 2에서 정식 추가)
```

- [ ] **Step 2: 프로젝트 재생성**

```bash
xcodegen generate
```

- [ ] **Step 3: 빌드 검증 (Spike 제거 후에도 빌드 성공)**

```bash
xattr -cr Cadenza
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project Cadenza.xcodeproj -scheme CadenzaTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/CadenzaDerivedData-pr0 test 2>&1 | tail -10
```

기대: `** TEST SUCCEEDED **`, 기존 테스트 회귀 없음.

- [ ] **Step 4: 정리 커밋**

```bash
git add -A
git commit -m "chore: remove apple music spike scaffolding"
```

- [ ] **Step 5: spike 브랜치를 main에 머지 또는 삭제**

Spike는 결과 문서만 메인으로 가져가면 됨. 코드 변경은 전부 되돌려짐. 브랜치는 결과 커밋만 cherry-pick 후 삭제 가능.

```bash
git checkout main
git cherry-pick <results-commit-sha>
git branch -D spike/apple-music-pcm
```

## Exit Criteria

- [ ] `docs/plans/2026-04-19-apple-music-pr0-spike-results.md`가 메인 브랜치에 커밋됨
- [ ] 모든 체크박스가 PASS면 PR 2/3 진행 가능, 플랜의 **결론 섹션을 "PR 2/3 진행 가능"으로 명시**
- [ ] 하나라도 FAIL이면 **설계 문서** `docs/plans/2026-04-19-apple-music-queue-design.md`에 "PR 0 결과로 재검토 필요" 섹션 추가 + 대안 검토

## Rollback

Spike 자체가 임시 코드라 되돌릴 것 없음. 실기기에 설치된 스파이크 빌드는 다음 빌드가 덮어씀.
