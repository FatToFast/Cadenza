import Foundation

enum PlaybackState: String {
    case idle
    case loading
    case ready
    case playing
    case paused
    case error
}

enum OriginalBPMSource: Sendable, Equatable {
    case metadata
    case analysis
    case assumedDefault
    case preset
    case manual

    var badgeText: String {
        switch self {
        case .metadata:
            return "자동 감지"
        case .analysis:
            return "자동 분석"
        case .assumedDefault:
            return "확인 필요"
        case .preset:
            return "샘플 기본값"
        case .manual:
            return "직접 입력"
        }
    }

    var helperText: String {
        switch self {
        case .metadata:
            return "파일 메타데이터에서 BPM을 읽었습니다. 필요하면 직접 수정할 수 있습니다."
        case .analysis:
            return "오디오 파형을 분석해 BPM과 박자 시작점을 추정했습니다. 필요하면 직접 수정할 수 있습니다."
        case .assumedDefault:
            return "메타데이터가 없어 120 BPM으로 가정했습니다. 정확한 속도를 위해 직접 입력하세요."
        case .preset:
            return "샘플 프리셋의 기본 BPM을 적용했습니다. 필요하면 직접 수정할 수 있습니다."
        case .manual:
            return "직접 입력한 BPM을 기준으로 재생 속도를 계산합니다."
        }
    }
}

enum ExternalBPMOctaveNormalizer {
    private static let doubleTimeThreshold = 160.0
    private static let halfTimeMin = 80.0
    private static let halfTimeMax = 115.0

    static func normalized(_ bpm: Double) -> Double {
        guard bpm.isFinite, bpm > 0 else { return bpm }

        let halfTimeBPM = bpm / 2.0
        guard bpm >= doubleTimeThreshold,
              halfTimeBPM >= halfTimeMin,
              halfTimeBPM <= halfTimeMax else {
            return bpm
        }

        return halfTimeBPM
    }
}

enum PlaybackStateRecovery {
    static func stateAfterClearingError(
        currentState: PlaybackState,
        hasLoadedTrack: Bool
    ) -> PlaybackState {
        guard currentState == .error else { return currentState }
        return hasLoadedTrack ? .ready : .idle
    }
}

struct MetronomeSyncPlan: Equatable {
    let nextBeatDelay: TimeInterval
    let startingBeatIndex: Int

    static func == (lhs: MetronomeSyncPlan, rhs: MetronomeSyncPlan) -> Bool {
        abs(lhs.nextBeatDelay - rhs.nextBeatDelay) < 0.000_1 &&
        lhs.startingBeatIndex == rhs.startingBeatIndex
    }
}

struct BeatGridMetronomeSyncPlan: Equatable {
    let syncPlan: MetronomeSyncPlan
    let beatGridIndex: Int?
}

enum MetronomeSyncPlanner {
    static func planNextBeat(
        currentSourceTime: TimeInterval,
        sourceBeatOffset: TimeInterval,
        originalBPM: Double,
        targetBPM: Double,
        beatsPerBar: Int = MetronomeDefaults.beatsPerBar
    ) -> MetronomeSyncPlan {
        guard originalBPM > 0, targetBPM > 0, beatsPerBar > 0 else {
            return MetronomeSyncPlan(nextBeatDelay: 0, startingBeatIndex: 0)
        }

        let sourceBeatDuration = 60.0 / originalBPM
        let playbackRate = targetBPM / originalBPM
        let normalizedBeatOffset = normalizedOffset(
            sourceBeatOffset,
            beatDuration: sourceBeatDuration
        )

        if currentSourceTime <= normalizedBeatOffset {
            return MetronomeSyncPlan(
                nextBeatDelay: max((normalizedBeatOffset - currentSourceTime) / playbackRate, 0),
                startingBeatIndex: 0
            )
        }

        let beatsSinceOffset = (currentSourceTime - normalizedBeatOffset) / sourceBeatDuration
        let completedBeats = Int(floor(beatsSinceOffset))
        let phase = beatsSinceOffset - floor(beatsSinceOffset)

        if phase < 0.000_1 || (1 - phase) < 0.000_1 {
            return MetronomeSyncPlan(
                nextBeatDelay: 0,
                startingBeatIndex: completedBeats % beatsPerBar
            )
        }

        let remainingSourceDelta = (1 - phase) * sourceBeatDuration
        let nextBeat = (completedBeats + 1) % beatsPerBar
        return MetronomeSyncPlan(
            nextBeatDelay: remainingSourceDelta / playbackRate,
            startingBeatIndex: nextBeat
        )
    }

    static func normalizedOffset(_ sourceBeatOffset: TimeInterval, beatDuration: TimeInterval) -> TimeInterval {
        guard beatDuration > 0 else { return 0 }
        let normalized = sourceBeatOffset.truncatingRemainder(dividingBy: beatDuration)
        return normalized >= 0 ? normalized : normalized + beatDuration
    }
}

enum BeatGridSyncPlanner {
    static func planNextBeat(
        currentSourceTime: TimeInterval,
        beatTimesSeconds: [TimeInterval],
        fallbackSourceBeatOffset: TimeInterval,
        originalBPM: Double,
        targetBPM: Double,
        beatsPerBar: Int = MetronomeDefaults.beatsPerBar
    ) -> BeatGridMetronomeSyncPlan {
        let beatTimes = sanitizedBeatTimes(beatTimesSeconds)
        guard !beatTimes.isEmpty, originalBPM > 0, targetBPM > 0 else {
            return BeatGridMetronomeSyncPlan(
                syncPlan: MetronomeSyncPlanner.planNextBeat(
                    currentSourceTime: currentSourceTime,
                    sourceBeatOffset: fallbackSourceBeatOffset,
                    originalBPM: originalBPM,
                    targetBPM: targetBPM,
                    beatsPerBar: beatsPerBar
                ),
                beatGridIndex: nil
            )
        }

        let playbackRate = targetBPM / originalBPM
        let safeSourceTime = max(currentSourceTime, 0)
        let onBeatTolerance = 0.001

        if let nextIndex = beatTimes.firstIndex(where: { $0 + onBeatTolerance >= safeSourceTime }) {
            let nextSourceBeat = beatTimes[nextIndex]
            let sourceDelta = max(nextSourceBeat - safeSourceTime, 0)
            return BeatGridMetronomeSyncPlan(
                syncPlan: MetronomeSyncPlan(
                    nextBeatDelay: sourceDelta / playbackRate,
                    startingBeatIndex: nextIndex % beatsPerBar
                ),
                beatGridIndex: nextIndex
            )
        }

        let beatDuration = 60.0 / originalBPM
        let lastIndex = max(beatTimes.count - 1, 0)
        let lastBeat = beatTimes[lastIndex]
        let beatsSinceLast = max(Int(floor((safeSourceTime - lastBeat) / beatDuration)), 0)
        let nextSourceBeat = lastBeat + (Double(beatsSinceLast) + 1) * beatDuration
        let sourceDelta = max(nextSourceBeat - safeSourceTime, 0)
        return BeatGridMetronomeSyncPlan(
            syncPlan: MetronomeSyncPlan(
                nextBeatDelay: sourceDelta / playbackRate,
                startingBeatIndex: (lastIndex + beatsSinceLast + 1) % beatsPerBar
            ),
            beatGridIndex: nil
        )
    }

    static func intervalAfterBeat(
        at beatGridIndex: Int?,
        beatTimesSeconds: [TimeInterval],
        originalBPM: Double,
        targetBPM: Double
    ) -> TimeInterval {
        let defaultDuration = targetBPM > 0 ? 60.0 / targetBPM : 0.5
        guard originalBPM > 0, targetBPM > 0 else { return defaultDuration }
        guard let beatGridIndex else { return defaultDuration }

        let beatTimes = sanitizedBeatTimes(beatTimesSeconds)
        guard beatTimes.indices.contains(beatGridIndex),
              beatTimes.indices.contains(beatGridIndex + 1) else {
            return defaultDuration
        }

        let sourceInterval = beatTimes[beatGridIndex + 1] - beatTimes[beatGridIndex]
        guard sourceInterval.isFinite, sourceInterval > 0 else { return defaultDuration }

        let playbackRate = targetBPM / originalBPM
        let adaptedDuration = sourceInterval / playbackRate
        guard adaptedDuration.isFinite, adaptedDuration > 0 else { return defaultDuration }

        let lowerBound = defaultDuration * 0.72
        let upperBound = defaultDuration * 1.32
        return min(max(adaptedDuration, lowerBound), upperBound)
    }

    private static func sanitizedBeatTimes(_ beatTimesSeconds: [TimeInterval]) -> [TimeInterval] {
        var previous: TimeInterval?
        return beatTimesSeconds
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
            .filter { beatTime in
                defer { previous = beatTime }
                guard let previous else { return true }
                return beatTime - previous > 0.05
            }
    }
}

enum BeatOffsetAdjustment {
    static func effectiveOffset(
        detectedOffset: TimeInterval,
        manualNudge: TimeInterval,
        beatDuration: TimeInterval
    ) -> TimeInterval {
        MetronomeSyncPlanner.normalizedOffset(
            detectedOffset + manualNudge,
            beatDuration: beatDuration
        )
    }

    static func normalizedManualNudge(
        _ manualNudge: TimeInterval,
        beatDuration: TimeInterval
    ) -> TimeInterval {
        guard beatDuration > 0 else { return 0 }
        let wrapped = effectiveOffset(
            detectedOffset: 0,
            manualNudge: manualNudge,
            beatDuration: beatDuration
        )
        return wrapped > beatDuration / 2 ? wrapped - beatDuration : wrapped
    }

    static func manualNudgeToAlignTap(
        currentSourceTime: TimeInterval,
        detectedOffset: TimeInterval,
        beatDuration: TimeInterval
    ) -> TimeInterval {
        guard beatDuration > 0 else { return 0 }
        let desiredOffset = MetronomeSyncPlanner.normalizedOffset(
            currentSourceTime,
            beatDuration: beatDuration
        )
        return normalizedManualNudge(
            desiredOffset - detectedOffset,
            beatDuration: beatDuration
        )
    }
}

enum RunningCadenceFitStatus: Sendable, Equatable {
    case excellent
    case usable
    case awkward
    case unsuitable
    case unknown
}

enum RunningCadenceRiskReason: Sendable, Equatable {
    case lowConfidence
    case unstableBeatGrid
}

enum BeatSyncStatus: Sendable, Equatable {
    case automaticBeatSync
    case bpmOnly
    case needsConfirmation
    case unstableBeatGrid

    var labelText: String {
        switch self {
        case .automaticBeatSync:
            return "자동 박자 맞춤"
        case .bpmOnly:
            return "BPM만 맞춤"
        case .needsConfirmation:
            return "확인 필요"
        case .unstableBeatGrid:
            return "박자 불안정"
        }
    }

    var helperText: String {
        switch self {
        case .automaticBeatSync:
            return "분석한 박자 위치에 맞춰 메트로놈을 시작합니다."
        case .bpmOnly:
            return "박자 위치 신뢰도가 낮아 BPM 기준으로만 메트로놈을 재생합니다."
        case .needsConfirmation:
            return "BPM 또는 박자 정보를 더 확인해야 합니다."
        case .unstableBeatGrid:
            return "박자 간격이 불안정해 자동 박자 맞춤을 사용하지 않습니다."
        }
    }

    var usesBeatGrid: Bool {
        self == .automaticBeatSync
    }
}

enum BeatSyncReliabilityIssue: Sendable, Equatable {
    case missingBPM
    case missingBeatGrid
    case lowConfidence
    case unstableBeatGrid
}

struct BeatSyncAssessment: Sendable, Equatable {
    let status: BeatSyncStatus
    let issue: BeatSyncReliabilityIssue?
    let confidence: Double?
    let beatIntervalVariation: Double?
    let beatCount: Int

    var shouldUseBeatGrid: Bool {
        status.usesBeatGrid
    }
}

enum BeatSyncReliability {
    static let minimumConfidence = 0.35
    static let maximumBeatIntervalVariation = 0.07
    static let minimumBeatCount = 4

    static func assess(
        originalBPM: Double?,
        confidence: Double?,
        beatTimesSeconds: [TimeInterval]
    ) -> BeatSyncAssessment {
        guard let originalBPM,
              originalBPM.isFinite,
              originalBPM > 0 else {
            return BeatSyncAssessment(
                status: .needsConfirmation,
                issue: .missingBPM,
                confidence: normalizedConfidence(confidence),
                beatIntervalVariation: nil,
                beatCount: 0
            )
        }

        let beatTimes = sanitizedBeatTimes(beatTimesSeconds)
        guard beatTimes.count >= minimumBeatCount else {
            return BeatSyncAssessment(
                status: .bpmOnly,
                issue: .missingBeatGrid,
                confidence: normalizedConfidence(confidence),
                beatIntervalVariation: nil,
                beatCount: beatTimes.count
            )
        }

        let variation = beatIntervalVariation(for: beatTimes)
        if let variation,
           variation > maximumBeatIntervalVariation {
            return BeatSyncAssessment(
                status: .unstableBeatGrid,
                issue: .unstableBeatGrid,
                confidence: normalizedConfidence(confidence),
                beatIntervalVariation: variation,
                beatCount: beatTimes.count
            )
        }

        let normalizedConfidence = normalizedConfidence(confidence)
        if let normalizedConfidence,
           normalizedConfidence < minimumConfidence {
            return BeatSyncAssessment(
                status: .bpmOnly,
                issue: .lowConfidence,
                confidence: normalizedConfidence,
                beatIntervalVariation: variation,
                beatCount: beatTimes.count
            )
        }

        return BeatSyncAssessment(
            status: .automaticBeatSync,
            issue: nil,
            confidence: normalizedConfidence,
            beatIntervalVariation: variation,
            beatCount: beatTimes.count
        )
    }

    static func beatIntervalVariation(for beatTimesSeconds: [TimeInterval]) -> Double? {
        let beatTimes = sanitizedBeatTimes(beatTimesSeconds)
        guard beatTimes.count >= 4 else { return nil }

        let intervals = zip(beatTimes, beatTimes.dropFirst())
            .map { $1 - $0 }
            .filter { $0.isFinite && $0 > 0.05 }
        guard intervals.count >= 3 else { return nil }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return nil }
        let variance = intervals.reduce(into: 0.0) { partial, interval in
            let delta = interval - mean
            partial += delta * delta
        } / Double(intervals.count)
        return sqrt(variance) / mean
    }

    private static func normalizedConfidence(_ confidence: Double?) -> Double? {
        guard let confidence, confidence.isFinite else { return nil }
        return min(max(confidence, 0), 1)
    }

    private static func sanitizedBeatTimes(_ beatTimesSeconds: [TimeInterval]) -> [TimeInterval] {
        beatTimesSeconds
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
            .reduce(into: [TimeInterval]()) { result, beatTime in
                guard let previous = result.last else {
                    result.append(beatTime)
                    return
                }
                if beatTime - previous > 0.05 {
                    result.append(beatTime)
                }
            }
    }
}

struct RunningPreviewSignal: Sendable, Equatable {
    let confidence: Double?
    let beatTimesSeconds: [TimeInterval]
}

struct RunningCadenceFit: Sendable, Equatable {
    static let targetCadence: Double = 180
    private static let pulseMultipliers: [Double] = [1, 1.5, 2, 3]

    let originalBPM: Double?
    let targetCadence: Double
    let pulseMultiplier: Double
    let playbackRate: Double
    let nativeFootCadence: Double
    let status: RunningCadenceFitStatus
    let riskReason: RunningCadenceRiskReason?

    var isRecommended: Bool {
        status == .excellent || status == .usable
    }

    var badgeText: String {
        if riskReason == .lowConfidence {
            return "신뢰도 낮음"
        }
        if riskReason == .unstableBeatGrid {
            return "박자 불안정"
        }

        switch status {
        case .excellent:
            return "러닝 적합"
        case .usable:
            return "사용 가능"
        case .awkward:
            return "박자 주의"
        case .unsuitable:
            return "러닝 부적합"
        case .unknown:
            return "BPM 미확인"
        }
    }

    var detailText: String {
        guard let originalBPM else { return "BPM 데이터 필요" }
        let ratePercent = Int((playbackRate * 100).rounded())
        let multiplierLabel = pulseMultiplier == floor(pulseMultiplier)
            ? "\(Int(pulseMultiplier))x"
            : String(format: "%.1fx", pulseMultiplier)
        return "\(Int(originalBPM.rounded())) BPM · \(multiplierLabel) · \(ratePercent)%"
    }

    static func evaluate(
        originalBPM: Double?,
        targetCadence: Double = Self.targetCadence,
        previewSignal: RunningPreviewSignal? = nil
    ) -> RunningCadenceFit {
        guard let originalBPM,
              originalBPM.isFinite,
              originalBPM > 0,
              targetCadence.isFinite,
              targetCadence > 0 else {
            return RunningCadenceFit(
                originalBPM: nil,
                targetCadence: targetCadence,
                pulseMultiplier: 1,
                playbackRate: 1,
                nativeFootCadence: 0,
                status: .unknown,
                riskReason: nil
            )
        }

        let candidates = pulseMultipliers.map { multiplier in
            let nativeCadence = originalBPM * multiplier
            let playbackRate = targetCadence / nativeCadence
            return RunningCadenceFit(
                originalBPM: originalBPM,
                targetCadence: targetCadence,
                pulseMultiplier: multiplier,
                playbackRate: playbackRate,
                nativeFootCadence: nativeCadence,
                status: status(forPlaybackRate: playbackRate),
                riskReason: nil
            )
        }

        let nonSlowingCandidates = candidates.filter { $0.playbackRate >= 1 }
        let preferredCandidates = nonSlowingCandidates.isEmpty ? candidates : nonSlowingCandidates

        let fit = preferredCandidates.min { lhs, rhs in
            let lhsPenalty = fitPenalty(lhs)
            let rhsPenalty = fitPenalty(rhs)
            if lhsPenalty == rhsPenalty {
                return lhs.pulseMultiplier < rhs.pulseMultiplier
            }
            return lhsPenalty < rhsPenalty
        } ?? RunningCadenceFit(
            originalBPM: originalBPM,
            targetCadence: targetCadence,
            pulseMultiplier: 1,
            playbackRate: targetCadence / originalBPM,
            nativeFootCadence: originalBPM,
            status: .awkward,
            riskReason: nil
        )

        return applyPreviewSignal(previewSignal, to: fit)
    }

    private static func status(forPlaybackRate playbackRate: Double) -> RunningCadenceFitStatus {
        guard playbackRate.isFinite,
              playbackRate >= Double(BPMRange.rateMin),
              playbackRate <= Double(BPMRange.rateMax) else {
            return .awkward
        }

        let deviation = abs(playbackRate - 1)
        if deviation <= 0.07 { return .excellent }
        if deviation <= 0.14 { return .usable }
        if deviation <= 0.18 { return .awkward }
        return .unsuitable
    }

    private static func fitPenalty(_ fit: RunningCadenceFit) -> Double {
        let ratePenalty = abs(log(max(fit.playbackRate, 0.0001)))
        let multiplierPenalty: Double
        switch fit.pulseMultiplier {
        case 1, 2:
            multiplierPenalty = 0
        case 1.5:
            multiplierPenalty = 0.01
        default:
            multiplierPenalty = 0.04
        }
        return ratePenalty + multiplierPenalty
    }

    private static func applyPreviewSignal(
        _ previewSignal: RunningPreviewSignal?,
        to fit: RunningCadenceFit
    ) -> RunningCadenceFit {
        guard let previewSignal else { return fit }
        let assessment = BeatSyncReliability.assess(
            originalBPM: fit.originalBPM,
            confidence: previewSignal.confidence,
            beatTimesSeconds: previewSignal.beatTimesSeconds
        )

        if assessment.issue == .unstableBeatGrid {
            return fit.with(status: .unsuitable, riskReason: .unstableBeatGrid)
        }

        if assessment.issue == .lowConfidence,
           fit.status != .unsuitable {
            return fit.with(status: .awkward, riskReason: .lowConfidence)
        }

        return fit
    }

    private func with(
        status: RunningCadenceFitStatus,
        riskReason: RunningCadenceRiskReason?
    ) -> RunningCadenceFit {
        RunningCadenceFit(
            originalBPM: originalBPM,
            targetCadence: targetCadence,
            pulseMultiplier: pulseMultiplier,
            playbackRate: playbackRate,
            nativeFootCadence: nativeFootCadence,
            status: status,
            riskReason: riskReason
        )
    }
}
