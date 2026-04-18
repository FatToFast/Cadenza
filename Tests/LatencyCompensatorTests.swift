import XCTest
@testable import Cadenza

final class LatencyCompensatorTests: XCTestCase {
    func testZeroLatenciesYieldZeroCompensation() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: 0,
                timePitchPresentation: 0,
                mixerPresentation: 0
            ),
            0,
            accuracy: 1e-9
        )
    }

    func testAULatencyOnlyIsPassedThrough() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: 0.030,
                timePitchPresentation: 0,
                mixerPresentation: 0
            ),
            0.030,
            accuracy: 1e-9
        )
    }

    func testPositivePresentationDeltaIsAdded() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: 0,
                timePitchPresentation: 0.005,
                mixerPresentation: 0
            ),
            0.005,
            accuracy: 1e-9
        )
    }

    func testNegativePresentationDeltaClampsToZero() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: 0.020,
                timePitchPresentation: 0.001,
                mixerPresentation: 0.010
            ),
            0.020,
            accuracy: 1e-9
        )
    }

    func testOverLimitIsClampedToMax() {
        let clamped = LatencyCompensator.metronomeDelaySeconds(
            timePitchAULatency: 1.0,
            timePitchPresentation: 0,
            mixerPresentation: 0
        )
        XCTAssertEqual(clamped, LatencyCompensator.maxCompensationSeconds, accuracy: 1e-9)
    }

    func testNonFiniteInputsYieldZero() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: .nan,
                timePitchPresentation: 0,
                mixerPresentation: 0
            ),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: .infinity,
                timePitchPresentation: 0,
                mixerPresentation: 0
            ),
            0,
            accuracy: 1e-9
        )
    }

    func testTypicalIOSNumbers() {
        let result = LatencyCompensator.metronomeDelaySeconds(
            timePitchAULatency: 0.025,
            timePitchPresentation: 0.003,
            mixerPresentation: 0.001
        )
        XCTAssertEqual(result, 0.027, accuracy: 1e-9)
    }

    func testNegativeAULatencyClampsToZero() {
        XCTAssertEqual(
            LatencyCompensator.metronomeDelaySeconds(
                timePitchAULatency: -0.01,
                timePitchPresentation: 0,
                mixerPresentation: 0
            ),
            0,
            accuracy: 1e-9
        )
    }
}
