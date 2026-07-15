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
            "BPM은 확인했지만 박자 위치는 충분히 잡지 못해 BPM 균등 간격으로 메트로놈을 돌립니다."
        )
        XCTAssertEqual(
            BeatSyncStatus.bpmOnly.helperText(issue: .lowConfidence),
            "분석 신뢰도가 낮아 자동 박자 맞춤은 끄고 BPM 균등 간격으로만 메트로놈을 돌립니다."
        )
    }

    func testBeatSyncStatusAllowsMetronomeOnceBPMConfirmed() {
        XCTAssertFalse(BeatSyncStatus.needsConfirmation.allowsMetronome)
        XCTAssertTrue(BeatSyncStatus.bpmOnly.allowsMetronome)
        XCTAssertTrue(BeatSyncStatus.unstableBeatGrid.allowsMetronome)
        XCTAssertTrue(BeatSyncStatus.automaticBeatSync.allowsMetronome)
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

    func testTempoPlanUsesNativeCadenceInsideUpwardWindow() {
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 92)

        XCTAssertEqual(plan.allowedCadence, 180...190)
        XCTAssertEqual(plan.effectiveCadence, 184)
        XCTAssertEqual(plan.requiredPlaybackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(plan.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .originalSpeed)
    }

    func testTempoPlanUsesNativeHalfTimeCadenceInsideWindow() {
        let plan = BPMRange.tempoPlan(targetCadence: 140, originalBPM: 280)

        XCTAssertEqual(plan.allowedCadence, 140...150)
        XCTAssertEqual(plan.musicalTarget, 280, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveCadence, 140, accuracy: 0.0001)
        XCTAssertEqual(plan.requiredPlaybackRate, 1.0, accuracy: 0.0001)
        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .originalSpeed)
    }

    func testTempoPlanNeverDriftsBelowBaseCadence() {
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 89)

        XCTAssertEqual(plan.effectiveCadence, 180)
        XCTAssertEqual(plan.requiredPlaybackRate, 90.0 / 89.0, accuracy: 0.0001)
        XCTAssertEqual(plan.playbackRate, 90.0 / 89.0, accuracy: 0.0001)
        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .adjustedSpeed)
    }

    func testTempoPlanAcceleratesNinetySixBPMToNextHigherFold() {
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 96)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .adjustedSpeed)
        XCTAssertNil(plan.rejectionReason)
        XCTAssertEqual(plan.musicalTarget, 180, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(plan.requiredPlaybackRate, 180.0 / 96.0, accuracy: 0.0001)
        XCTAssertEqual(plan.playbackRate, 180.0 / 96.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(plan.playbackRate, 1.0)
    }

    func testTempoPlanAcceleratesSeventyBPMToNinetyBPM() {
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 70)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .adjustedSpeed)
        XCTAssertNil(plan.rejectionReason)
        XCTAssertEqual(plan.musicalTarget, 90, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(plan.requiredPlaybackRate, 90.0 / 70.0, accuracy: 0.0001)
        XCTAssertEqual(plan.playbackRate, 90.0 / 70.0, accuracy: 0.0001)
    }

    func testTempoPlanAcceleratesOneTwentyBPMToBaseCadence() {
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 120)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(plan.mode, .adjustedSpeed)
        XCTAssertNil(plan.rejectionReason)
        XCTAssertEqual(plan.musicalTarget, 180, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(plan.requiredPlaybackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(plan.playbackRate, 1.5, accuracy: 0.0001)
    }

    func testTempoPlanMakesEverySupportedCadenceAndOriginalBPMPlayableWithoutSlowing() {
        for targetCadence in stride(from: 140.0, through: 200.0, by: 1.0) {
            for originalBPM in stride(from: 30.0, through: 300.0, by: 1.0) {
                let plan = BPMRange.tempoPlan(
                    targetCadence: targetCadence,
                    originalBPM: originalBPM
                )
                let context = "Cadence: \(targetCadence), BPM: \(originalBPM)"

                XCTAssertTrue(plan.isPlayable, context)
                XCTAssertTrue(plan.requiredPlaybackRate.isFinite, context)
                XCTAssertGreaterThanOrEqual(plan.requiredPlaybackRate, 1.0, context)
                XCTAssertLessThanOrEqual(
                    plan.requiredPlaybackRate,
                    Double(BPMRange.rateMax),
                    context
                )
            }
        }
    }

    func testTempoPlanMovesAllowedWindowWithBaseCadence() {
        let plan = BPMRange.tempoPlan(targetCadence: 175, originalBPM: 92)

        XCTAssertEqual(plan.baseCadence, 175)
        XCTAssertEqual(plan.allowedCadence, 175...185)
    }

    func testTempoPlanCapsAllowedWindowAtGlobalMaximum() {
        let plan = BPMRange.tempoPlan(targetCadence: 195, originalBPM: 100)

        XCTAssertEqual(plan.baseCadence, 195)
        XCTAssertEqual(plan.allowedCadence, 195...200)
    }

    func testTempoPlanSafelyNormalizesInvalidAndOutOfRangeTargetCadences() {
        XCTAssertEqual(
            BPMRange.tempoPlan(targetCadence: .nan, originalBPM: 92).baseCadence,
            180
        )
        XCTAssertEqual(
            BPMRange.tempoPlan(targetCadence: -.infinity, originalBPM: 92).baseCadence,
            140
        )
        XCTAssertEqual(
            BPMRange.tempoPlan(targetCadence: .infinity, originalBPM: 92).baseCadence,
            200
        )
        XCTAssertEqual(
            BPMRange.tempoPlan(targetCadence: 139, originalBPM: 92).baseCadence,
            140
        )
        XCTAssertEqual(
            BPMRange.tempoPlan(targetCadence: 201, originalBPM: 92).baseCadence,
            200
        )
    }

    func testTempoPlanRejectsInvalidOriginalBPM() {
        for originalBPM in [0.0, -1.0, .infinity, -.infinity, .nan] {
            let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: originalBPM)

            XCTAssertFalse(plan.isPlayable)
            XCTAssertEqual(plan.mode, .rejected)
            XCTAssertEqual(plan.rejectionReason, .invalidOriginalBPM)
            XCTAssertEqual(plan.playbackRate, 1.0, accuracy: 0.0001)
        }
    }

    func testTempoPlanRejectsFiniteOriginalBPMOutsideSupportedRange() {
        for originalBPM in [1.0, 29.0, 301.0, 1_000.0] {
            let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: originalBPM)

            XCTAssertFalse(plan.isPlayable, "BPM: \(originalBPM)")
            XCTAssertEqual(plan.mode, .rejected, "BPM: \(originalBPM)")
            XCTAssertEqual(
                plan.rejectionReason,
                .invalidOriginalBPM,
                "BPM: \(originalBPM)"
            )
            XCTAssertEqual(plan.playbackRate, 1.0, accuracy: 0.0001)
        }
    }

    // MARK: - 옥타브 폴딩 (스티키 케이던스 → 음악 목표 템포)

    func testFoldedMusicalTargetKeepsPlaybackRateNearOne() {
        // 원곡 85 + 케이던스 170 → 목표 85, 배속 1.0 (한 박에 두 걸음)
        let mt1 = BPMRange.foldedMusicalTarget(targetCadence: 170, originalBPM: 85)
        XCTAssertEqual(mt1, 85, accuracy: 0.0001)
        XCTAssertEqual(mt1 / 85, 1.0, accuracy: 0.0001)

        // 원곡 85 + 케이던스 180 → 목표 90, 배속 ≈ 1.0588
        let mt2 = BPMRange.foldedMusicalTarget(targetCadence: 180, originalBPM: 85)
        XCTAssertEqual(mt2, 90, accuracy: 0.0001)
        XCTAssertEqual(mt2 / 85, 1.0588, accuracy: 0.0001)

        // 원곡 175 + 케이던스 175 → 목표 175, 배속 1.0
        let mt3 = BPMRange.foldedMusicalTarget(targetCadence: 175, originalBPM: 175)
        XCTAssertEqual(mt3, 175, accuracy: 0.0001)
        XCTAssertEqual(mt3 / 175, 1.0, accuracy: 0.0001)

        // 원곡 60 + 케이던스 220 → 목표 110 (55는 원곡보다 느려져 제외), 배속 ≈ 1.8333
        let mt4 = BPMRange.foldedMusicalTarget(targetCadence: 220, originalBPM: 60)
        XCTAssertEqual(mt4, 110, accuracy: 0.0001)
        XCTAssertEqual(mt4 / 60, 1.8333, accuracy: 0.0001)
    }

    func testFoldedMusicalTargetNeverSlowsDownBelowOriginal() {
        // 원곡보다 느린 재생은 러닝 불가 — 배속 >= 1.0 후보 중 최솟값을 고른다.
        // 원곡 100 + 케이던스 180: 90(0.9x)이 1.0에 더 가깝지만 느려지므로 180(1.8x) 선택.
        let mt1 = BPMRange.foldedMusicalTarget(targetCadence: 180, originalBPM: 100)
        XCTAssertEqual(mt1, 180, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(mt1 / 100, 1.0)

        // 원곡 120 + 케이던스 170: 85(0.708x) 대신 170(1.4167x).
        let mt2 = BPMRange.foldedMusicalTarget(targetCadence: 170, originalBPM: 120)
        XCTAssertEqual(mt2, 170, accuracy: 0.0001)

        // 원곡 89.96 + 케이던스 180: 90은 배속 1.0004 >= 1.0이라 그대로 유효.
        let mt3 = BPMRange.foldedMusicalTarget(targetCadence: 180, originalBPM: 89.96)
        XCTAssertEqual(mt3, 90, accuracy: 0.0001)

        // 전 범위 스모크: 어떤 조합에서도 배속 < 1.0이 나오지 않는다
        // (케이던스 90~220, 원곡 30~300 — 상향 후보 ×4가 항상 존재).
        for cadence in stride(from: 90.0, through: 220.0, by: 5.0) {
            for original in stride(from: 30.0, through: 300.0, by: 5.0) {
                let folded = BPMRange.foldedMusicalTarget(targetCadence: cadence, originalBPM: original)
                XCTAssertGreaterThanOrEqual(
                    folded / original, 1.0 - 1e-9,
                    "cadence \(cadence), original \(original) → 배속 \(folded / original)"
                )
            }
        }
    }

    func testFoldedMusicalTargetReturnsCadenceWhenOriginalBPMNonPositive() {
        // originalBPM <= 0이면 폴딩 근거가 없어 케이던스를 그대로 반환 (배속 가드는 별도 유지).
        XCTAssertEqual(BPMRange.foldedMusicalTarget(targetCadence: 175, originalBPM: 0), 175)
        XCTAssertEqual(BPMRange.foldedMusicalTarget(targetCadence: 175, originalBPM: -10), 175)
    }

    func testMetronomeCadenceClampsRealCadenceWithoutDoubling() {
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 90), 140)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 95), 140)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 139), 140)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 180), 180)
        XCTAssertEqual(BPMRange.metronomeCadence(forTargetBPM: 201), 200)
    }

    func testBeatGridIntervalUsesRealCadence() {
        let playbackTargetBPM = 180.0
        let metronomeBPM = BPMRange.metronomeCadence(forTargetBPM: playbackTargetBPM)
        let metronomeSourceCadenceBPM = 180.0 * (metronomeBPM / playbackTargetBPM)

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

    func testBeatGridCadenceInterpolatorSupportsFourfoldPulse() {
        XCTAssertEqual(
            BeatGridCadenceInterpolator.multiplier(
                effectiveCadence: 184,
                musicalTargetBPM: 46
            ),
            4
        )

        let subdivided = BeatGridCadenceInterpolator.subdivide(
            beatTimesSeconds: [0, 4.0 / 3.0, 8.0 / 3.0],
            multiplier: 4
        )

        XCTAssertEqual(subdivided.count, 9)
        XCTAssertEqual(subdivided[0], 0, accuracy: 0.0001)
        XCTAssertEqual(subdivided[1], 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(subdivided[2], 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(subdivided[3], 1.0, accuracy: 0.0001)
        XCTAssertEqual(subdivided[4], 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(subdivided[8], 8.0 / 3.0, accuracy: 0.0001)
    }

    func testCadenceVisualizationDescribesEffectiveCadenceInSPM() {
        let visualization = CadenceVisualization(cadence: 184, isActive: true)

        XCTAssertEqual(visualization.cadence, 184)
        XCTAssertEqual(
            CadenceVisualization.accessibilityDescription(for: 184),
            "케이던스 184 SPM 시각화"
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
        XCTAssertEqual(fit.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(fit.detailText, "90 BPM · 180 SPM · 원곡 속도")
    }

    func testRunningCadenceFitReportsNativeNinetyFiveAsOriginalSpeed() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 95, targetCadence: 180)

        XCTAssertEqual(fit.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, 190, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .excellent)
        XCTAssertTrue(fit.isRecommended)
        XCTAssertEqual(fit.detailText, "95 BPM · 190 SPM · 원곡 속도")
    }

    func testRunningCadenceFitMarksOneTwentyAccelerationAsAwkward() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 120)
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 120)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(fit.playbackRate, plan.requiredPlaybackRate, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, plan.effectiveCadence, accuracy: 0.0001)
        XCTAssertEqual(fit.playbackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .awkward)
        XCTAssertEqual(fit.badgeText, "박자 주의")
        XCTAssertEqual(fit.detailText, "120 BPM · 180 SPM · 150%")
    }

    func testRunningCadenceFitReportsAdjustedTempoPlanRateAndCadence() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 80, targetCadence: 180)
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 80)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(fit.playbackRate, plan.requiredPlaybackRate, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, plan.effectiveCadence, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .usable)
        XCTAssertTrue(fit.isRecommended)
        XCTAssertEqual(fit.detailText, "80 BPM · 180 SPM · 113%")
    }

    func testRunningCadenceFitMarksNinetySixAccelerationAsAwkward() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 96, targetCadence: 180)
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 96)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(fit.playbackRate, plan.requiredPlaybackRate, accuracy: 0.0001)
        XCTAssertEqual(fit.playbackRate, 180.0 / 96.0, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .awkward)
        XCTAssertEqual(fit.detailText, "96 BPM · 180 SPM · 188%")
    }

    func testRunningCadenceFitMarksRejectedInvalidBPMAsUnsuitable() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 0)

        XCTAssertEqual(fit.status, .unsuitable)
        XCTAssertFalse(fit.isRecommended)
        XCTAssertEqual(fit.badgeText, "러닝 부적합")
    }

    func testRunningCadenceFitKeepsMissingBPMUnknown() {
        let fit = RunningCadenceFit.evaluate(originalBPM: nil)

        XCTAssertEqual(fit.status, .unknown)
        XCTAssertEqual(fit.badgeText, "BPM 미확인")
    }

    func testRunningCadenceFitDoesNotExposeNonFiniteRejectedBPMForDisplay() {
        for invalidBPM in [Double.nan, .infinity, -.infinity] {
            let fit = RunningCadenceFit.evaluate(originalBPM: invalidBPM)

            XCTAssertEqual(fit.status, .unsuitable)
            XCTAssertNil(fit.originalBPM)
            if fit.originalBPM == nil {
                XCTAssertEqual(fit.detailText, "BPM 데이터 필요")
            }
        }
    }

    func testRunningCadenceFitMarksLowPreviewConfidenceAsAwkward() {
        let fit = RunningCadenceFit.evaluate(
            originalBPM: 90,
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
            originalBPM: 90,
            previewSignal: RunningPreviewSignal(
                confidence: 0.8,
                beatTimesSeconds: [0.0, 0.5, 1.18, 1.47, 2.1]
            )
        )

        XCTAssertEqual(fit.status, .unsuitable)
        XCTAssertEqual(fit.riskReason, .unstableBeatGrid)
        XCTAssertEqual(fit.badgeText, "박자 불안정")
    }

    func testRunningCadenceFitMarksOnePointTwoFiveAccelerationAsAwkward() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 72)

        XCTAssertEqual(fit.playbackRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .awkward)
        XCTAssertEqual(fit.badgeText, "박자 주의")
    }

    func testRunningCadenceFitMarksSeventyBPMAccelerationAsAwkward() {
        let fit = RunningCadenceFit.evaluate(originalBPM: 70)
        let plan = BPMRange.tempoPlan(targetCadence: 180, originalBPM: 70)

        XCTAssertTrue(plan.isPlayable)
        XCTAssertEqual(fit.playbackRate, 90.0 / 70.0, accuracy: 0.0001)
        XCTAssertEqual(fit.nativeFootCadence, 180, accuracy: 0.0001)
        XCTAssertEqual(fit.status, .awkward)
        XCTAssertEqual(fit.badgeText, "박자 주의")
    }

    // MARK: - BPMOctaveChoice

    func testBPMOctavePairFromHighBPM() {
        let pair = BPMOctaveChoice.ambiguousPair(for: 174)
        XCTAssertEqual(pair, BPMOctaveChoicePair(lower: 87, upper: 174))
    }

    func testBPMOctavePairFromLowBPM() {
        let pair = BPMOctaveChoice.ambiguousPair(for: 87)
        XCTAssertEqual(pair, BPMOctaveChoicePair(lower: 87, upper: 174))
    }

    func testBPMOctavePairNilInMidRange() {
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: 120))
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: 130))
    }

    func testBPMOctavePairRejectsOutOfBounds() {
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: 50))
    }

    func testBPMOctavePairRejectsInvalidInputs() {
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: 0))
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: -1))
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: .nan))
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: .infinity))
    }

    func testBPMOctavePairRejectsTooHighDouble() {
        // 220 over the upper bound — ambiguous pair must not return >220 BPM
        XCTAssertNil(BPMOctaveChoice.ambiguousPair(for: 240))
    }

}
