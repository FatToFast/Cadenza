import XCTest
import Combine
@testable import Cadenza

@MainActor
final class AudioManagerGenerationTests: XCTestCase {
    func testDefaultBehaviorIsLoop() {
        XCTAssertEqual(AudioManager().playbackEndBehavior, .loop)
    }
    func testBehaviorMutable() {
        let a = AudioManager()
        a.playbackEndBehavior = .notify
        XCTAssertEqual(a.playbackEndBehavior, .notify)
    }
    func testTrackEndedSubjectEmits() {
        let a = AudioManager()
        var n = 0
        let c = a.trackEndedSubject.sink { n += 1 }
        a.trackEndedSubject.send(())
        XCTAssertEqual(n, 1)
        c.cancel()
    }
    func testDefaultNowPlayingEmpty() {
        let info = AudioManager().currentNowPlayingInfo
        XCTAssertNil(info.title)
        XCTAssertEqual(info.originalBPM, BPMRange.originalDefault)
        XCTAssertNil(info.queueContext)
    }

    func testStreamingBeatAlignmentForNinetyBPMKeepsPlaybackRateNearOne() {
        let audio = AudioManager()

        audio.setStreamingBeatAlignment(
            bpm: 89.96,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.targetBPM, 90)
        XCTAssertEqual(audio.playbackRate, 90 / 89.96, accuracy: 0.0001)
    }

    func testMetronomeRequiresConfirmedBPM() {
        let audio = AudioManager()

        // 기본 상태: needsConfirmation — BPM 확정 안 됨
        XCTAssertFalse(audio.canRunMetronomeForCurrentBeatSync)

        // BPM 확정 (grid 없이) — bpmOnly. 균등 간격 메트로놈은 가능해야 함.
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.beatSyncStatus, .bpmOnly)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)

        // grid까지 신뢰: automaticBeatSync — 정확한 박자 정렬 가능.
        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .analysis,
            beatOffsetSeconds: 0.1,
            beatTimesSeconds: [0.1, 0.6, 1.1, 1.6],
            confidence: 0.8
        )

        XCTAssertEqual(audio.beatSyncStatus, .automaticBeatSync)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
    }

    func testLowConfidenceBeatGridFallsBackToBPMOnlyMetronome() {
        let audio = AudioManager()

        audio.setStreamingBeatAlignment(
            bpm: 120,
            source: .analysis,
            beatOffsetSeconds: 0.1,
            beatTimesSeconds: [0.1, 0.6, 1.1, 1.6],
            confidence: 0.2
        )

        XCTAssertEqual(audio.beatSyncStatus, .bpmOnly)
        XCTAssertEqual(audio.beatSyncIssue, .lowConfidence)
        // 새 정책: 신뢰도 낮아도 BPM은 확정된 상태이므로 균등 간격 메트로놈은 동작.
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
    }
}
