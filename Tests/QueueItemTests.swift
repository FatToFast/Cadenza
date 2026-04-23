import XCTest
@testable import Cadenza

final class QueueItemTests: XCTestCase {
    func testFileSourceURL() {
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        let item = QueueItem(id: "x", title: "s", artist: nil, source: .file(url))
        if case .file(let u) = item.source { XCTAssertEqual(u, url) } else { XCTFail() }
    }

    func testAnalysisCacheIdentityUsesFilePath() {
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        let item = QueueItem(id: "x", title: "s", artist: nil, source: .file(url))
        XCTAssertEqual(item.analysisCacheIdentity, "file-\(url.path)")
    }

    func testAppleMusicSourceIdentityUsesStableTrackID() {
        let track = AppleMusicTrack(
            id: "am-42",
            appleMusicID: "123456789",
            persistentID: 42,
            title: "Song",
            artist: "Artist",
            albumTitle: "Album",
            assetURL: URL(string: "ipod-library://item/item.mp3?id=42"),
            beatsPerMinute: 172,
            isCloudItem: false
        )
        let item = QueueItem(id: "x", title: "s", artist: nil, source: .appleMusic(track))
        XCTAssertEqual(item.analysisCacheIdentity, "am-42")
    }

    func testUnplayableReasonNilByDefault() {
        let item = QueueItem(id: "x", title: "s", artist: nil,
                             source: .file(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertNil(item.unplayableReason)
    }

    func testLocalFilePlaylistBuildsItemsFromFileURLs() {
        let playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/01 First.mp3"),
            URL(fileURLWithPath: "/tmp/02 Second.mp3"),
        ])

        XCTAssertEqual(playlist.count, 2)
        XCTAssertEqual(playlist.currentItem?.title, "01 First")
        XCTAssertEqual(playlist.queueContext?.currentIndex, 0)
        XCTAssertEqual(playlist.queueContext?.totalCount, 2)
        XCTAssertEqual(playlist.queueContext?.nextTitle, "02 Second")
    }

    func testLocalFilePlaylistMovesForwardAndBackwardWithoutWrapping() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])

        XCTAssertFalse(playlist.canMovePrevious)
        XCTAssertTrue(playlist.canMoveNext)
        XCTAssertEqual(playlist.moveToNext()?.title, "b")
        XCTAssertTrue(playlist.canMovePrevious)
        XCTAssertFalse(playlist.canMoveNext)
        XCTAssertNil(playlist.moveToNext())
        XCTAssertEqual(playlist.moveToStart()?.title, "a")
        XCTAssertFalse(playlist.canMovePrevious)
        XCTAssertTrue(playlist.canMoveNext)
        XCTAssertEqual(playlist.moveToNext()?.title, "b")
        XCTAssertEqual(playlist.moveToPrevious()?.title, "a")
    }

    func testLocalFilePlaylistEmptyHasNoCurrentItem() {
        let playlist = LocalFilePlaylist(fileURLs: [])

        XCTAssertTrue(playlist.isEmpty)
        XCTAssertNil(playlist.currentItem)
        XCTAssertNil(playlist.queueContext)
    }

    func testLocalFilePlaylistShuffleKeepsCurrentTrackAndRestoresOriginalOrder() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
            URL(fileURLWithPath: "/tmp/d.mp3"),
        ])
        XCTAssertEqual(playlist.moveToNext()?.title, "b")

        var generator = FixedRandomNumberGenerator(values: [2, 0, 1])
        XCTAssertEqual(playlist.toggleShuffle(using: &generator)?.title, "b")

        XCTAssertTrue(playlist.isShuffled)
        XCTAssertEqual(playlist.currentItem?.title, "b")
        XCTAssertEqual(playlist.queueContext?.currentIndex, 0)
        XCTAssertEqual(playlist.count, 4)
        XCTAssertFalse(Array(playlist.items.dropFirst()).contains { $0.title == "b" })

        XCTAssertEqual(playlist.toggleShuffle(using: &generator)?.title, "b")
        XCTAssertFalse(playlist.isShuffled)
        XCTAssertEqual(playlist.currentItem?.title, "b")
        XCTAssertEqual(playlist.queueContext?.currentIndex, 1)
        XCTAssertEqual(playlist.items.map(\.title), ["a", "b", "c", "d"])
    }
}

private struct FixedRandomNumberGenerator: RandomNumberGenerator {
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    mutating func next() -> UInt64 {
        values.isEmpty ? 0 : values.removeFirst()
    }
}
