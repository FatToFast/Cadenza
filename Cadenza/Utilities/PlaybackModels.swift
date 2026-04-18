import Foundation

enum PlaybackState: String {
    case idle
    case loading
    case ready
    case playing
    case paused
    case error
}

enum OriginalBPMSource: Equatable {
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
