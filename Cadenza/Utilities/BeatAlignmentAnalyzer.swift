import AVFoundation
import CryptoKit
import Foundation

struct BeatAlignmentFingerprint: Codable, Equatable, Sendable {
    let fileSize: Int64
    let modifiedAt: TimeInterval
    let durationSeconds: TimeInterval
}

struct BeatAlignmentAnalysis: Codable, Equatable, Sendable {
    let fingerprint: BeatAlignmentFingerprint
    let estimatedBPM: Double
    let beatOffsetSeconds: TimeInterval
    let confidence: Double
    let manualNudgeSeconds: TimeInterval
    let beatTimesSeconds: [TimeInterval]?
}

enum BeatAlignmentCacheStatus: String {
    case none
    case hit
    case miss
}

enum BeatOffsetRefinement {
    /// 3점 parabolic fit으로 quantized score peak를 sub-bin 정확도로 refine한다.
    /// phase 공간은 scores.count 모듈러 순환이므로 양끝은 wrap-around로 참조.
    static func refinedPhase(scores: [Double], bestPhase: Int) -> Double {
        let count = scores.count
        guard count >= 3 else { return Double(bestPhase) }
        let safePhase = ((bestPhase % count) + count) % count
        let prev = scores[(safePhase - 1 + count) % count]
        let mid = scores[safePhase]
        let next = scores[(safePhase + 1) % count]
        let denom = prev - 2 * mid + next
        guard denom.isFinite, denom != 0 else { return Double(safePhase) }
        let rawDelta = 0.5 * (prev - next) / denom
        guard rawDelta.isFinite else { return Double(safePhase) }
        let delta = min(max(rawDelta, -0.5), 0.5)
        var refined = Double(safePhase) + delta
        if refined < 0 { refined += Double(count) }
        if refined >= Double(count) { refined -= Double(count) }
        return refined
    }
}

enum BPMIntervalRefinement {
    static func refinedInterval(scoresByInterval: [Int: Double], bestInterval: Int) -> Double {
        guard let mid = scoresByInterval[bestInterval] else { return Double(bestInterval) }
        let prev = scoresByInterval[bestInterval - 1] ?? mid
        let next = scoresByInterval[bestInterval + 1] ?? mid
        let denom = prev - 2 * mid + next
        guard denom.isFinite, denom != 0 else { return Double(bestInterval) }
        let rawDelta = 0.5 * (prev - next) / denom
        guard rawDelta.isFinite else { return Double(bestInterval) }
        let delta = min(max(rawDelta, -0.5), 0.5)
        return Double(bestInterval) + delta
    }
}

struct BPMCandidate: Equatable {
    let bpm: Double
    let score: Double
}

enum BPMOctaveResolver {
    private static let doubleTimeThreshold = 160.0
    private static let halfTimeMin = 80.0
    private static let halfTimeMax = 115.0
    private static let halfTimeTolerance = 3.0
    private static let halfTimeScoreRatio = 0.35
    private static let slowTempoMin = 60.0
    private static let slowTempoMax = 85.0
    private static let slowTempoTolerance = 3.0
    private static let slowTempoScoreRatio = 0.85

    static func resolve(candidates: [BPMCandidate]) -> Double? {
        let validCandidates = candidates.filter { candidate in
            candidate.bpm.isFinite && candidate.score.isFinite && candidate.score > 0
        }
        guard let best = validCandidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        if let halfTime = halfTimeCandidate(for: best, candidates: validCandidates) {
            return halfTime.bpm
        }

        if let slowTempo = slowTempoCandidate(for: best, candidates: validCandidates) {
            return slowTempo.bpm
        }

        return best.bpm
    }

    private static func halfTimeCandidate(
        for best: BPMCandidate,
        candidates: [BPMCandidate]
    ) -> BPMCandidate? {
        guard best.bpm >= doubleTimeThreshold else { return nil }

        let halfTimeBPM = best.bpm / 2
        guard halfTimeBPM >= halfTimeMin, halfTimeBPM <= halfTimeMax else { return nil }
        guard let candidate = strongestCandidate(
            near: halfTimeBPM,
            tolerance: halfTimeTolerance,
            candidates: candidates
        ) else {
            return nil
        }

        let scoreRatio = candidate.score / best.score
        guard scoreRatio >= halfTimeScoreRatio else { return nil }
        return candidate
    }

    private static func slowTempoCandidate(
        for best: BPMCandidate,
        candidates: [BPMCandidate]
    ) -> BPMCandidate? {
        guard best.bpm >= 105, best.bpm <= 130 else { return nil }

        let slowBPM = best.bpm / 1.5
        guard slowBPM >= slowTempoMin, slowBPM <= slowTempoMax else { return nil }
        guard let candidate = strongestCandidate(
            near: slowBPM,
            tolerance: slowTempoTolerance,
            candidates: candidates
        ) else {
            return nil
        }

        let scoreRatio = candidate.score / best.score
        guard scoreRatio >= slowTempoScoreRatio else { return nil }
        return candidate
    }

    private static func strongestCandidate(
        near bpm: Double,
        tolerance: Double,
        candidates: [BPMCandidate]
    ) -> BPMCandidate? {
        candidates
            .filter { abs($0.bpm - bpm) <= tolerance }
            .max(by: { lhs, rhs in
                if lhs.score == rhs.score {
                    return abs(lhs.bpm - bpm) > abs(rhs.bpm - bpm)
                }
                return lhs.score < rhs.score
            })
    }
}

struct BeatAlignmentLoadResult {
    let analysis: BeatAlignmentAnalysis?
    let cacheStatus: BeatAlignmentCacheStatus
}

private struct PreparedOnsetEnvelope {
    let values: [Double]
    let startIndex: Int
}

enum BeatAlignmentAnalyzer {
    static func loadOrAnalyze(url: URL, expectedBPM: Double?) throws -> BeatAlignmentLoadResult {
        let file = try AVAudioFile(forReading: url)
        let fingerprint = makeFingerprint(for: url, file: file)

        if let cached = loadCachedAnalysis(for: url),
           cached.fingerprint == fingerprint,
           cached.beatTimesSeconds?.isEmpty == false {
            return BeatAlignmentLoadResult(analysis: cached, cacheStatus: .hit)
        }

        guard let analysis = try analyze(fileURL: url, file: file, expectedBPM: expectedBPM, fingerprint: fingerprint) else {
            return BeatAlignmentLoadResult(analysis: nil, cacheStatus: .none)
        }

        try save(analysis: analysis, for: url)
        return BeatAlignmentLoadResult(analysis: analysis, cacheStatus: .miss)
    }

    static func updateManualNudge(
        _ manualNudge: TimeInterval,
        for url: URL,
        analysis: BeatAlignmentAnalysis
    ) throws -> BeatAlignmentAnalysis {
        let beatDuration = 60.0 / analysis.estimatedBPM
        let updated = BeatAlignmentAnalysis(
            fingerprint: analysis.fingerprint,
            estimatedBPM: analysis.estimatedBPM,
            beatOffsetSeconds: analysis.beatOffsetSeconds,
            confidence: analysis.confidence,
            manualNudgeSeconds: BeatOffsetAdjustment.normalizedManualNudge(
                manualNudge,
                beatDuration: beatDuration
            ),
            beatTimesSeconds: analysis.beatTimesSeconds
        )
        try save(analysis: updated, for: url)
        return updated
    }

    private static func analyze(
        fileURL: URL,
        file: AVAudioFile,
        expectedBPM: Double?,
        fingerprint: BeatAlignmentFingerprint
    ) throws -> BeatAlignmentAnalysis? {
        guard let monoSamples = try readMonoSamples(from: file, maxSeconds: 20) else {
            return nil
        }

        let sampleRate = file.processingFormat.sampleRate
        let frameSize = 2_048
        let hopSize = 512
        let hopDuration = Double(hopSize) / sampleRate
        let onsetEnvelope = makeOnsetEnvelope(
            monoSamples: monoSamples,
            frameSize: frameSize,
            hopSize: hopSize
        )

        guard onsetEnvelope.count > 32 else { return nil }
        let preparedEnvelope = prepareOnsetEnvelope(onsetEnvelope)
        guard preparedEnvelope.values.count > 32 else { return nil }

        let estimatedBPM = expectedBPM ?? estimateBPM(onsetEnvelope: preparedEnvelope.values, hopDuration: hopDuration)
        guard let estimatedBPM, estimatedBPM >= BPMRange.originalMin, estimatedBPM <= BPMRange.originalMax else {
            return nil
        }

        let localBeatOffsetSeconds = estimateBeatOffset(
            onsetEnvelope: preparedEnvelope.values,
            bpm: estimatedBPM,
            hopDuration: hopDuration
        )
        let beatDuration = 60.0 / estimatedBPM
        let analysisStartSeconds = Double(preparedEnvelope.startIndex) * hopDuration
        let beatOffsetSeconds = MetronomeSyncPlanner.normalizedOffset(
            analysisStartSeconds + localBeatOffsetSeconds,
            beatDuration: beatDuration
        )
        let confidence = estimateConfidence(
            onsetEnvelope: preparedEnvelope.values,
            bpm: estimatedBPM,
            beatOffsetSeconds: localBeatOffsetSeconds,
            hopDuration: hopDuration
        )
        let beatTimesSeconds = estimateBeatTimes(
            onsetEnvelope: preparedEnvelope.values,
            bpm: estimatedBPM,
            beatOffsetSeconds: localBeatOffsetSeconds,
            hopDuration: hopDuration,
            analysisStartSeconds: analysisStartSeconds,
            durationSeconds: fingerprint.durationSeconds
        )

        return BeatAlignmentAnalysis(
            fingerprint: fingerprint,
            estimatedBPM: estimatedBPM,
            beatOffsetSeconds: beatOffsetSeconds,
            confidence: confidence,
            manualNudgeSeconds: 0,
            beatTimesSeconds: beatTimesSeconds
        )
    }

    private static func readMonoSamples(from file: AVAudioFile, maxSeconds: Double) throws -> [Float]? {
        let sampleRate = file.processingFormat.sampleRate
        let frameLimit = min(file.length, AVAudioFramePosition(sampleRate * maxSeconds))
        guard frameLimit > 0 else { return nil }

        file.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameLimit)
        ) else {
            return nil
        }

        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameLimit))
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        if let floatChannels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            return (0..<frameLength).map { frameIndex in
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += floatChannels[channel][frameIndex]
                }
                return mixed / Float(channelCount)
            }
        }

        if let int16Channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            return (0..<frameLength).map { frameIndex in
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += Float(int16Channels[channel][frameIndex]) / Float(Int16.max)
                }
                return mixed / Float(channelCount)
            }
        }

        return nil
    }

    private static func makeOnsetEnvelope(
        monoSamples: [Float],
        frameSize: Int,
        hopSize: Int
    ) -> [Double] {
        guard monoSamples.count >= frameSize else { return [] }

        var energies: [Double] = []
        energies.reserveCapacity((monoSamples.count - frameSize) / hopSize + 1)

        var frameStart = 0
        while frameStart + frameSize <= monoSamples.count {
            let frame = monoSamples[frameStart..<(frameStart + frameSize)]
            let energy = frame.reduce(into: 0.0) { partialResult, sample in
                partialResult += Double(abs(sample))
            } / Double(frameSize)
            energies.append(energy)
            frameStart += hopSize
        }

        var onsets: [Double] = []
        onsets.reserveCapacity(max(energies.count - 1, 0))
        var previous = energies.first ?? 0
        for energy in energies.dropFirst() {
            onsets.append(max(energy - previous, 0))
            previous = energy
        }

        return onsets
    }

    private static func prepareOnsetEnvelope(_ onsetEnvelope: [Double]) -> PreparedOnsetEnvelope {
        guard onsetEnvelope.count > 8 else {
            return PreparedOnsetEnvelope(values: onsetEnvelope, startIndex: 0)
        }

        let mean = onsetEnvelope.reduce(0, +) / Double(onsetEnvelope.count)
        let variance = onsetEnvelope.reduce(into: 0.0) { partial, value in
            let delta = value - mean
            partial += delta * delta
        } / Double(onsetEnvelope.count)
        let threshold = mean + max(sqrt(variance) * 1.25, 0.0005)

        let firstStrongIndex = onsetEnvelope.firstIndex(where: { $0 > threshold }) ?? 0
        let startIndex = max(firstStrongIndex - 8, 0)
        return PreparedOnsetEnvelope(values: Array(onsetEnvelope[startIndex...]), startIndex: startIndex)
    }

    private static func estimateBPM(onsetEnvelope: [Double], hopDuration: Double) -> Double? {
        guard !onsetEnvelope.isEmpty else { return nil }

        let minBPM = 60.0
        let maxBPM = 200.0
        let minInterval = max(Int(floor((60.0 / maxBPM) / hopDuration)), 1)
        let maxInterval = max(Int(ceil((60.0 / minBPM) / hopDuration)), minInterval)
        var scoresByInterval: [Int: Double] = [:]

        for interval in minInterval...maxInterval {
            guard interval < onsetEnvelope.count else { continue }

            var score = 0.0
            for index in interval..<onsetEnvelope.count {
                score += onsetEnvelope[index] * onsetEnvelope[index - interval]
            }

            let pairCount = max(onsetEnvelope.count - interval, 1)
            scoresByInterval[interval] = score / Double(pairCount)
        }

        guard let bestInterval = scoresByInterval.max(by: { $0.value < $1.value })?.key,
              let bestScore = scoresByInterval[bestInterval],
              bestScore > 0 else {
            return nil
        }

        let refinedInterval = BPMIntervalRefinement.refinedInterval(
            scoresByInterval: scoresByInterval,
            bestInterval: bestInterval
        )
        let refinedBPM = 60.0 / (refinedInterval * hopDuration)
        var candidates = scoresByInterval.map { interval, score in
            BPMCandidate(bpm: 60.0 / (Double(interval) * hopDuration), score: score)
        }
        candidates.removeAll { candidate in
            abs(candidate.bpm - 60.0 / (Double(bestInterval) * hopDuration)) < 0.000_1
        }
        candidates.append(BPMCandidate(bpm: refinedBPM, score: bestScore))

        return BPMOctaveResolver.resolve(candidates: candidates)
    }

    private static func estimateBeatOffset(
        onsetEnvelope: [Double],
        bpm: Double,
        hopDuration: Double
    ) -> TimeInterval {
        let beatFrames = max(Int(round((60.0 / bpm) / hopDuration)), 1)
        guard beatFrames > 0, onsetEnvelope.count > beatFrames else { return 0 }

        let offbeatOffset = max(beatFrames / 2, 1)
        var scores = [Double](repeating: 0, count: beatFrames)
        for phase in 0..<beatFrames {
            var beatScore = 0.0
            var offbeatScore = 0.0
            var index = phase
            var weight = 1.0
            while index < onsetEnvelope.count {
                beatScore += onsetEnvelope[index] * weight
                let offbeatIndex = index + offbeatOffset
                if offbeatIndex < onsetEnvelope.count {
                    offbeatScore += onsetEnvelope[offbeatIndex] * weight
                }
                weight *= 0.985
                index += beatFrames
            }
            scores[phase] = beatScore - (offbeatScore * 0.55)
        }

        var bestPhase = 0
        var bestScore = -Double.infinity
        for (phase, score) in scores.enumerated() where score > bestScore {
            bestScore = score
            bestPhase = phase
        }

        let refinedPhase = BeatOffsetRefinement.refinedPhase(scores: scores, bestPhase: bestPhase)
        return refinedPhase * hopDuration
    }

    private static func estimateConfidence(
        onsetEnvelope: [Double],
        bpm: Double,
        beatOffsetSeconds: TimeInterval,
        hopDuration: Double
    ) -> Double {
        let beatFrames = max(Int(round((60.0 / bpm) / hopDuration)), 1)
        guard beatFrames > 0 else { return 0 }

        let phase = min(max(Int(round(beatOffsetSeconds / hopDuration)), 0), beatFrames - 1)
        var alignedScore = 0.0
        var baselineScore = 0.0
        var index = phase
        while index < onsetEnvelope.count {
            alignedScore += onsetEnvelope[index]
            index += beatFrames
        }

        baselineScore = onsetEnvelope.reduce(0, +) / Double(onsetEnvelope.count)
        guard baselineScore > 0 else { return 0 }
        return min(max(alignedScore / (baselineScore * Double(max(onsetEnvelope.count / beatFrames, 1))), 0), 1)
    }

    private static func estimateBeatTimes(
        onsetEnvelope: [Double],
        bpm: Double,
        beatOffsetSeconds: TimeInterval,
        hopDuration: Double,
        analysisStartSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) -> [TimeInterval] {
        let beatDuration = 60.0 / bpm
        guard beatDuration.isFinite, beatDuration > 0, hopDuration > 0 else { return [] }
        guard onsetEnvelope.count > 4 else { return [] }

        let mean = onsetEnvelope.reduce(0, +) / Double(onsetEnvelope.count)
        let variance = onsetEnvelope.reduce(into: 0.0) { partial, value in
            let delta = value - mean
            partial += delta * delta
        } / Double(onsetEnvelope.count)
        let peakThreshold = mean + sqrt(variance) * 0.2
        let searchWindowFrames = max(Int(round((beatDuration * 0.22) / hopDuration)), 2)
        let maxCorrection = min(beatDuration * 0.18, 0.09)
        let analysisDuration = Double(onsetEnvelope.count - 1) * hopDuration
        var localBeatTime = MetronomeSyncPlanner.normalizedOffset(
            beatOffsetSeconds,
            beatDuration: beatDuration
        )

        while localBeatTime - beatDuration >= 0 {
            localBeatTime -= beatDuration
        }

        var beatTimes: [TimeInterval] = []
        while localBeatTime <= analysisDuration {
            let expectedIndex = Int(round(localBeatTime / hopDuration))
            let lowerBound = max(expectedIndex - searchWindowFrames, 0)
            let upperBound = min(expectedIndex + searchWindowFrames, onsetEnvelope.count - 1)

            var peakIndex = expectedIndex
            var peakValue = -Double.infinity
            if lowerBound <= upperBound {
                for index in lowerBound...upperBound where onsetEnvelope[index] > peakValue {
                    peakIndex = index
                    peakValue = onsetEnvelope[index]
                }
            }

            let peakTime = Double(peakIndex) * hopDuration
            let correctionWeight = peakValue >= peakThreshold ? 0.85 : 0.35
            let correction = min(max(peakTime - localBeatTime, -maxCorrection), maxCorrection)
            let adaptedLocalBeatTime = localBeatTime + correction * correctionWeight
            let sourceBeatTime = analysisStartSeconds + adaptedLocalBeatTime

            if sourceBeatTime >= 0, sourceBeatTime <= durationSeconds {
                beatTimes.append(sourceBeatTime)
            }

            localBeatTime += beatDuration
        }

        return beatTimes
    }

    private static func makeFingerprint(for url: URL, file: AVAudioFile) -> BeatAlignmentFingerprint {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        return BeatAlignmentFingerprint(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            durationSeconds: durationSeconds
        )
    }

    private static func loadCachedAnalysis(for url: URL) -> BeatAlignmentAnalysis? {
        guard let cacheURL = try? cacheURL(for: url),
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(BeatAlignmentAnalysis.self, from: data)
    }

    private static func save(analysis: BeatAlignmentAnalysis, for url: URL) throws {
        let data = try JSONEncoder().encode(analysis)
        let destinationURL = try cacheURL(for: url)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func cacheURL(for url: URL) throws -> URL {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesDirectory
            .appendingPathComponent("BeatAlignmentCache", isDirectory: true)
            .appendingPathComponent(stableCacheKey(for: url))
            .appendingPathExtension("json")
    }

    private static func stableCacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
