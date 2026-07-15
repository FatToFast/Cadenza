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

    func testMarkCurrentTempoUnplayableUpdatesShuffledAndOriginalCopies() throws {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])
        _ = playlist.moveToNext()
        var generator = FixedRandomNumberGenerator(values: [1, 0])
        _ = playlist.toggleShuffle(using: &generator)

        playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.8))

        let currentID = try XCTUnwrap(playlist.currentItem?.id)
        XCTAssertEqual(
            playlist.items.first(where: { $0.id == currentID })?.unplayableReason,
            .rateOutOfRange(required: 1.8)
        )
        XCTAssertEqual(
            playlist.originalItems.first(where: { $0.id == currentID })?.unplayableReason,
            .rateOutOfRange(required: 1.8)
        )

        _ = playlist.toggleShuffle(using: &generator)
        XCTAssertEqual(
            playlist.items.first(where: { $0.id == currentID })?.unplayableReason,
            .rateOutOfRange(required: 1.8)
        )
    }

    func testPlaylistSkipsItemsMarkedTempoUnplayableWithoutWrapping() {
        var playlist = LocalFilePlaylist(fileURLs: [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])

        playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.8))
        XCTAssertEqual(playlist.moveToNextPlayable()?.title, "b")
        playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.7))
        XCTAssertEqual(playlist.moveToNextPlayable()?.title, "c")
        playlist.markCurrentUnplayable(.rateOutOfRange(required: 1.6))
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
                unplayableReason: .rateOutOfRange(required: 1.5)
            ),
            QueueItem(
                id: "c", title: "c", artist: nil, source: .file(urlC),
                unplayableReason: .decodingFailed
            ),
        ])

        XCTAssertNil(playlist.moveToNextPlayable())
        XCTAssertEqual(playlist.currentItem?.title, "a")
    }

    func testClearingTempoRejectionsPreservesUnrelatedFailures() {
        let urlA = URL(fileURLWithPath: "/tmp/a.mp3")
        let urlB = URL(fileURLWithPath: "/tmp/b.mp3")
        var playlist = LocalFilePlaylist(items: [
            QueueItem(
                id: "a", title: "a", artist: nil, source: .file(urlA),
                unplayableReason: .rateOutOfRange(required: 1.8)
            ),
            QueueItem(
                id: "b", title: "b", artist: nil, source: .file(urlB),
                unplayableReason: .decodingFailed
            ),
        ])

        playlist.clearTempoUnplayableReasons()

        XCTAssertNil(playlist.items[0].unplayableReason)
        XCTAssertEqual(playlist.items[1].unplayableReason, .decodingFailed)
    }

    func testTempoSkipGuardRejectsDuplicateIdentityUntilReset() {
        var guardState = TempoSkipGuard()

        XCTAssertTrue(guardState.register(identity: "song-a"))
        XCTAssertFalse(guardState.register(identity: "song-a"))
        XCTAssertTrue(guardState.register(identity: "song-b"))

        guardState.reset()

        XCTAssertTrue(guardState.register(identity: "song-a"))
    }

    func testTempoSkipGuardRejectsMissingOrBlankIdentity() {
        var guardState = TempoSkipGuard()

        XCTAssertFalse(guardState.register(identity: nil))
        XCTAssertFalse(guardState.register(identity: ""))
        XCTAssertFalse(guardState.register(identity: "   \n"))
    }

    func testStreamingTempoSkipCoordinatorTerminatesInvalidAndDuplicateIdentities() throws {
        var coordinator = StreamingTempoSkipCoordinator()

        XCTAssertEqual(coordinator.transitionForRejected(identity: nil), .exhausted)
        XCTAssertEqual(coordinator.transitionForRejected(identity: "  \n"), .exhausted)

        let first = coordinator.transitionForRejected(identity: " song-a ")
        guard case .skip(let token) = first else {
            return XCTFail("Expected first valid identity to request a skip")
        }
        XCTAssertEqual(token.identity, "song-a")
        coordinator.clearInFlight(ifMatching: token.identity)

        XCTAssertEqual(coordinator.transitionForRejected(identity: "song-a"), .exhausted)
    }

    func testStreamingTempoSkipCoordinatorBlocksStaleGenerationAndIdentity() throws {
        var coordinator = StreamingTempoSkipCoordinator()
        let transition = coordinator.transitionForRejected(identity: "song-a")
        guard case .skip(let token) = transition else {
            return XCTFail("Expected a skip token")
        }

        XCTAssertTrue(coordinator.permitsSkip(token: token, currentIdentity: "song-a"))
        XCTAssertFalse(coordinator.permitsSkip(token: token, currentIdentity: "song-b"))

        coordinator.reset()

        XCTAssertFalse(coordinator.permitsSkip(token: token, currentIdentity: "song-a"))
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

    func testStreamingQueueStartVerifierRequiresExactQueueEntry() {
        XCTAssertTrue(
            StreamingQueueStartVerifier.matches(
                expectedQueueEntryID: "queue-4",
                actualQueueEntryID: "queue-4"
            )
        )
        XCTAssertFalse(
            StreamingQueueStartVerifier.matches(
                expectedQueueEntryID: "queue-4",
                actualQueueEntryID: "queue-8"
            )
        )
        XCTAssertFalse(
            StreamingQueueStartVerifier.matches(
                expectedQueueEntryID: "queue-4",
                actualQueueEntryID: nil
            )
        )
    }

    func testExplicitStreamingSelectionDoesNotAutoSkipRejectedTrack() {
        XCTAssertFalse(
            StreamingTempoPolicyGate.shouldAutoSkipRejectedPlaylistEntry(
                origin: .explicitSelection
            )
        )
    }

    func testQueueAdvanceStillAutoSkipsRejectedTrack() {
        XCTAssertTrue(
            StreamingTempoPolicyGate.shouldAutoSkipRejectedPlaylistEntry(
                origin: .queueAdvance
            )
        )
    }

    func testStreamingEntryOriginStaysExplicitForRequestedIndex() {
        XCTAssertEqual(
            StreamingEntryOrigin.resolved(
                requestedIndex: 6,
                previousIndex: 6,
                observedIndex: 6
            ),
            .explicitSelection
        )
    }

    func testStreamingEntryOriginBecomesQueueAdvanceWhenObservedIndexChanges() {
        XCTAssertEqual(
            StreamingEntryOrigin.resolved(
                requestedIndex: nil,
                previousIndex: 6,
                observedIndex: 7
            ),
            .queueAdvance
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
