import Foundation
import MediaPlayer

enum MusicLibraryError: LocalizedError, Equatable {
    case accessDenied
    case playlistNotFound
    case fixtureAssetMissing

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Apple Music 보관함 접근 권한이 필요합니다"
        case .playlistNotFound:
            return "플레이리스트를 찾을 수 없습니다"
        case .fixtureAssetMissing:
            return "시뮬레이터 테스트용 샘플 오디오를 찾을 수 없습니다"
        }
    }
}

@MainActor
protocol MusicLibrary {
    func authorizationStatus() -> MPMediaLibraryAuthorizationStatus
    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus
    func fetchPlaylists() async throws -> [PlaylistSummary]
    func fetchTracks(in playlistID: UInt64) async throws -> [AppleMusicTrack]
}

@MainActor
struct MusicLibraryService: MusicLibrary {
    func authorizationStatus() -> MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchPlaylists() async throws -> [PlaylistSummary] {
        guard authorizationStatus() == .authorized else {
            throw MusicLibraryError.accessDenied
        }

        let query = MPMediaQuery.playlists()
        let playlists = query.collections?.compactMap { $0 as? MPMediaPlaylist } ?? []
        let summaries = playlists
            .map { playlist in
                PlaylistSummary(
                    id: playlist.persistentID,
                    name: playlist.name ?? "Untitled Playlist",
                    trackCount: playlist.items.count
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        #if targetEnvironment(simulator)
        if summaries.isEmpty || summaries.allSatisfy({ $0.trackCount == 0 }) {
            return Self.simulatorFixturePlaylists
        }
        #endif

        return summaries
    }

    func fetchTracks(in playlistID: UInt64) async throws -> [AppleMusicTrack] {
        guard authorizationStatus() == .authorized else {
            throw MusicLibraryError.accessDenied
        }

        #if targetEnvironment(simulator)
        if Self.simulatorFixturePlaylists.contains(where: { $0.id == playlistID }) {
            return try Self.simulatorFixtureTracks(for: playlistID)
        }
        #endif

        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: playlistID),
            forProperty: MPMediaPlaylistPropertyPersistentID
        ))

        guard let playlist = query.collections?.compactMap({ $0 as? MPMediaPlaylist }).first else {
            throw MusicLibraryError.playlistNotFound
        }

        return playlist.items.map(Self.makeTrack(from:))
    }

    private static func makeTrack(from item: MPMediaItem) -> AppleMusicTrack {
        let bpmNumber = item.value(forProperty: MPMediaItemPropertyBeatsPerMinute) as? NSNumber
        let bpm = bpmNumber?.intValue
        let title = item.title?.isEmpty == false ? item.title! : "Untitled Track"

        return AppleMusicTrack(
            id: "am-\(item.persistentID)",
            appleMusicID: item.playbackStoreID.isEmpty ? nil : item.playbackStoreID,
            persistentID: item.persistentID,
            title: title,
            artist: item.artist,
            albumTitle: item.albumTitle,
            assetURL: item.assetURL,
            beatsPerMinute: bpm.flatMap { $0 > 0 ? $0 : nil },
            isCloudItem: item.isCloudItem
        )
    }

    #if targetEnvironment(simulator)
    private static let simulatorFixturePlaylists: [PlaylistSummary] = [
        PlaylistSummary(id: UInt64.max - 1, name: "Simulator Apple Music", trackCount: 1),
    ]

    private static func simulatorFixtureTracks(for playlistID: UInt64) throws -> [AppleMusicTrack] {
        guard simulatorFixturePlaylists.contains(where: { $0.id == playlistID }) else {
            throw MusicLibraryError.playlistNotFound
        }
        guard let sampleURL = Bundle.main.url(forResource: "Kickdrum Rocket-2", withExtension: "mp3") else {
            throw MusicLibraryError.fixtureAssetMissing
        }
        return [
            AppleMusicTrack(
                id: "simulator-kickdrum-rocket",
                appleMusicID: nil,
                persistentID: UInt64.max - 100,
                title: "Kickdrum Rocket",
                artist: "Simulator Fixture",
                albumTitle: "Cadenza Samples",
                assetURL: sampleURL,
                beatsPerMinute: 180,
                isCloudItem: false
            ),
        ]
    }
    #endif
}
