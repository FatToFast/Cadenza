import XCTest
@testable import Cadenza

final class NowPlayingInfoTests: XCTestCase {
    func testConstructs() {
        let info = NowPlayingInfo(title: "S", artist: "A", originalBPM: 128,
            originalBPMSource: .metadata, playbackProgress: 0.5,
            playbackDuration: 180, queueContext: nil)
        XCTAssertEqual(info.title, "S")
        XCTAssertEqual(info.originalBPM, 128)
    }
    func testEmpty() {
        XCTAssertNil(NowPlayingInfo.empty.title)
        XCTAssertEqual(NowPlayingInfo.empty.originalBPM, BPMRange.originalDefault)
    }
    func testQueueContext() {
        let ctx = NowPlayingInfo.QueueContext(currentIndex: 2, totalCount: 5, nextTitle: "N")
        XCTAssertEqual(ctx.currentIndex, 2)
    }

    func testActivityStateKeepsCadenceSeparateFromOriginalBPM() {
        let state = CadenzaActivityState(
            title: "Song",
            artist: nil,
            effectiveCadence: 190,
            baseCadence: 180,
            originalBPM: 95,
            elapsed: 0,
            duration: 180,
            isPlaying: true,
            artworkData: nil
        )

        XCTAssertEqual(state.effectiveCadence, 190)
        XCTAssertEqual(state.baseCadence, 180)
        XCTAssertEqual(state.originalBPM, 95)
    }
}
