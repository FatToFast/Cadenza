import AVFoundation

/// 오디오 파일에서 BPM 메타데이터를 추출한다.
/// ID3 TBPM 태그 (MP3) 또는 M4A tempo 태그를 읽는다.
enum BPMMetadataReader {

    /// 파일 URL에서 BPM 메타데이터를 읽는다.
    /// - Returns: BPM 값 (30~300 범위), 없거나 유효하지 않으면 nil
    static func readBPM(from url: URL) async -> Double? {
        let asset = AVAsset(url: url)

        guard let metadata = try? await asset.load(.metadata) else {
            return nil
        }

        // ID3 TBPM (MP3)
        if let bpm = await extractBPM(
            from: metadata,
            key: AVMetadataKey.id3MetadataKeyBeatsPerMinute,
            keySpace: .id3
        ) {
            return bpm
        }

        // iTunes/M4A tempo
        if let bpm = await extractBPM(
            from: metadata,
            key: AVMetadataKey.iTunesMetadataKeyBeatsPerMin,
            keySpace: .iTunes
        ) {
            return bpm
        }

        // Common metadata fallback
        for item in metadata {
            if let key = item.commonKey, key.rawValue.lowercased().contains("bpm") || key.rawValue.lowercased().contains("tempo") {
                if let bpm = await loadBPMValue(from: item) {
                    return bpm
                }
            }
        }

        return nil
    }

    private static func extractBPM(
        from metadata: [AVMetadataItem],
        key: AVMetadataKey,
        keySpace: AVMetadataKeySpace
    ) async -> Double? {
        let items = AVMetadataItem.metadataItems(from: metadata,
                                                  withKey: key,
                                                  keySpace: keySpace)
        guard let item = items.first else { return nil }

        var bpm: Double?

        if let number = try? await item.load(.numberValue) {
            bpm = number.doubleValue
        } else if let string = try? await item.load(.stringValue),
                  let parsed = Double(string) {
            bpm = parsed
        }

        guard let value = bpm, value >= BPMRange.originalMin, value <= BPMRange.originalMax else {
            return nil
        }

        return value
    }

    private static func loadBPMValue(from item: AVMetadataItem) async -> Double? {
        guard let value = try? await item.load(.value) else { return nil }

        var bpm: Double?
        if let number = value as? NSNumber {
            bpm = number.doubleValue
        } else if let string = value as? String, let parsed = Double(string) {
            bpm = parsed
        }

        guard let result = bpm, result >= BPMRange.originalMin, result <= BPMRange.originalMax else {
            return nil
        }

        return result
    }
}
