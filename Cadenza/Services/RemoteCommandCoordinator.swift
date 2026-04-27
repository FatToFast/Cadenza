import Foundation
import MediaPlayer

/// 잠금화면/이어폰 미디어 컨트롤(play/pause/skip) 핸들러를 등록한다.
/// 로컬 파일 재생 경로에서만 의미가 있다 — Apple Music 스트리밍은 MusicKit이 자체 처리.
///
/// next/previous는 플레이리스트 리팩토링이 끝나기 전까지 비활성 상태로 둔다.
@MainActor
final class RemoteCommandCoordinator {
    private let audio: AudioManager
    private let center = MPRemoteCommandCenter.shared()

    init(audio: AudioManager) {
        self.audio = audio
        register()
    }

    private func register() {
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.audio.play() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.audio.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.audio.state == .playing {
                    self.audio.pause()
                } else {
                    self.audio.play()
                }
            }
            return .success
        }

        // next/previous는 플레이리스트 이동이 AudioManager에 흡수된 뒤 활성화한다.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
