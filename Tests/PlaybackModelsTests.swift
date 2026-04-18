import XCTest
@testable import Cadenza

final class PlaybackModelsTests: XCTestCase {
    func testMetronomeSyncPlanWaitsForFirstDetectedBeatAtTrackStart() {
        XCTAssertEqual(
            MetronomeSyncPlanner.planNextBeat(
                currentSourceTime: 0,
                sourceBeatOffset: 0.24,
                originalBPM: 180,
                targetBPM: 180
            ),
            MetronomeSyncPlan(nextBeatDelay: 0.24, startingBeatIndex: 0)
        )
    }

    func testMetronomeSyncPlanFiresImmediatelyWhenSeekLandsOnBeat() {
        XCTAssertEqual(
            MetronomeSyncPlanner.planNextBeat(
                currentSourceTime: 2.24,
                sourceBeatOffset: 0.24,
                originalBPM: 180,
                targetBPM: 180
            ),
            MetronomeSyncPlan(nextBeatDelay: 0, startingBeatIndex: 2)
        )
    }

    func testMetronomeSyncPlanConvertsSourceDeltaIntoTargetTempoDelay() {
        XCTAssertEqual(
            MetronomeSyncPlanner.planNextBeat(
                currentSourceTime: 0.35,
                sourceBeatOffset: 0.24,
                originalBPM: 120,
                targetBPM: 180
            ),
            MetronomeSyncPlan(nextBeatDelay: 0.26, startingBeatIndex: 1)
        )
    }

    func testEffectiveBeatOffsetWrapsForwardWithinBeatDuration() {
        XCTAssertEqual(
            BeatOffsetAdjustment.effectiveOffset(
                detectedOffset: 0.48,
                manualNudge: 0.08,
                beatDuration: 0.5
            ),
            0.06,
            accuracy: 0.0001
        )
    }

    func testEffectiveBeatOffsetWrapsNegativeAdjustmentIntoBeatWindow() {
        XCTAssertEqual(
            BeatOffsetAdjustment.effectiveOffset(
                detectedOffset: 0.05,
                manualNudge: -0.12,
                beatDuration: 0.5
            ),
            0.43,
            accuracy: 0.0001
        )
    }

    func testManualNudgeToAlignTapMovesCurrentSourceTimeOntoBeatGrid() {
        XCTAssertEqual(
            BeatOffsetAdjustment.manualNudgeToAlignTap(
                currentSourceTime: 1.37,
                detectedOffset: 0.24,
                beatDuration: 0.5
            ),
            0.13,
            accuracy: 0.0001
        )
    }

    func testClearingErrorLeavesNonErrorStateUntouched() {
        XCTAssertEqual(
            PlaybackStateRecovery.stateAfterClearingError(
                currentState: .playing,
                hasLoadedTrack: true
            ),
            .playing
        )
    }

    func testClearingImportErrorWithoutLoadedTrackRecoversToIdle() {
        XCTAssertEqual(
            PlaybackStateRecovery.stateAfterClearingError(
                currentState: .error,
                hasLoadedTrack: false
            ),
            .idle
        )
    }

    func testClearingErrorWithLoadedTrackRecoversToReady() {
        XCTAssertEqual(
            PlaybackStateRecovery.stateAfterClearingError(
                currentState: .error,
                hasLoadedTrack: true
            ),
            .ready
        )
    }

    func testPresetBadgeTextIsExplicit() {
        XCTAssertEqual(OriginalBPMSource.preset.badgeText, "샘플 기본값")
    }

    func testAllBPMSourceBadgeTextsStayStable() {
        XCTAssertEqual(OriginalBPMSource.metadata.badgeText, "자동 감지")
        XCTAssertEqual(OriginalBPMSource.analysis.badgeText, "자동 분석")
        XCTAssertEqual(OriginalBPMSource.assumedDefault.badgeText, "확인 필요")
        XCTAssertEqual(OriginalBPMSource.manual.badgeText, "직접 입력")
    }

    func testPresetHelperTextExplainsPresetSource() {
        XCTAssertTrue(OriginalBPMSource.preset.helperText.contains("샘플"))
    }

    func testMetadataAndAssumedDefaultHelpersDescribeTheirSources() {
        XCTAssertTrue(OriginalBPMSource.metadata.helperText.contains("메타데이터"))
        XCTAssertTrue(OriginalBPMSource.analysis.helperText.contains("분석"))
        XCTAssertTrue(OriginalBPMSource.assumedDefault.helperText.contains("120 BPM"))
    }
}
