import Foundation

enum LatencyCompensator {
    static let maxCompensationSeconds: TimeInterval = 0.15

    /// timePitch 경로와 mixer-공유 경로 간 presentation latency delta.
    /// `mainMixer` 이후(shared tail)는 양 경로에서 상쇄되므로 제외한다.
    static func metronomeDelaySeconds(
        timePitchAULatency: TimeInterval,
        timePitchPresentation: TimeInterval,
        mixerPresentation: TimeInterval
    ) -> TimeInterval {
        let core = sanitize(timePitchAULatency)
        let presentationDelta = max(
            0,
            sanitize(timePitchPresentation) - sanitize(mixerPresentation)
        )
        let total = core + presentationDelta
        guard total.isFinite else { return 0 }
        return min(max(total, 0), maxCompensationSeconds)
    }

    private static func sanitize(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? value : 0
    }
}
