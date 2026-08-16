package com.jy.cadenza.android

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackRatePolicyTest {
    @Test fun neverSlowsDown() {
        assertEquals(1.6666666f, PlaybackRatePolicy.rate(originalBpm = 180f, targetBpm = 150f), 0.0001f)
    }

    @Test fun acceleratesToCadence() {
        assertEquals(1.5f, PlaybackRatePolicy.rate(originalBpm = 120f, targetBpm = 180f))
    }

    @Test fun clampsInvalidAndExtremeValues() {
        assertEquals(1f, PlaybackRatePolicy.rate(Float.NaN, 180f))
        assertEquals(1.8333334f, PlaybackRatePolicy.rate(60f, 220f), 0.0001f)
    }

    @Test fun driftsCadenceInsteadOfNearlyDoublingNinetyFiveBpmTrack() {
        val plan = PlaybackRatePolicy.plan(originalBpm = 95f, targetBpm = 180f)

        assertEquals(1f, plan.rate)
        assertEquals(190f, plan.effectiveCadence)
    }

    @Test fun keepsRequestedCadenceWhenFoldedRateIsReasonable() {
        val plan = PlaybackRatePolicy.plan(originalBpm = 87f, targetBpm = 180f)

        assertEquals(180f / 174f, plan.rate, 0.0001f)
        assertEquals(180f, plan.effectiveCadence)
    }
}
