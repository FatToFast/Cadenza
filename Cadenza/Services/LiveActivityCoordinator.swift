import ActivityKit
import Combine
import Foundation
import UIKit

/// Live Activity 생명주기 — 곡이 로드되면 시작, 트랙/상태 변경 시 update,
/// 트랙이 사라지면 종료. iOS 16.1+ 필요.
@MainActor
final class LiveActivityCoordinator {
    private let audio: AudioManager
    nonisolated(unsafe) private var activity: Activity<CadenzaActivityAttributes>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPushedAt: Date = .distantPast

    /// 페이로드 한계를 지키기 위한 최소 update 간격 — 진행 시간 같이 자주 바뀌는 값은
    /// 위젯의 자체 timeline이 아니라 이쪽에서 throttle한 update만 받는다.
    private let minUpdateInterval: TimeInterval = 8

    init(audio: AudioManager) {
        self.audio = audio
        observe()
    }

    private func observe() {
        // 곡 로드/변경 — title이나 duration이 바뀌면 새 Activity 시작 또는 update.
        Publishers
            .CombineLatest3(
                audio.$trackTitle,
                audio.$trackDuration,
                audio.$currentArtworkData
            )
            .sink { [weak self] title, _, _ in
                if title == nil {
                    Task { @MainActor in await self?.end() }
                } else {
                    Task { @MainActor in await self?.startOrUpdate(force: true) }
                }
            }
            .store(in: &cancellables)

        // 재생/일시정지는 즉시 반영한다.
        audio.$state
            .sink { [weak self] _ in
                Task { @MainActor in await self?.startOrUpdate(force: true) }
            }
            .store(in: &cancellables)

        // BPM/케이던스는 진행 시간 throttle과 분리하되, 슬라이더를 드래그할 때
        // ActivityKit update가 1 SPM마다 폭주하지 않도록 짧게 debounce한다.
        Publishers.CombineLatest(
                audio.$originalBPM,
                audio.$targetBPM
            )
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                Task { @MainActor in await self?.startOrUpdate(force: true) }
            }
            .store(in: &cancellables)

        // 진행 시간만 페이로드 갱신 빈도를 제한한다.
        audio.$currentPlaybackTime
            .sink { [weak self] _ in
                Task { @MainActor in await self?.startOrUpdate(force: false) }
            }
            .store(in: &cancellables)
    }

    private func startOrUpdate(force: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let title = audio.trackTitle, audio.hasLoadedTrack else { return }

        let now = Date()
        if !force, now.timeIntervalSince(lastPushedAt) < minUpdateInterval { return }
        lastPushedAt = now

        let plan = audio.tempoPlan
        let state = CadenzaActivityState(
            title: title,
            artist: audio.trackArtist,
            effectiveCadence: roundedInt(plan.effectiveCadence, fallback: Int(BPMRange.targetDefault)),
            baseCadence: roundedInt(plan.baseCadence, fallback: Int(BPMRange.targetDefault)),
            originalBPM: confirmedOriginalBPM,
            elapsed: audio.currentPlaybackTime,
            duration: audio.trackDuration,
            isPlaying: audio.state == .playing,
            artworkData: thumbnailArtwork()
        )

        let content = ActivityContent(state: state, staleDate: nil)
        if activity != nil {
            await activity?.update(content)
        } else {
            do {
                activity = try Activity.request(
                    attributes: CadenzaActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            } catch {
                // Activity 요청 실패는 사용자가 system setting에서 차단했을 때 등 — 조용히 무시.
            }
        }
    }

    private func end() async {
        guard let lastContent = activity?.content else { return }
        let content = ActivityContent(state: lastContent.state, staleDate: nil)
        await activity?.end(content, dismissalPolicy: .immediate)
        activity = nil
    }

    /// 64x64 썸네일로 다운샘플 — Live Activity 페이로드(~4KB) 안에 들어가도록.
    private func thumbnailArtwork() -> Data? {
        guard let data = audio.currentArtworkData, let image = UIImage(data: data) else { return nil }
        let target = CGSize(width: 128, height: 128)
        UIGraphicsBeginImageContextWithOptions(target, false, 1)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: target))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        return resized?.jpegData(compressionQuality: 0.7)
    }

    private func roundedInt(_ value: Double, fallback: Int) -> Int {
        guard value.isFinite,
              let roundedValue = Int(exactly: value.rounded()) else {
            return fallback
        }
        return roundedValue
    }

    private var confirmedOriginalBPM: Int {
        guard audio.originalBPMSource != .assumedDefault else { return 0 }
        return roundedInt(audio.originalBPM, fallback: 0)
    }
}
