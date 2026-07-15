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

    /// 분석으로 감지된 BPM은 사용자가 명시적으로 선택한 값이 아니므로 store에 저장하면 안 된다.
    func testDetectedBPMDoesNotPersistAsManualOverride() async throws {
        let store = makeStore()

        let first = AudioManager(bpmOverrideStore: store)
        await first.loadSampleTrack(.clickLoop)
        guard first.hasLoadedTrack else {
            throw XCTSkip("샘플 로드 실패")
        }

        first.setStreamingBeatAlignment(
            bpm: 174,
            source: .analysis,
            beatOffsetSeconds: nil
        )
        XCTAssertEqual(first.originalBPM, 174)
        XCTAssertEqual(first.originalBPMSource, .analysis)

        let second = AudioManager(bpmOverrideStore: store)
        await second.loadSampleTrack(.clickLoop)
        XCTAssertNotEqual(
            second.originalBPMSource, .manual,
            "auto-default가 store에 잘못 저장되어 manual로 복원됨"
        )
    }

    /// 같은 곡에 대한 다음 수동 선택은 이전 override를 갱신해야 한다.
    func testLatestManualBPMChoicePersists() async throws {
        let store = makeStore()
        let audio = AudioManager(bpmOverrideStore: store)
        await audio.loadSampleTrack(.clickLoop)
        guard audio.hasLoadedTrack else { throw XCTSkip("샘플 로드 실패") }

        audio.setOriginalBPM(160)
        XCTAssertEqual(audio.originalBPMSource, .manual)
        audio.setOriginalBPM(80)

        let restored = AudioManager(bpmOverrideStore: store)
        await restored.loadSampleTrack(.clickLoop)

        XCTAssertEqual(restored.originalBPM, 80)
        XCTAssertEqual(restored.originalBPMSource, .manual)
    }
}
