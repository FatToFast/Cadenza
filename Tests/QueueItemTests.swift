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

    func testJumpToValidIndexUpdatesCurrent() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])
        XCTAssertEqual(playlist.currentIndex, 0)

        let item = playlist.jumpTo(index: 2)

        XCTAssertEqual(item?.title, "c")
        XCTAssertEqual(playlist.currentIndex, 2)
    }

    func testJumpToOutOfBoundsLeavesCurrentUntouched() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])
        _ = playlist.moveToNext() // currentIndex = 1
        XCTAssertEqual(playlist.currentIndex, 1)

        XCTAssertNil(playlist.jumpTo(index: 5))
        XCTAssertNil(playlist.jumpTo(index: -1))
        XCTAssertEqual(playlist.currentIndex, 1)
    }

    func testMarkCurrentUnplayableUpdatesShuffledAndOriginalCopies() throws {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])
        _ = playlist.moveToNext()
        var generator = FixedRandomNumberGenerator(values: [1, 0])
        _ = playlist.toggleShuffle(using: &generator)

        playlist.markCurrentUnplayable(.decodingFailed)

        let currentID = try XCTUnwrap(playlist.currentItem?.id)
        XCTAssertEqual(
            playlist.items.first(where: { $0.id == currentID })?.unplayableReason,
            .decodingFailed
        )
        XCTAssertEqual(
            playlist.originalItems.first(where: { $0.id == currentID })?.unplayableReason,
            .decodingFailed
        )

        _ = playlist.toggleShuffle(using: &generator)
        XCTAssertEqual(
            playlist.items.first(where: { $0.id == currentID })?.unplayableReason,
            .decodingFailed
        )
    }

    func testPlaylistSkipsItemsMarkedUnplayableWithoutWrapping() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])

        playlist.markCurrentUnplayable(.decodingFailed)
        XCTAssertEqual(playlist.moveToNextPlayable()?.title, "b")
        playlist.markCurrentUnplayable(.cloudOnly)
        XCTAssertEqual(playlist.moveToNextPlayable()?.title, "c")
        playlist.markCurrentUnplayable(.subscriptionLapsed)
        XCTAssertNil(playlist.moveToNextPlayable())
        XCTAssertEqual(playlist.currentItem?.title, "c")
    }

    func testMoveToNextPlayableSkipsAlreadyRejectedItemsAndReturnsNilWhenNoneRemain() {
        let urlA = URL(fileURLWithPath: "/tmp/a.mp3")
        let urlB = URL(fileURLWithPath: "/tmp/b.mp3")
        let urlC = URL(fileURLWithPath: "/tmp/c.mp3")
        var playlist = LocalFilePlaylist(items: [
            QueueItem(id: "a", title: "a", artist: nil, source: .file(urlA)),
            QueueItem(
                id: "b", title: "b", artist: nil, source: .file(urlB),
                unplayableReason: .cloudOnly
            ),
            QueueItem(
                id: "c", title: "c", artist: nil, source: .file(urlC),
                unplayableReason: .decodingFailed
            ),
        ])

        XCTAssertNil(playlist.moveToNextPlayable())
        XCTAssertEqual(playlist.currentItem?.title, "a")
    }

    func testQueueIdentityNormalizerTrimsAndRejectsBlankIdentity() {
        XCTAssertEqual(QueueIdentityNormalizer.normalized(" song-a "), "song-a")
        XCTAssertNil(QueueIdentityNormalizer.normalized(nil))
        XCTAssertNil(QueueIdentityNormalizer.normalized(""))
        XCTAssertNil(QueueIdentityNormalizer.normalized("   \n"))
    }

    func testStreamingTempoPolicyGateDefersWhileInitialSelectionIsLoading() {
        XCTAssertFalse(
            StreamingTempoPolicyGate.shouldEvaluate(hasSong: true, isLoading: true)
        )
        XCTAssertTrue(
            StreamingTempoPolicyGate.shouldEvaluate(hasSong: true, isLoading: false)
        )
        XCTAssertFalse(
            StreamingTempoPolicyGate.shouldEvaluate(hasSong: false, isLoading: false)
        )
    }

    func testStreamingPlaylistSelectionPlanPreservesRequestedTailIndexes() {
        let ids = (0..<10).map { "entry-\($0)" }

        XCTAssertEqual(
            StreamingPlaylistSelectionPlan.make(
                entryIDs: ids,
                selectedEntryID: "entry-5"
            )?.selectedIndex,
            5
        )
        XCTAssertEqual(
            StreamingPlaylistSelectionPlan.make(
                entryIDs: ids,
                selectedEntryID: "entry-6"
            )?.selectedIndex,
            6
        )
        XCTAssertEqual(
            StreamingPlaylistSelectionPlan.make(
                entryIDs: ids,
                selectedEntryID: "entry-7"
            )?.selectedIndex,
            7
        )
    }

    func testStreamingPlaylistSelectionPlanRejectsMissingEntry() {
        XCTAssertNil(
            StreamingPlaylistSelectionPlan.make(
                entryIDs: ["entry-a", "entry-b"],
                selectedEntryID: "entry-c"
            )
        )
    }

    func testStreamingQueueStartVerifierRequiresExactPreparedQueueIndex() {
        XCTAssertTrue(
            StreamingQueueStartVerifier.matches(
                expectedIndex: 4,
                actualIndex: 4
            )
        )
        XCTAssertFalse(
            StreamingQueueStartVerifier.matches(
                expectedIndex: 4,
                actualIndex: 8
            )
        )
        XCTAssertFalse(
            StreamingQueueStartVerifier.matches(
                expectedIndex: 4,
                actualIndex: nil
            )
        )
    }

    func testStreamingPlaylistQueueRequiresDetailedPlaylistContext() {
        XCTAssertTrue(
            StreamingPlaylistQueuePolicy.canStart(
                hasDetailedPlaylistContext: true
            )
        )
        XCTAssertFalse(
            StreamingPlaylistQueuePolicy.canStart(
                hasDetailedPlaylistContext: false
            )
        )
    }

    func testStreamingQueueCommandSnapshotRejectsSelectionGenerationChange() {
        let snapshot = StreamingQueueCommandSnapshot(
            selectionGeneration: 7,
            expectedIdentity: " song-a "
        )

        XCTAssertTrue(
            snapshot.isCurrent(selectionGeneration: 7, currentIdentity: "song-a")
        )
        XCTAssertFalse(
            snapshot.isCurrent(selectionGeneration: 8, currentIdentity: "song-b")
        )
        XCTAssertFalse(
            snapshot.isCurrent(selectionGeneration: 7, currentIdentity: "song-b")
        )
    }

    func testStreamingPlayCompletionStopsStalePlaybackWithoutCommittingState() {
        var stopCount = 0
        var commitCount = 0

        let didCommit = StreamingPlayCompletionGuard.commitIfCurrent(
            startedGeneration: 4,
            currentGeneration: 5,
            stopStalePlayback: { stopCount += 1 },
            commitCurrentPlayback: { commitCount += 1 }
        )

        XCTAssertFalse(didCommit)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(commitCount, 0)
    }

    func testStreamingPlayCompletionCommitsCurrentPlaybackWithoutStopping() {
        var stopCount = 0
        var commitCount = 0

        let didCommit = StreamingPlayCompletionGuard.commitIfCurrent(
            startedGeneration: 5,
            currentGeneration: 5,
            stopStalePlayback: { stopCount += 1 },
            commitCurrentPlayback: { commitCount += 1 }
        )

        XCTAssertTrue(didCommit)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(commitCount, 1)
    }

    func testStreamingPlaylistErrorRecoveryShowsCurrentPlaylist() {
        XCTAssertEqual(
            PlayerErrorRecoveryPolicy.action(
                hasStreamingSong: true,
                hasCurrentStreamingPlaylist: true
            ),
            .showCurrentStreamingPlaylist
        )
    }

    func testFailedStreamingPlaylistSelectionStillShowsCurrentPlaylist() {
        XCTAssertEqual(
            PlayerErrorRecoveryPolicy.action(
                hasStreamingSong: false,
                hasCurrentStreamingPlaylist: true
            ),
            .showCurrentStreamingPlaylist
        )
    }

    func testStreamingSongErrorRecoveryDismissesInsteadOfChoosingFile() {
        XCTAssertEqual(
            PlayerErrorRecoveryPolicy.action(
                hasStreamingSong: true,
                hasCurrentStreamingPlaylist: false
            ),
            .dismiss
        )
    }

    func testLocalErrorRecoveryStillOffersAnotherFile() {
        XCTAssertEqual(
            PlayerErrorRecoveryPolicy.action(
                hasStreamingSong: false,
                hasCurrentStreamingPlaylist: false
            ),
            .chooseLocalFile
        )
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
