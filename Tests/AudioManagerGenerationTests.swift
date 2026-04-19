import XCTest
import Combine
@testable import Cadenza

@MainActor
final class AudioManagerGenerationTests: XCTestCase {
    func testDefaultBehaviorIsLoop() {
        XCTAssertEqual(AudioManager().playbackEndBehavior, .loop)
    }
    func testBehaviorMutable() {
        let a = AudioManager()
        a.playbackEndBehavior = .notify
        XCTAssertEqual(a.playbackEndBehavior, .notify)
    }
    func testTrackEndedSubjectEmits() {
        let a = AudioManager()
        var n = 0
        let c = a.trackEndedSubject.sink { n += 1 }
        a.trackEndedSubject.send(())
        XCTAssertEqual(n, 1)
        c.cancel()
    }
}
