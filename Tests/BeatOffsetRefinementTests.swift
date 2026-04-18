import XCTest
@testable import Cadenza

final class BeatOffsetRefinementTests: XCTestCase {
    func testReturnsIntegerPhaseWhenFewerThanThreeScores() {
        XCTAssertEqual(
            BeatOffsetRefinement.refinedPhase(scores: [], bestPhase: 0),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            BeatOffsetRefinement.refinedPhase(scores: [0.5, 0.2], bestPhase: 0),
            0,
            accuracy: 1e-9
        )
    }

    func testSymmetricPeakReturnsExactPhase() {
        let scores = [0.2, 1.0, 0.2]
        XCTAssertEqual(
            BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 1),
            1.0,
            accuracy: 1e-9
        )
    }

    func testPeakSkewedToRightShiftsPositive() {
        let scores = [0.2, 1.0, 0.8]
        let refined = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 1)
        XCTAssertGreaterThan(refined, 1.0)
        XCTAssertLessThan(refined, 1.5)
    }

    func testPeakSkewedToLeftShiftsNegative() {
        let scores = [0.8, 1.0, 0.2]
        let refined = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 1)
        XCTAssertLessThan(refined, 1.0)
        XCTAssertGreaterThan(refined, 0.5)
    }

    func testWrapAroundAtStart() {
        // 경계(인덱스 0)에서 peak — 이전 샘플은 last로 순환
        let scores = [1.0, 0.3, 0.3, 0.6]
        let refined = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 0)
        XCTAssertGreaterThanOrEqual(refined, 0.0)
        XCTAssertLessThan(refined, Double(scores.count))
    }

    func testWrapAroundAtEnd() {
        let scores = [0.6, 0.3, 0.3, 1.0]
        let refined = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 3)
        XCTAssertGreaterThanOrEqual(refined, 0.0)
        XCTAssertLessThan(refined, Double(scores.count))
    }

    func testDeltaClampsToHalfBin() {
        // 평평한 언덕: 양옆이 peak와 같으면 분모 0 → phase 그대로
        let flat = [1.0, 1.0, 1.0]
        XCTAssertEqual(
            BeatOffsetRefinement.refinedPhase(scores: flat, bestPhase: 1),
            1.0,
            accuracy: 1e-9
        )
    }

    func testNonFiniteScoresFallBackToInteger() {
        let bad: [Double] = [.nan, 1.0, 0.5]
        XCTAssertEqual(
            BeatOffsetRefinement.refinedPhase(scores: bad, bestPhase: 1),
            1.0,
            accuracy: 1e-9
        )
    }

    func testSubHopAccuracyExceedsIntegerQuantization() {
        // peak가 인덱스 1과 2 사이(~1.3)에 있는 synthetic 샘플
        let scores = [0.1, 0.9, 1.0, 0.4]
        let refined = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: 2)
        XCTAssertLessThan(refined, 2.0)
        XCTAssertGreaterThan(refined, 1.0)
    }
}
