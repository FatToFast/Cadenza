import XCTest
import MediaPlayer
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

    func testArtworkRequestHandlerCanRunOffMainQueue() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let artwork = try XCTUnwrap(NowPlayingCenterCoordinator.makeArtwork(from: png))
        let artworkBox = UncheckedSendableBox(artwork)
        let expectation = expectation(description: "artwork rendered off main queue")

        DispatchQueue(label: "test.cadenza.artwork.accessQueue").async {
            XCTAssertNotNil(artworkBox.value.image(at: CGSize(width: 32, height: 32)))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
