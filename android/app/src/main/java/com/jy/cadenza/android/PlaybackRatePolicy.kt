package com.jy.cadenza.android

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

data class PlaybackTempoPlan(
    val rate: Float,
    val effectiveCadence: Float,
)

object PlaybackRatePolicy {
    const val MIN_RATE = 1.0f
    const val MAX_RATE = 2.5f
    private const val CADENCE_DRIFT_TOLERANCE = 10f
    private const val DRIFT_RATE_THRESHOLD = 1.25f

    fun rate(originalBpm: Float, targetBpm: Float): Float {
        return plan(originalBpm, targetBpm).rate
    }

    fun plan(originalBpm: Float, targetBpm: Float): PlaybackTempoPlan {
        if (!originalBpm.isFinite() || !targetBpm.isFinite() || originalBpm <= 0f) {
            return PlaybackTempoPlan(MIN_RATE, targetBpm)
        }
        val foldedTarget = listOf(0.25f, 0.5f, 1f, 2f, 4f)
            .asSequence()
            .map { multiplier -> targetBpm * multiplier }
            .map { candidate -> candidate to candidate / originalBpm }
            .filter { (_, candidateRate) -> candidateRate.isFinite() && candidateRate >= MIN_RATE }
            .minByOrNull { (_, candidateRate) -> candidateRate }
            ?.first
            ?: targetBpm
        val baseRate = min(max(foldedTarget / originalBpm, MIN_RATE), MAX_RATE)
        if (baseRate <= DRIFT_RATE_THRESHOLD) {
            return PlaybackTempoPlan(baseRate, targetBpm)
        }

        val driftCadence = (0..2)
            .map { octave -> originalBpm * 2f.pow(octave) }
            .filter { candidate -> kotlin.math.abs(candidate - targetBpm) <= CADENCE_DRIFT_TOLERANCE }
            .minByOrNull { candidate -> kotlin.math.abs(candidate - targetBpm) }
        return if (driftCadence != null) {
            PlaybackTempoPlan(MIN_RATE, driftCadence)
        } else {
            PlaybackTempoPlan(baseRate, targetBpm)
        }
    }
}
