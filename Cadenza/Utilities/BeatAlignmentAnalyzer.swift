import AVFoundation
import CryptoKit
import Foundation

struct BeatAlignmentFingerprint: Codable, Equatable {
    let fileSize: Int64
    let modifiedAt: TimeInterval
    let durationSeconds: TimeInterval
}

struct BeatAlignmentAnalysis: Codable, Equatable {
    let fingerprint: BeatAlignmentFingerprint
    let estimatedBPM: Double
    let beatOffsetSeconds: TimeInterval
    let confidence: Double
    let manualNudgeSeconds: TimeInterval
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

struct BeatAlignmentLoadResult {
    let analysis: BeatAlignmentAnalysis?
    let cacheStatus: BeatAlignmentCacheStatus
}

enum BeatAlignmentAnalyzer {
    static func loadOrAnalyze(url: URL, expectedBPM: Double?) throws -> BeatAlignmentLoadResult {
        let file = try AVAudioFile(forReading: url)
        let fingerprint = makeFingerprint(for: url, file: file)

        if let cached = loadCachedAnalysis(for: url), cached.fingerprint == fingerprint {
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
            )
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
        guard preparedEnvelope.count > 32 else { return nil }

        let estimatedBPM = expectedBPM ?? estimateBPM(onsetEnvelope: preparedEnvelope, hopDuration: hopDuration)
        guard let estimatedBPM, estimatedBPM >= BPMRange.originalMin, estimatedBPM <= BPMRange.originalMax else {
            return nil
        }

        let beatOffsetSeconds = estimateBeatOffset(
            onsetEnvelope: preparedEnvelope,
            bpm: estimatedBPM,
            hopDuration: hopDuration
        )
        let confidence = estimateConfidence(
            onsetEnvelope: preparedEnvelope,
            bpm: estimatedBPM,
            beatOffsetSeconds: beatOffsetSeconds,
            hopDuration: hopDuration
        )

        return BeatAlignmentAnalysis(
            fingerprint: fingerprint,
            estimatedBPM: estimatedBPM,
            beatOffsetSeconds: beatOffsetSeconds,
            confidence: confidence,
            manualNudgeSeconds: 0
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

    private static func prepareOnsetEnvelope(_ onsetEnvelope: [Double]) -> [Double] {
        guard onsetEnvelope.count > 8 else { return onsetEnvelope }

        let mean = onsetEnvelope.reduce(0, +) / Double(onsetEnvelope.count)
        let variance = onsetEnvelope.reduce(into: 0.0) { partial, value in
            let delta = value - mean
            partial += delta * delta
        } / Double(onsetEnvelope.count)
        let threshold = mean + max(sqrt(variance) * 1.25, 0.0005)

        let firstStrongIndex = onsetEnvelope.firstIndex(where: { $0 > threshold }) ?? 0
        let startIndex = max(firstStrongIndex - 8, 0)
        return Array(onsetEnvelope[startIndex...])
    }

    private static func estimateBPM(onsetEnvelope: [Double], hopDuration: Double) -> Double? {
        guard !onsetEnvelope.isEmpty else { return nil }

        var bestScore = 0.0
        var bestBPM = BPMRange.originalDefault
        for bpm in stride(from: 80.0, through: 200.0, by: 1.0) {
            let interval = max(Int(round((60.0 / bpm) / hopDuration)), 1)
            guard interval < onsetEnvelope.count else { continue }

            var score = 0.0
            for index in interval..<onsetEnvelope.count {
                score += onsetEnvelope[index] * onsetEnvelope[index - interval]
            }

            if score > bestScore {
                bestScore = score
                bestBPM = bpm
            }
        }

        return bestScore > 0 ? bestBPM : nil
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
