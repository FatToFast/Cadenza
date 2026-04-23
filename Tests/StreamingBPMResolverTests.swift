import XCTest
@testable import Cadenza

final class StreamingBPMResolverTests: XCTestCase {
    func testUsesGetSongBPMBeforePreviewAnalysis() async {
        let previewCounter = PreviewCallCounter()
        let resolver = StreamingBPMResolver(
            getSongBPM: { title, artist, appleMusicID, isrc in
                XCTAssertEqual(title, "달리기")
                XCTAssertEqual(artist, "S.E.S.")
                XCTAssertEqual(appleMusicID, "12345")
                XCTAssertNil(isrc)
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
            artist: "S.E.S.",
            appleMusicID: "12345"
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
            confidence: nil,
            beatSyncStatus: .bpmOnly
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in
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
            artist: "Artist",
            appleMusicID: nil
        )

        let previewCallCount = await previewCounter.count
        XCTAssertEqual(resolution.result, cached)
        XCTAssertEqual(previewCallCount, 0)
        XCTAssertFalse(resolution.didAttemptGetSongBPM)
    }

    func testFallsBackToPreviewAnalysisWhenGetSongBPMHasNoMatch() async {
        let previewCounter = PreviewCallCounter()
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in nil },
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
            artist: "Nobody",
            appleMusicID: nil
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
            confidence: nil,
            beatSyncStatus: .bpmOnly
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in
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
            artist: "Artist",
            appleMusicID: nil
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
            confidence: nil,
            beatSyncStatus: .bpmOnly
        )
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in nil },
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
            artist: "Artist",
            appleMusicID: nil
        )

        XCTAssertEqual(resolution.result?.bpm ?? 0, 103, accuracy: 0.01)
        XCTAssertEqual(resolution.result?.source, .metadata)
        XCTAssertNil(resolution.result?.beatOffsetSeconds)
        let previewCallCount = await previewCounter.countValue()
        XCTAssertEqual(previewCallCount, 0)
    }

    func testPreviewAnalysisKeepsBeatGridWhenReliable() async {
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in nil },
            previewAnalysis: {
                Self.previewAnalysis(
                    bpm: 120,
                    confidence: 0.72,
                    beatTimesSeconds: [0.12, 0.62, 1.12, 1.62]
                )
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: nil,
            shouldTryGetSongBPM: false,
            shouldTryPreviewAnalysis: true,
            title: "Reliable",
            artist: "Artist",
            appleMusicID: nil
        )

        XCTAssertEqual(resolution.result?.beatSyncStatus, .automaticBeatSync)
        XCTAssertEqual(resolution.result?.beatOffsetSeconds, 0.12)
        XCTAssertEqual(resolution.result?.beatTimesSeconds, [0.12, 0.62, 1.12, 1.62])
    }

    func testPreviewAnalysisDropsBeatGridWhenConfidenceIsLow() async {
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in nil },
            previewAnalysis: {
                Self.previewAnalysis(
                    bpm: 120,
                    confidence: 0.21,
                    beatTimesSeconds: [0.12, 0.62, 1.12, 1.62]
                )
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: nil,
            shouldTryGetSongBPM: false,
            shouldTryPreviewAnalysis: true,
            title: "Low Confidence",
            artist: "Artist",
            appleMusicID: nil
        )

        XCTAssertEqual(resolution.result?.bpm, 120)
        XCTAssertEqual(resolution.result?.beatSyncStatus, .bpmOnly)
        XCTAssertNil(resolution.result?.beatOffsetSeconds)
        XCTAssertNil(resolution.result?.beatTimesSeconds)
    }

    func testPreviewAnalysisDropsBeatGridWhenIntervalsAreUnstable() async {
        let resolver = StreamingBPMResolver(
            getSongBPM: { _, _, _, _ in nil },
            previewAnalysis: {
                Self.previewAnalysis(
                    bpm: 120,
                    confidence: 0.8,
                    beatTimesSeconds: [0.0, 0.5, 1.18, 1.47, 2.1]
                )
            }
        )

        let resolution = await resolver.resolve(
            cachedResult: nil,
            shouldTryGetSongBPM: false,
            shouldTryPreviewAnalysis: true,
            title: "Unstable",
            artist: "Artist",
            appleMusicID: nil
        )

        XCTAssertEqual(resolution.result?.beatSyncStatus, .unstableBeatGrid)
        XCTAssertNil(resolution.result?.beatOffsetSeconds)
        XCTAssertNil(resolution.result?.beatTimesSeconds)
    }

    private static func previewAnalysis(
        bpm: Double,
        confidence: Double = 0.7,
        beatTimesSeconds: [TimeInterval] = [0.12, 0.76, 1.40]
    ) -> BeatAlignmentAnalysis {
        BeatAlignmentAnalysis(
            fingerprint: BeatAlignmentFingerprint(
                fileSize: 1,
                modifiedAt: 0,
                durationSeconds: 30
            ),
            estimatedBPM: bpm,
            beatOffsetSeconds: 0.12,
            confidence: confidence,
            manualNudgeSeconds: 0,
            beatTimesSeconds: beatTimesSeconds
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
