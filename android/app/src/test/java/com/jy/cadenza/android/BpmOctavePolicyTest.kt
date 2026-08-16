package com.jy.cadenza.android

import org.junit.Assert.assertEquals
import org.junit.Test

class BpmOctavePolicyTest {
    @Test
    fun promotesHalfTimeDetectionTowardRunningCadence() {
        assertEquals(130f, BpmOctavePolicy.preferred(65f, 180f))
        assertEquals(174f, BpmOctavePolicy.preferred(87f, 180f))
    }

    @Test
    fun leavesUnambiguousAndHighTempoDetectionsAlone() {
        assertEquals(120f, BpmOctavePolicy.preferred(120f, 180f))
        assertEquals(174f, BpmOctavePolicy.preferred(174f, 180f))
    }
}
