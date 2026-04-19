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

    func testUnplayableReasonNilByDefault() {
        let item = QueueItem(id: "x", title: "s", artist: nil,
                             source: .file(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertNil(item.unplayableReason)
    }
}
