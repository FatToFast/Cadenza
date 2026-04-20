import AVFoundation
import Foundation

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum AssetResolverError: LocalizedError, Equatable {
    case missingAssetURL
    case cloudOnly
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAssetURL:
            return "이 곡의 오디오 파일에 접근할 수 없습니다"
        case .cloudOnly:
            return "기기에 다운로드된 곡만 불러올 수 있습니다"
        case .exportUnavailable:
            return "이 곡은 앱에서 분석 가능한 오디오로 변환할 수 없습니다"
        case .exportFailed(let reason):
            return "Apple Music 곡을 불러오지 못했습니다: \(reason)"
        }
    }
}

actor AssetResolver {
    static let shared = AssetResolver()

    private let fileManager: FileManager
    private let cacheDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.cacheDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CadenzaAppleMusic", isDirectory: true)
    }

    func resolve(_ track: AppleMusicTrack) async throws -> URL {
        if track.isCloudItem {
            throw AssetResolverError.cloudOnly
        }
        guard let assetURL = track.assetURL else {
            throw AssetResolverError.missingAssetURL
        }

        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let outputURL = cacheDirectory
            .appendingPathComponent(safeFilename(for: track))
            .appendingPathExtension("m4a")

        if fileManager.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let asset = AVURLAsset(url: assetURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AssetResolverError.exportUnavailable
        }
        guard exporter.supportedFileTypes.contains(.m4a) else {
            throw AssetResolverError.exportUnavailable
        }

        try? fileManager.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        let exportBox = ExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: AssetResolverError.exportFailed(
                        exportBox.session.error?.localizedDescription ?? "export failed"
                    ))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: AssetResolverError.exportFailed("unexpected export status"))
                }
            }
        }

        return outputURL
    }

    private func safeFilename(for track: AppleMusicTrack) -> String {
        "track-\(track.persistentID)"
    }
}
