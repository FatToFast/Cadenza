import Combine
import Foundation
import MediaPlayer
import UIKit

/// `MPNowPlayingInfoCenter`에 로컬 파일 재생 상태를 push.
/// Apple Music 스트리밍 경로는 MusicKit이 자체 처리하므로 여기서 다루지 않는다.
@MainActor
final class NowPlayingCenterCoordinator {
    private let audio: AudioManager
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var cancellables: Set<AnyCancellable> = []

    init(audio: AudioManager) {
        self.audio = audio
        observe()
    }

    private func observe() {
        // 메타데이터/지속시간/아트워크 변경 — 곡 단위
        Publishers
            .CombineLatest4(
                audio.$trackTitle,
                audio.$trackArtist,
                audio.$trackDuration,
                audio.$currentArtworkData
            )
            .sink { [weak self] _, _, _, _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // 재생 상태/속도 — 시간/속도 단위
        Publishers
            .CombineLatest3(
                audio.$state,
                audio.$currentPlaybackTime,
                audio.$targetBPM // playbackRate 변경을 추적하기 위해 (rate는 originalBPM과 targetBPM에서 파생)
            )
            .sink { [weak self] _, _, _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard audio.hasLoadedTrack, let title = audio.trackTitle else {
            infoCenter.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if let artist = audio.trackArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        info[MPMediaItemPropertyPlaybackDuration] = audio.trackDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audio.currentPlaybackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = audio.state == .playing ? audio.playbackRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = audio.playbackRate

        if let data = audio.currentArtworkData, let artwork = Self.makeArtwork(from: data) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info
    }

    /// MediaPlayer invokes the artwork request handler on its own access queue.
    /// Build the closure outside this coordinator's MainActor isolation so Swift 6
    /// does not insert a main-executor precondition into that callback.
    nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
