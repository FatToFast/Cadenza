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
}
