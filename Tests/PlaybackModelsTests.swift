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

    func testBeatGridSyncPlanFollowsDetectedBeatTimestamps() {
        let plan = BeatGridSyncPlanner.planNextBeat(
            currentSourceTime: 0.90,
            beatTimesSeconds: [0.24, 0.93, 1.57],
            fallbackSourceBeatOffset: 0.24,
            originalBPM: 90,
            targetBPM: 90
        )

        XCTAssertEqual(plan.syncPlan.nextBeatDelay, 0.03, accuracy: 0.0001)
        XCTAssertEqual(plan.syncPlan.startingBeatIndex, 1)
        XCTAssertEqual(plan.beatGridIndex, 1)
    }

    func testBeatGridIntervalUsesDetectedNextBeatSpacing() {
        XCTAssertEqual(
            BeatGridSyncPlanner.intervalAfterBeat(
                at: 1,
                beatTimesSeconds: [0.24, 0.93, 1.57],
                originalBPM: 90,
                targetBPM: 90
            ),
            0.64,
            accuracy: 0.0001
        )
    }

    func testBeatGridSyncPlanFallsBackAfterDetectedGridEnds() {
        let plan = BeatGridSyncPlanner.planNextBeat(
            currentSourceTime: 2.12,
            beatTimesSeconds: [0.24, 0.93, 1.57],
            fallbackSourceBeatOffset: 0.24,
            originalBPM: 90,
            targetBPM: 90
        )

        XCTAssertEqual(plan.syncPlan.nextBeatDelay, 0.1167, accuracy: 0.0001)
        XCTAssertEqual(plan.syncPlan.startingBeatIndex, 3)
        XCTAssertNil(plan.beatGridIndex)
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

    func testBeatSyncReliabilityAcceptsConfidentStableBeatGrid() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: 120,
            confidence: 0.74,
            beatTimesSeconds: [0.0, 0.5, 1.0, 1.5]
        )

        XCTAssertEqual(assessment.status, .automaticBeatSync)
        XCTAssertNil(assessment.issue)
        XCTAssertTrue(assessment.shouldUseBeatGrid)
        XCTAssertEqual(assessment.beatCount, 4)
    }

    func testBeatSyncReliabilityFallsBackToBPMOnlyForLowConfidence() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: 120,
            confidence: 0.21,
            beatTimesSeconds: [0.0, 0.5, 1.0, 1.5]
        )

        XCTAssertEqual(assessment.status, .bpmOnly)
        XCTAssertEqual(assessment.issue, .lowConfidence)
        XCTAssertFalse(assessment.shouldUseBeatGrid)
    }

    func testBeatSyncReliabilityRejectsUnstableBeatGrid() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: 120,
            confidence: 0.8,
            beatTimesSeconds: [0.0, 0.5, 1.18, 1.47, 2.1]
        )

        XCTAssertEqual(assessment.status, .unstableBeatGrid)
        XCTAssertEqual(assessment.issue, .unstableBeatGrid)
        XCTAssertFalse(assessment.shouldUseBeatGrid)
    }

    func testBeatSyncReliabilityFallsBackToBPMOnlyWhenGridIsMissing() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: 120,
            confidence: 0.9,
            beatTimesSeconds: []
        )

        XCTAssertEqual(assessment.status, .bpmOnly)
        XCTAssertEqual(assessment.issue, .missingBeatGrid)
        XCTAssertFalse(assessment.shouldUseBeatGrid)
    }

    func testBeatSyncReliabilityFallsBackToBPMOnlyWhenGridHasTooFewBeats() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: 120,
            confidence: 0.9,
            beatTimesSeconds: [0.0, 0.5, 1.0]
        )

        XCTAssertEqual(assessment.status, .bpmOnly)
        XCTAssertEqual(assessment.issue, .missingBeatGrid)
        XCTAssertEqual(assessment.beatCount, 3)
        XCTAssertFalse(assessment.shouldUseBeatGrid)
    }

    func testBeatSyncReliabilityNeedsConfirmationWhenBPMIsMissing() {
        let assessment = BeatSyncReliability.assess(
            originalBPM: nil,
            confidence: 0.9,
            beatTimesSeconds: [0.0, 0.5, 1.0, 1.5]
        )

        XCTAssertEqual(assessment.status, .needsConfirmation)
        XCTAssertEqual(assessment.issue, .missingBPM)
        XCTAssertFalse(assessment.shouldUseBeatGrid)
    }

    func testBeatSyncStatusHelperExplainsBPMOnlyReasonsSeparately() {
        XCTAssertEqual(
            BeatSyncStatus.bpmOnly.helperText(issue: .missingBeatGrid),
            "BPM은 확인했지만 박자 위치는 충분히 잡지 못해 BPM 기준으로 재생합니다."
        )
        XCTAssertEqual(
            BeatSyncStatus.bpmOnly.helperText(issue: .lowConfidence),
            "분석 신뢰도가 낮아 BPM 기준으로만 메트로놈을 재생합니다."
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

    func testAutomaticTargetKeepsSlowTracksNearOriginalTempo() {
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 89), 90)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 90), 90)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 92), 90)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 99), 90)
    }

    func testAutomaticTargetUsesDoubleTimeAtOneHundredAndAbove() {
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 100), 180)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 103), 180)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 120), 180)
        XCTAssertEqual(BPMRange.automaticTarget(forOriginalBPM: 128), 180)
    }

    func testMetronomeCadenceUsesDoubleTimeForNinetyTarget() {
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 90), 180)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 95), 190)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 180), 180)
    }

    func testBeatGridIntervalCanClickDoubleTimeWhilePlaybackTargetStaysNinety() {
        let playbackTargetBPM = 90.0
        let metronomeBPM = BPMRange.metronomeCadence(forTargetBPM: playbackTargetBPM)
        let metronomeSourceCadenceBPM = 90.0 * (metronomeBPM / playbackTargetBPM)

        XCTAssertEqual(
            BeatGridSyncPlanner.intervalAfterBeat(
                at: 0,
                beatTimesSeconds: [0, 1.0 / 3.0, 2.0 / 3.0],
                originalBPM: metronomeSourceCadenceBPM,
                targetBPM: metronomeBPM
            ),
            1.0 / 3.0,
            accuracy: 0.0001
        )
    }

    func testBPMOctaveResolverPrefersHalfTimeWhenDoubleTimeCandidateIsLikely() {
        let resolved = BPMOctaveResolver.resolve(candidates: [
            BPMCandidate(bpm: 94, score: 0.42),
            BPMCandidate(bpm: 95, score: 0.48),
            BPMCandidate(bpm: 188, score: 1.0),
        ])

        XCTAssertEqual(resolved, 95)
    }

    func testBPMOctaveResolverKeepsHighTempoWhenHalfTimeCandidateIsWeak() {
        let resolved = BPMOctaveResolver.resolve(candidates: [
            BPMCandidate(bpm: 94, score: 0.20),
            BPMCandidate(bpm: 188, score: 1.0),
        ])

        XCTAssertEqual(resolved, 188)
    }

    func testBPMOctaveResolverDoesNotHalveMidTempoCandidate() {
        let resolved = BPMOctaveResolver.resolve(candidates: [
            BPMCandidate(bpm: 71, score: 0.8),
            BPMCandidate(bpm: 142, score: 1.0),
        ])

        XCTAssertEqual(resolved, 142)
    }

    func testBPMIntervalRefinementMovesPeakBetweenAdjacentIntervals() {
        let refinedInterval = BPMIntervalRefinement.refinedInterval(
            scoresByInterval: [
                46: 0.0001603688,
                47: 0.0001612668,
                48: 0.0001188420,
            ],
            bestInterval: 47
        )

        XCTAssertEqual(refinedInterval, 46.52, accuracy: 0.01)
    }

    func testBPMOctaveResolverKeepsRefinedDrowningTempo() {
        let resolved = BPMOctaveResolver.resolve(candidates: [
            BPMCandidate(bpm: 107.67, score: 0.0001188420),
            BPMCandidate(bpm: 111.09, score: 0.0001612668),
            BPMCandidate(bpm: 112.35, score: 0.0001603688),
        ])

        XCTAssertEqual(resolved ?? 0, 111.09, accuracy: 0.01)
    }

    func testBPMOctaveResolverPrefersSlowTempoOverStrongOnePointFiveHarmonic() {
        let resolved = BPMOctaveResolver.resolve(candidates: [
            BPMCandidate(bpm: 74.90, score: 0.0000184775),
            BPMCandidate(bpm: 112.75, score: 0.0000186446),
            BPMCandidate(bpm: 114.84, score: 0.0000168609),
        ])

        XCTAssertEqual(resolved ?? 0, 74.90, accuracy: 0.01)
    }

    func testExternalBPMOctaveNormalizerHalvesLikelyDoubleTimeValues() {
        XCTAssertEqual(ExternalBPMOctaveNormalizer.normalized(178.03), 89.015, accuracy: 0.001)
        XCTAssertEqual(ExternalBPMOctaveNormalizer.normalized(207.79), 103.895, accuracy: 0.001)
    }

    func testExternalBPMOctaveNormalizerKeepsOrdinaryAndClearlyFastValues() {
        XCTAssertEqual(ExternalBPMOctaveNormalizer.normalized(146), 146, accuracy: 0.001)
        XCTAssertEqual(ExternalBPMOctaveNormalizer.normalized(78.97), 78.97, accuracy: 0.001)
        XCTAssertEqual(ExternalBPMOctaveNormalizer.normalized(250), 250, accuracy: 0.001)
    }

    func testRunningCadenceFitRecognizesNinetyAsNaturalDoubleTime() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 90)

        XCTAssertEqual(fit.status, .excellent)
        XCTAssertEqual(fit.pulseMultiplier, 2.0)
        XCTAssertEqual(fit.playbackRate, 1.0, accuracy: 0.0001)
    }

    func testRunningCadenceFitRecognizesOneTwentyAsNaturalThreeOverTwo() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 120)

        XCTAssertEqual(fit.status, .excellent)
        XCTAssertEqual(fit.pulseMultiplier, 1.5)
        XCTAssertEqual(fit.playbackRate, 1.0, accuracy: 0.0001)
    }

    func testRunningCadenceFitMarksLargeSpeedChangesAsAwkward() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 150)

        XCTAssertEqual(fit.status, .unsuitable)
        XCTAssertFalse(fit.isRecommended)
    }

    func testRunningCadenceFitWarnsButDoesNotSlowOneHundredThreeBPM() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 103)

        XCTAssertEqual(fit.status, .awkward)
        XCTAssertGreaterThan(fit.playbackRate, 1.0)
    }

    func testRunningCadenceFitRejectsInvalidBPM() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 0)

        XCTAssertEqual(fit.status, .unknown)
        XCTAssertEqual(fit.badgeText, "BPM 미확인")
    }

    func testRunningCadenceFitMarksLowPreviewConfidenceAsAwkward() {
        let fit = RunningCadenceFit.evaluate(
            originalBPM: 120,
            previewSignal: RunningPreviewSignal(
                confidence: 0.21,
                beatTimesSeconds: [0.0, 0.5, 1.0, 1.5]
            )
        )

        XCTAssertEqual(fit.status, .awkward)
        XCTAssertEqual(fit.riskReason, .lowConfidence)
        XCTAssertEqual(fit.badgeText, "신뢰도 낮음")
    }

    func testRunningCadenceFitMarksUnstablePreviewBeatGridAsUnsuitable() {
        let fit = RunningCadenceFit.evaluate(
            originalBPM: 120,
            previewSignal: RunningPreviewSignal(
                confidence: 0.8,
                beatTimesSeconds: [0.0, 0.5, 1.18, 1.47, 2.1]
            )
        )

        XCTAssertEqual(fit.status, .unsuitable)
        XCTAssertEqual(fit.riskReason, .unstableBeatGrid)
        XCTAssertEqual(fit.badgeText, "박자 불안정")
    }

    func testRunningCadenceFitMarksExtremeSpeedUpAsUnsuitable() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 72)

        XCTAssertEqual(fit.status, .unsuitable)
        XCTAssertEqual(fit.badgeText, "러닝 부적합")
    }
}
