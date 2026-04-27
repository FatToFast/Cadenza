import XCTest
@testable import Cadenza

@MainActor
final class AudioManagerOverrideIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "test.cadenza.audio-override-integration"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore() -> TrackBPMOverrideStore {
        TrackBPMOverrideStore(
            defaults: defaults,
            storageKey: "override.integration",
            maxEntries: 100
        )
    }

    /// 사용자가 곡에 BPM을 직접 입력하면 (`setOriginalBPM`), 같은 곡 식별자로
    /// override store에 영구 저장되어야 한다. 이 테스트는 store가 wire되어 있는지를
    /// 검증한다 — 같은 store를 공유하는 두 번째 AudioManager 인스턴스가 영향을 받는다.
    func testManualBPMPersistsToOverrideStore() async throws {
        let store = makeStore()

        // 첫 번째 인스턴스가 샘플을 로드하고 사용자가 174 입력
        let first = AudioManager(bpmOverrideStore: store)
        await first.loadSampleTrack(.clickLoop)
        XCTAssertTrue(first.hasLoadedTrack, "샘플 로드 실패 — 번들에서 파일을 찾지 못했을 수 있습니다")

        first.setOriginalBPM(174)
        XCTAssertEqual(first.originalBPM, 174)
        XCTAssertEqual(first.originalBPMSource, .manual)

        // 두 번째 인스턴스가 같은 샘플을 로드하면 사용자 값이 다시 적용되어야 한다
        let second = AudioManager(bpmOverrideStore: store)
        await second.loadSampleTrack(.clickLoop)
        XCTAssertTrue(second.hasLoadedTrack)
        XCTAssertEqual(second.originalBPM, 174, "override가 다음 인스턴스에 적용되지 않음")
        XCTAssertEqual(second.originalBPMSource, .manual)
    }

    /// applyAutoBPMDefault는 사용자가 명시적으로 선택한 게 아니므로 store에 저장하면 안 된다.
    /// 두 번째 인스턴스 로드 시에는 override가 없어야 한다.
    func testAutoBPMDefaultDoesNotPersist() async throws {
        let store = makeStore()

        let first = AudioManager(bpmOverrideStore: store)
        await first.loadSampleTrack(.clickLoop)
        guard first.hasLoadedTrack else {
            throw XCTSkip("샘플 로드 실패")
        }

        // BPM이 metadata로 로드되었다고 가정하고, ambiguous한 후보 중 자동 디폴트만 적용
        first.applyAutoBPMDefault(174)

        // store는 비어있어야 함
        let second = AudioManager(bpmOverrideStore: store)
        await second.loadSampleTrack(.clickLoop)
        XCTAssertNotEqual(
            second.originalBPMSource, .manual,
            "auto-default가 store에 잘못 저장되어 manual로 복원됨"
        )
    }

    /// applyAutoBPMDefault는 source가 manual이면 무시되어야 한다 — 사용자 의도 보호.
    func testAutoBPMDefaultIgnoredWhenManual() async throws {
        let store = makeStore()
        let audio = AudioManager(bpmOverrideStore: store)
        await audio.loadSampleTrack(.clickLoop)
        guard audio.hasLoadedTrack else { throw XCTSkip("샘플 로드 실패") }

        audio.setOriginalBPM(160)
        XCTAssertEqual(audio.originalBPMSource, .manual)

        audio.applyAutoBPMDefault(80)

        XCTAssertEqual(audio.originalBPM, 160, "manual BPM이 auto-default에 의해 덮어쓰임")
        XCTAssertEqual(audio.originalBPMSource, .manual)
    }
}
