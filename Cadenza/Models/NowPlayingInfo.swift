import Foundation

struct NowPlayingInfo: Sendable, Equatable {
    let title: String?
    let artist: String?
    let originalBPM: Double
    let originalBPMSource: OriginalBPMSource
    let playbackProgress: Double
    let playbackDuration: TimeInterval
    let queueContext: QueueContext?

    struct QueueContext: Sendable, Equatable {
        let currentIndex: Int
        let totalCount: Int
        let nextTitle: String?
    }

    static let empty = NowPlayingInfo(title: nil, artist: nil,
        originalBPM: BPMRange.originalDefault, originalBPMSource: .assumedDefault,
        playbackProgress: 0, playbackDuration: 0, queueContext: nil)
}
