import XCTest
@testable import Cadenza

final class StreamingBPMResolverTests: XCTestCase {
    func testUsesGetSongBPMBeforePreviewAnalysis() async {
        let previewCounter = PreviewCallCounter()
        let resolver = StreamingBPMResolver(
            getSongBPM: { title, artist in
                XCTAssertEqual(title, "달리기")
                XCTAssertEqual(artist, "S.E.S.")
                return GetSongBPMService.Result(
                    bpm: 103,
                    matchedArtist: "S.E.S.",
                    matchedTitle: "달리기"
                )
            },
            previewAnalysis: {
                await previewCounter.increment()
                return Self.previewAnalysis(bpm: 188)
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: nil,
            shouldTryGetSongBPM: true,
            shouldTryPreviewAnalysis: true,
            title: "달리기",
            artist: "S.E.S."
        )

        let previewCallCount = await previewCounter.count
        XCTAssertEqual(resolution.result?.bpm, 103)
        XCTAssertEqual(resolution.result?.source, .metadata)
        XCTAssertEqual(previewCallCount, 0)
        XCTAssertTrue(resolution.didAttemptGetSongBPM)
    }

    func testKeepsCachedResultWhenExternalLookupAlreadyAttempted() async {
        let previewCounter = PreviewCallCounter()
        let cached = StreamingBPMResult(
            bpm: 128,
            source: .metadata,
            beatOffsetSeconds: nil,
            beatTimesSeconds: nil,
            confidence: nil
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _ in
                XCTFail("GetSongBPM should not be called")
                return nil
            },
            previewAnalysis: {
                await previewCounter.increment()
                return Self.previewAnalysis(bpm: 90)
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: cached,
            shouldTryGetSongBPM: false,
            shouldTryPreviewAnalysis: true,
            title: "Cached",
            artist: "Artist"
        )

        let previewCallCount = await previewCounter.count
        XCTAssertEqual(resolution.result, cached)
        XCTAssertEqual(previewCallCount, 0)
        XCTAssertFalse(resolution.didAttemptGetSongBPM)
    }

    func testFallsBackToPreviewAnalysisWhenGetSongBPMHasNoMatch() async {
        let previewCounter = PreviewCallCounter()
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _ in nil },
            previewAnalysis: {
                await previewCounter.increment()
                return Self.previewAnalysis(bpm: 94)
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: nil,
            shouldTryGetSongBPM: true,
            shouldTryPreviewAnalysis: true,
            title: "Unknown",
            artist: "Nobody"
        )

        let previewCallCount = await previewCounter.count
        XCTAssertEqual(resolution.result?.bpm, 94)
        XCTAssertEqual(resolution.result?.source, .analysis)
        XCTAssertEqual(previewCallCount, 1)
        XCTAssertTrue(resolution.didAttemptGetSongBPM)
    }

    func testKeepsExternalBPMWithoutRunningPreviewAnalysis() async {
        let previewCounter = PreviewCallCounter()
        let cached = StreamingBPMResult(
            bpm: 103,
            source: .metadata,
            beatOffsetSeconds: nil,
            beatTimesSeconds: nil,
            confidence: nil
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _ in
                GetSongBPMService.Result(
                    bpm: 103,
                    matchedArtist: "Artist",
                    matchedTitle: "Song"
                )
            },
            previewAnalysis: {
                await previewCounter.increment()
                return Self.previewAnalysis(bpm: 68.67)
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: cached,
            shouldTryGetSongBPM: true,
            shouldTryPreviewAnalysis: true,
            title: "Song",
            artist: "Artist"
        )

        XCTAssertEqual(resolution.result?.bpm ?? 0, 103, accuracy: 0.01)
        XCTAssertEqual(resolution.result?.source, .metadata)
        XCTAssertNil(resolution.result?.beatOffsetSeconds)
        XCTAssertNil(resolution.result?.beatTimesSeconds)
        let previewCallCount = await previewCounter.countValue()
        XCTAssertEqual(previewCallCount, 0)
    }

    func testKeepsCachedBPMWithoutRunningPreviewAnalysis() async {
        let previewCounter = PreviewCallCounter()
        let cached = StreamingBPMResult(
            bpm: 103,
            source: .metadata,
            beatOffsetSeconds: nil,
            beatTimesSeconds: nil,
            confidence: nil
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _ in nil },
            previewAnalysis: {
                await previewCounter.increment()
                return Self.previewAnalysis(bpm: 68.67)
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: cached,
            shouldTryGetSongBPM: false,
            shouldTryPreviewAnalysis: true,
            title: "Song",
            artist: "Artist"
        )

        XCTAssertEqual(resolution.result?.bpm ?? 0, 103, accuracy: 0.01)
        XCTAssertEqual(resolution.result?.source, .metadata)
        XCTAssertNil(resolution.result?.beatOffsetSeconds)
        let previewCallCount = await previewCounter.countValue()
        XCTAssertEqual(previewCallCount, 0)
    }

    private static func previewAnalysis(bpm: Double) -> BeatAlignmentAnalysis {
        BeatAlignmentAnalysis(
            fingerprint: BeatAlignmentFingerprint(
                fileSize: 1,
                modifiedAt: 0,
                durationSeconds: 30
            ),
            estimatedBPM: bpm,
            beatOffsetSeconds: 0.12,
            confidence: 0.7,
            manualNudgeSeconds: 0,
            beatTimesSeconds: [0.12, 0.76, 1.40]
        )
    }
}

private actor PreviewCallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    func countValue() -> Int {
        count
    }
}
