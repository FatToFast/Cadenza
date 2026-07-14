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
        // 케이던스를 명시적으로 고정해 UserDefaults 영속값에 의존하지 않게 한다.
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 89.96,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        // 케이던스는 스티키 — 곡 BPM 도착에도 바뀌지 않는다.
        XCTAssertEqual(audio.targetBPM, 180)
        // 원곡 89.96에 옥타브 폴딩 → 음악 목표 90 → 배속 ≈ 1.0.
        XCTAssertEqual(audio.musicalTargetBPM, 90, accuracy: 0.0001)
        XCTAssertEqual(audio.playbackRate, 90 / 89.96, accuracy: 0.0001)
    }

    func testConfirmedNinetyFiveBPMUsesNativeOneNinetyCadence() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 95,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.tempoPlan.effectiveCadence, 190)
        XCTAssertEqual(audio.playbackRate, audio.tempoPlan.playbackRate, accuracy: 0.0001)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(audio.metronomeBPM, 190)
        XCTAssertTrue(audio.isCurrentTempoPlayable)
    }

    func testConfirmedNinetySixBPMRejectsUnsafePlaybackRate() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 96,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertFalse(audio.tempoPlan.isPlayable)
        XCTAssertGreaterThan(audio.tempoPlan.requiredPlaybackRate, 1.25)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(audio.tempoRejectionMessage, "케이던스 범위에 맞지 않는 곡입니다")
    }

    func testConfirmedEightyNineBPMAdjustsToBaseCadence() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.setStreamingBeatAlignment(
            bpm: 89,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertTrue(audio.isCurrentTempoPlayable)
        XCTAssertEqual(audio.tempoPlan.effectiveCadence, 180)
        XCTAssertEqual(audio.playbackRate, 90.0 / 89.0, accuracy: 0.0001)
        XCTAssertEqual(audio.metronomeBPM, 180)
    }

    func testAssumedDefaultBPMNeverAppliesTempoTransform() {
        let audio = AudioManager()
        audio.targetBPM = 180

        audio.applyAutoBPMDefault(144)

        XCTAssertEqual(audio.originalBPMSource, .assumedDefault)
        XCTAssertEqual(audio.tempoPlan.requiredPlaybackRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertNil(audio.tempoRejectionMessage)
    }

    func testMetronomeOnlyModeCanStartWithoutPlayableTrackTempo() {
        let audio = AudioManager()
        audio.targetBPM = 180
        audio.metronomeEnabled = true

        audio.setStreamingBeatAlignment(
            bpm: 96,
            source: .metadata,
            beatOffsetSeconds: nil
        )

        XCTAssertFalse(audio.hasLoadedTrack)
        XCTAssertTrue(audio.canRunMetronomeForCurrentBeatSync)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertTrue(audio.canStartPlayback)
    }

    func testConfirmedRejectedLocalTrackCannotStartPlayback() async {
        let audio = AudioManager()
        audio.targetBPM = 180

        await audio.loadSampleTrack(.clickLoop)

        XCTAssertEqual(audio.state, .ready)
        XCTAssertTrue(audio.hasLoadedTrack)
        XCTAssertFalse(audio.isCurrentTempoPlayable)
        XCTAssertFalse(audio.canStartPlayback)

        audio.play()

        XCTAssertEqual(audio.state, .ready)
    }

    func testUnconfirmedLocalTrackCannotStartPlayback() async {
        let audio = AudioManager()
        audio.targetBPM = 180
        await audio.loadSampleTrack(.warmupGroove)
        audio.setStreamingBeatAlignment(
            bpm: nil,
            source: .assumedDefault,
            beatOffsetSeconds: nil
        )

        XCTAssertEqual(audio.state, .ready)
        XCTAssertTrue(audio.hasLoadedTrack)
        XCTAssertEqual(audio.originalBPMSource, .assumedDefault)
        XCTAssertFalse(audio.canStartPlayback)

        audio.play()

        XCTAssertEqual(audio.state, .ready)
    }

    /// 스티키 케이던스: streaming BPM 해석이 도착해도 사용자의 케이던스는 유지된다.
    func testStreamingBeatAlignmentDoesNotOverwriteStickyCadence() {
        let audio = AudioManager()
        audio.targetBPM = 170

        audio.setStreamingBeatAlignment(
            bpm: 85,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        XCTAssertEqual(audio.targetBPM, 170)
        XCTAssertEqual(audio.playbackRate, 1.0, accuracy: 0.0001)

        // 다른 곡(원곡 128)으로 바뀌어도 케이던스는 그대로.
        audio.setStreamingBeatAlignment(
            bpm: 128,
            source: .metadata,
            beatOffsetSeconds: nil
        )
        XCTAssertEqual(audio.targetBPM, 170)
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
