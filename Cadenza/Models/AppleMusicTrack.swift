import Foundation

struct PlaylistSummary: Identifiable, Sendable, Equatable {
    let id: UInt64
    let name: String
    let trackCount: Int
}

struct AppleMusicTrack: Identifiable, Sendable, Equatable {
    let id: String
    let appleMusicID: String?
    let persistentID: UInt64
    let title: String
    let artist: String?
    let albumTitle: String?
    let assetURL: URL?
    let beatsPerMinute: Int?
    let isCloudItem: Bool

    var canLoadAudio: Bool {
        assetURL != nil && !isCloudItem
    }

    var unavailableReason: String? {
        if isCloudItem {
            return "기기에 다운로드된 곡만 불러올 수 있습니다"
        }
        if assetURL == nil {
            return "오디오 파일에 접근할 수 없습니다"
        }
        return nil
    }
}
