package com.jy.cadenza.android

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

internal data class BpmCandidate(val bpm: Double, val score: Double)

object BpmAnalyzer {
    private const val MAX_ANALYSIS_SECONDS = 20
    private const val FRAME_SIZE = 2_048
    private const val HOP_SIZE = 512

    suspend fun analyze(context: Context, uri: Uri): Float? = withContext(Dispatchers.Default) {
        val decoded = decodeMono(context, uri) ?: return@withContext null
        val onsetEnvelope = makeOnsetEnvelope(decoded.samples)
        val prepared = prepareOnsetEnvelope(onsetEnvelope)
        estimateBpm(prepared, HOP_SIZE.toDouble() / decoded.sampleRate)
            ?.takeIf { it in 60.0..220.0 }
            ?.toFloat()
    }

    private data class DecodedAudio(val samples: FloatArray, val sampleRate: Int)

    private suspend fun decodeMono(context: Context, uri: Uri): DecodedAudio? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var codecStarted = false
        try {
            if (uri.scheme == "file") {
                extractor.setDataSource(requireNotNull(uri.path))
            } else {
                extractor.setDataSource(context, uri, null)
            }
            val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(trackIndex)

            val inputFormat = extractor.getTrackFormat(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: return null
            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            val maxSamples = sampleRate * MAX_ANALYSIS_SECONDS
            val monoSamples = FloatArray(maxSamples)
            var sampleCount = 0

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()
            codecStarted = true

            val info = MediaCodec.BufferInfo()
            var inputEnded = false
            var outputEnded = false
            while (!outputEnded && sampleCount < maxSamples) {
                currentCoroutineContext().ensureActive()
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputIndex) ?: continue
                        inputBuffer.clear()
                        val size = extractor.readSampleData(inputBuffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        } else {
                            codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = codec.outputFormat
                        sampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channelCount = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        pcmEncoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                    }

                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit

                    else -> if (outputIndex >= 0) {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && info.size > 0) {
                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)
                            val pcm = outputBuffer.slice().order(ByteOrder.LITTLE_ENDIAN)
                            val bytesPerSample = if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                            val frameBytes = bytesPerSample * channelCount
                            while (pcm.remaining() >= frameBytes && sampleCount < maxSamples) {
                                var mixed = 0f
                                repeat(channelCount) {
                                    mixed += if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                                        pcm.float
                                    } else {
                                        pcm.short.toFloat() / Short.MAX_VALUE
                                    }
                                }
                                monoSamples[sampleCount++] = mixed / channelCount
                            }
                        }
                        outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                }
            }

            if (sampleCount < FRAME_SIZE) return null
            return DecodedAudio(monoSamples.copyOf(sampleCount), sampleRate)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        } finally {
            if (codecStarted) runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }

    private suspend fun makeOnsetEnvelope(samples: FloatArray): DoubleArray {
        if (samples.size < FRAME_SIZE) return DoubleArray(0)
        val energyCount = (samples.size - FRAME_SIZE) / HOP_SIZE + 1
        val energies = DoubleArray(energyCount)
        var frameStart = 0
        for (frameIndex in 0 until energyCount) {
            if (frameIndex % 32 == 0) currentCoroutineContext().ensureActive()
            var energy = 0.0
            for (sampleIndex in frameStart until frameStart + FRAME_SIZE) {
                energy += abs(samples[sampleIndex].toDouble())
            }
            energies[frameIndex] = energy / FRAME_SIZE
            frameStart += HOP_SIZE
        }

        return DoubleArray(max(energies.size - 1, 0)) { index ->
            max(energies[index + 1] - energies[index], 0.0)
        }
    }

    private fun prepareOnsetEnvelope(onsets: DoubleArray): DoubleArray {
        if (onsets.size <= 8) return onsets
        val mean = onsets.average()
        val variance = onsets.sumOf { value ->
            val delta = value - mean
            delta * delta
        } / onsets.size
        val threshold = mean + max(sqrt(variance) * 1.25, 0.0005)
        val firstStrong = onsets.indexOfFirst { it > threshold }.takeIf { it >= 0 } ?: 0
        return onsets.copyOfRange(max(firstStrong - 8, 0), onsets.size)
    }

    internal fun estimateBpm(onsetEnvelope: DoubleArray, hopDuration: Double): Double? {
        if (onsetEnvelope.isEmpty() || hopDuration <= 0) return null
        val minInterval = max(floor((60.0 / 200.0) / hopDuration).toInt(), 1)
        val maxInterval = max(ceil((60.0 / 60.0) / hopDuration).toInt(), minInterval)
        val candidates = mutableListOf<BpmCandidate>()
        var bestInterval = -1
        var bestScore = 0.0

        for (interval in minInterval..maxInterval) {
            if (interval >= onsetEnvelope.size) continue
            var score = 0.0
            for (index in interval until onsetEnvelope.size) {
                score += onsetEnvelope[index] * onsetEnvelope[index - interval]
            }
            score /= max(onsetEnvelope.size - interval, 1)
            candidates += BpmCandidate(60.0 / (interval * hopDuration), score)
            if (score > bestScore) {
                bestScore = score
                bestInterval = interval
            }
        }
        if (bestInterval < 0 || bestScore <= 0) return null

        fun scoreAt(interval: Int): Double = candidates
            .firstOrNull { abs(it.bpm - 60.0 / (interval * hopDuration)) < 0.0001 }
            ?.score ?: bestScore

        val previous = scoreAt(bestInterval - 1)
        val next = scoreAt(bestInterval + 1)
        val denominator = previous - 2 * bestScore + next
        val delta = if (denominator.isFinite() && denominator != 0.0) {
            (0.5 * (previous - next) / denominator).coerceIn(-0.5, 0.5)
        } else {
            0.0
        }
        val refinedBpm = 60.0 / ((bestInterval + delta) * hopDuration)
        candidates.removeAll { abs(it.bpm - 60.0 / (bestInterval * hopDuration)) < 0.0001 }
        candidates += BpmCandidate(refinedBpm, bestScore)
        return resolveOctave(candidates)
    }

    internal fun resolveOctave(candidates: List<BpmCandidate>): Double? {
        val valid = candidates.filter { it.bpm.isFinite() && it.score.isFinite() && it.score > 0 }
        val best = valid.maxByOrNull(BpmCandidate::score) ?: return null

        if (best.bpm >= 160.0) {
            val halfBpm = best.bpm / 2
            if (halfBpm in 80.0..115.0) {
                val half = valid.filter { abs(it.bpm - halfBpm) <= 3.0 }.maxByOrNull(BpmCandidate::score)
                if (half != null && half.score / best.score >= 0.35) return half.bpm
            }
        }

        if (best.bpm in 105.0..130.0) {
            val slowBpm = best.bpm / 1.5
            if (slowBpm in 60.0..85.0) {
                val slow = valid.filter { abs(it.bpm - slowBpm) <= 3.0 }.maxByOrNull(BpmCandidate::score)
                if (slow != null && slow.score / best.score >= 0.85) return slow.bpm
            }
        }
        return best.bpm
    }
}
