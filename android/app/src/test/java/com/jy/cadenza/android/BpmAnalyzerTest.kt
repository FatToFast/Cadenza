package com.jy.cadenza.android

import org.junit.Assert.assertEquals
import org.junit.Test

class BpmAnalyzerTest {
    @Test
    fun resolvesLikelyDoubleTimeToHalfTime() {
        val result = BpmAnalyzer.resolveOctave(
            listOf(
                BpmCandidate(94.0, 0.42),
                BpmCandidate(95.0, 0.48),
                BpmCandidate(188.0, 1.0),
            ),
        )

        assertEquals(95.0, result!!, 0.001)
    }

    @Test
    fun keepsHighTempoWhenHalfTimeEvidenceIsWeak() {
        val result = BpmAnalyzer.resolveOctave(
            listOf(
                BpmCandidate(94.0, 0.20),
                BpmCandidate(188.0, 1.0),
            ),
        )

        assertEquals(188.0, result!!, 0.001)
    }
}
