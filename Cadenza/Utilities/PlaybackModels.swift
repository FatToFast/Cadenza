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
    case streamingGuide
    case streamingAnchor

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
        case .streamingGuide:
            return "BPM 가이드"
        case .streamingAnchor:
            return "박자 맞춤"
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
        case .streamingGuide:
            return "Apple Music 스트리밍은 BPM만 맞춘 가이드입니다. 박자 기준 없음 상태입니다."
        case .streamingAnchor:
            return "저장된 박자 기준으로 Apple Music 메트로놈을 맞춥니다."
        }
    }
}

struct StreamingBeatAnchorStore {
    private let defaults: UserDefaults
    private let prefix = "streamingBeatAnchor.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func offset(title: String, artist: String?) -> TimeInterval? {
        let key = storageKey(title: title, artist: artist)
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value.isFinite ? value : nil
    }

    func saveOffset(_ offset: TimeInterval, title: String, artist: String?) {
        guard offset.isFinite else { return }
        defaults.set(offset, forKey: storageKey(title: title, artist: artist))
    }

    func removeOffset(title: String, artist: String?) {
        defaults.removeObject(forKey: storageKey(title: title, artist: artist))
    }

    private func storageKey(title: String, artist: String?) -> String {
        "\(prefix).\(normalized(title)).\(normalized(artist ?? ""))"
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber }
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

enum StreamingBeatAnchorEstimator {
    static let requiredTapCount = 8

    static func estimatedOffset(
        tapTimes: [TimeInterval],
        beatDuration: TimeInterval
    ) -> TimeInterval? {
        guard beatDuration > 0 else { return nil }
        let phases = tapTimes
            .filter { $0.isFinite && $0 >= 0 }
            .map { MetronomeSyncPlanner.normalizedOffset($0, beatDuration: beatDuration) }
        guard phases.count >= requiredTapCount else { return nil }

        let angles = phases.map { ($0 / beatDuration) * 2 * Double.pi }
        let sinSum = angles.reduce(0) { $0 + sin($1) }
        let cosSum = angles.reduce(0) { $0 + cos($1) }
        guard sinSum.isFinite, cosSum.isFinite else { return nil }
        guard abs(sinSum) > 0.000_001 || abs(cosSum) > 0.000_001 else { return nil }

        let angle = atan2(sinSum, cosSum)
        let normalizedAngle = angle >= 0 ? angle : angle + 2 * Double.pi
        return (normalizedAngle / (2 * Double.pi)) * beatDuration
    }
}
