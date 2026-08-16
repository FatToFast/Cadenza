package com.jy.cadenza.android

import kotlin.math.abs

object BpmOctavePolicy {
    fun preferred(rawBpm: Float, targetCadence: Float): Float {
        if (!rawBpm.isFinite() || rawBpm <= 0f) return rawBpm

        val pair = when {
            rawBpm >= 140f -> rawBpm / 2f to rawBpm
            rawBpm <= 100f -> rawBpm to rawBpm * 2f
            else -> return rawBpm
        }
        if (pair.first < 60f || pair.second > 220f || pair.second <= pair.first) return rawBpm
        if (!targetCadence.isFinite() || targetCadence <= 0f) return pair.second

        val lowerDistance = abs(pair.first - targetCadence)
        val upperDistance = abs(pair.second - targetCadence)
        return if (lowerDistance + 0.5f < upperDistance) pair.first else pair.second
    }
}
