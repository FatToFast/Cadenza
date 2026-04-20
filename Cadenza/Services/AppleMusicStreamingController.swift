import Foundation
@preconcurrency import MusicKit

@MainActor
final class AppleMusicStreamingController: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let player = ApplicationMusicPlayer.shared

    var hasSong: Bool {
        currentSong != nil
    }

    var title: String? {
        currentSong?.title
    }

    var artist: String? {
        currentSong?.artistName
    }

    func clearError() {
        errorMessage = nil
    }

    func play(_ song: Song, playbackRate: Double) async {
        isLoading = true
        errorMessage = nil

        let status = await ensureAuthorization()
        guard status == .authorized else {
            isLoading = false
            errorMessage = "Apple Music 스트리밍 권한이 필요합니다"
            return
        }

        do {
            currentSong = song
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await player.prepareToPlay()
            applyPlaybackRate(playbackRate)
            try await player.play()
            isPlaying = true
        } catch {
            errorMessage = "Apple Music 스트리밍을 시작할 수 없습니다: \(error.localizedDescription)"
            isPlaying = false
        }

        isLoading = false
    }

    func togglePlayback(playbackRate: Double) async {
        guard currentSong != nil else { return }
        do {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                applyPlaybackRate(playbackRate)
                try await player.play()
                isPlaying = true
            }
        } catch {
            errorMessage = "Apple Music 재생 상태를 변경할 수 없습니다"
            isPlaying = false
        }
    }

    func stop() {
        player.stop()
        currentSong = nil
        isPlaying = false
        isLoading = false
    }

    func applyPlaybackRate(_ playbackRate: Double) {
        let clamped = min(max(playbackRate, Double(BPMRange.rateMin)), Double(BPMRange.rateMax))
        player.state.playbackRate = Float(clamped)
    }

    private func ensureAuthorization() async -> MusicAuthorization.Status {
        let currentStatus = MusicAuthorization.currentStatus
        if currentStatus == .notDetermined {
            return await MusicAuthorization.request()
        }
        return currentStatus
    }
}
