import Foundation
import AVFoundation
import Combine
import MediaPlayer
import OSLog
@preconcurrency import MusicKit

struct StreamingBPMResult: Equatable, Sendable {
    let bpm: Double
    let source: OriginalBPMSource
    let beatOffsetSeconds: TimeInterval?
    let beatTimesSeconds: [TimeInterval]?
    let confidence: Double?
    let beatSyncStatus: BeatSyncStatus
    let beatSyncIssue: BeatSyncReliabilityIssue?
}

struct StreamingBPMResolution: Equatable, Sendable {
    let result: StreamingBPMResult?
    let didAttemptGetSongBPM: Bool
}

struct StreamingBPMResolver: Sendable {
    typealias GetSongBPMLookup = @Sendable (_ title: String, _ artist: String?, _ appleMusicID: String?, _ isrc: String?) async -> GetSongBPMService.Result?
    typealias PreviewAnalysisLookup = @Sendable () async -> BeatAlignmentAnalysis?

    let getSongBPM: GetSongBPMLookup
    let previewAnalysis: PreviewAnalysisLookup

    func resolve(
        cachedResult: StreamingBPMResult?,
        shouldTryGetSongBPM: Bool,
        shouldTryPreviewAnalysis: Bool,
        title: String,
        artist: String?,
        appleMusicID: String?,
        isrc: String? = nil
    ) async -> StreamingBPMResolution {
        if shouldTryGetSongBPM,
           let external = await getSongBPM(title, artist, appleMusicID, isrc) {
            return StreamingBPMResolution(
                result: StreamingBPMResult(
                    bpm: external.bpm,
                    source: .metadata,
                    beatOffsetSeconds: nil,
                    beatTimesSeconds: nil,
                    confidence: nil,
                    beatSyncStatus: .bpmOnly,
                    beatSyncIssue: .missingBeatGrid
                ),
                didAttemptGetSongBPM: true
            )
        }

        if let cachedResult {
            return StreamingBPMResolution(
                result: cachedResult,
                didAttemptGetSongBPM: shouldTryGetSongBPM
            )
        }

        guard shouldTryPreviewAnalysis,
              let analysis = await previewAnalysis() else {
            return StreamingBPMResolution(
                result: nil,
                didAttemptGetSongBPM: shouldTryGetSongBPM
            )
        }

        let assessment = BeatSyncReliability.assess(
            originalBPM: analysis.estimatedBPM,
            confidence: analysis.confidence,
            beatTimesSeconds: analysis.beatTimesSeconds ?? []
        )
        return StreamingBPMResolution(
            result: StreamingBPMResult(
                bpm: analysis.estimatedBPM,
                source: .analysis,
                beatOffsetSeconds: assessment.shouldUseBeatGrid ? analysis.beatOffsetSeconds : nil,
                beatTimesSeconds: assessment.shouldUseBeatGrid ? analysis.beatTimesSeconds : nil,
                confidence: analysis.confidence,
                beatSyncStatus: assessment.status,
                beatSyncIssue: assessment.issue
            ),
            didAttemptGetSongBPM: shouldTryGetSongBPM
        )
    }
}

@MainActor
final class AppleMusicStreamingController: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentArtist: String?
    @Published private(set) var currentBPM: Double?
    @Published private(set) var currentBPMSource: OriginalBPMSource?
    @Published private(set) var currentBeatOffsetSeconds: TimeInterval?
    @Published private(set) var currentBeatTimesSeconds: [TimeInterval] = []
    @Published private(set) var currentBeatAlignmentConfidence: Double?
    @Published private(set) var currentBeatSyncStatus: BeatSyncStatus = .needsConfirmation
    @Published private(set) var currentBeatSyncIssue: BeatSyncReliabilityIssue? = .missingBPM
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var canShuffle = false
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var canRepeat = false
    @Published private(set) var isRepeatEnabled = false
    @Published private(set) var errorMessage: String?

    private let player = ApplicationMusicPlayer.shared
    private var queueCancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?
    private var nowPlayingTask: Task<Void, Never>?
    private var bpmAnalysisTask: Task<Void, Never>?
    private var activePreviewAnalysisKey: String?
    private var failedPreviewAnalysisKeys: Set<String> = []
    private var getSongBPMAttemptedKeys: Set<String> = []
    private var bpmCacheByKey: [String: StreamingBPMResult] = [:]
    private var didBuildBPMCache = false
    private var desiredPlaybackRate: Float = 1.0
    private let logger = Logger(subsystem: "com.jy.cadenza", category: "AppleMusicStreaming")
    private let bpmOverrideStore: TrackBPMOverrideStore

    init(bpmOverrideStore: TrackBPMOverrideStore = .shared) {
        self.bpmOverrideStore = bpmOverrideStore
    }

    var hasSong: Bool {
        currentTitle != nil
    }

    var title: String? {
        currentTitle
    }

    var artist: String? {
        currentArtist
    }

    var playbackTime: TimeInterval {
        player.playbackTime
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
        await prepareBPMCacheIfPossible()

        do {
            currentSong = song
            currentTitle = song.title
            currentArtist = song.artistName
            applyResolvedBPM(bpm(for: song))
            startPreviewBPMAnalysisIfNeeded(for: song)
            canShuffle = false
            canRepeat = true
            setShuffleEnabled(false)
            setRepeatEnabled(false)
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            startPlayerObservation()
            syncCurrentEntryFromQueue()
            try await player.prepareToPlay()
            applyPlaybackRate(playbackRate)
            try await player.play()
            isPlaying = true
            enforcePlaybackRate(reason: "song-play-started")
            reapplyPlaybackRateAfterStartup()
        } catch {
            errorMessage = "Apple Music 스트리밍을 시작할 수 없습니다: \(error.localizedDescription)"
            isPlaying = false
        }

        isLoading = false
    }

    func play(
        playlist: Playlist,
        startingAt entry: Playlist.Entry,
        playbackRate: Double,
        preloadedEntries: [Playlist.Entry] = []
    ) async {
        isLoading = true
        errorMessage = nil

        let status = await ensureAuthorization()
        guard status == .authorized else {
            isLoading = false
            errorMessage = "Apple Music 스트리밍 권한이 필요합니다"
            return
        }
        await prepareBPMCacheIfPossible()
        await seedBPMCacheFromPrefetchedLookups(preloadedEntries)
        startPlaylistBPMPreload(preloadedEntries)

        do {
            currentSong = nil
            currentTitle = entry.title
            currentArtist = entry.artistName
            applyResolvedBPM(bpm(for: entry))
            startPreviewBPMAnalysisIfNeeded(for: entry)
            canShuffle = true
            canRepeat = true
            setShuffleEnabled(false)
            setRepeatEnabled(false)
            player.queue = ApplicationMusicPlayer.Queue(playlist: playlist, startingAt: entry)
            startPlayerObservation()
            syncCurrentEntryFromQueue()
            try await player.prepareToPlay()
            applyPlaybackRate(playbackRate)
            try await player.play()
            isPlaying = true
            enforcePlaybackRate(reason: "playlist-play-started")
            reapplyPlaybackRateAfterStartup()
        } catch {
            errorMessage = "Apple Music 플레이리스트를 재생할 수 없습니다: \(error.localizedDescription)"
            isPlaying = false
        }

        isLoading = false
    }

    private func seedBPMCacheFromPrefetchedLookups(_ entries: [Playlist.Entry]) async {
        for entry in entries {
            let lookup = trackLookup(for: entry)
            guard let result = await GetSongBPMService.shared.cachedBPM(
                title: lookup.title,
                artist: lookup.artist,
                appleMusicID: lookup.appleMusicID,
                isrc: lookup.isrc
            ) else { continue }
            cacheBPMResult(
                StreamingBPMResult(
                    bpm: result.bpm,
                    source: .metadata,
                    beatOffsetSeconds: nil,
                    beatTimesSeconds: nil,
                    confidence: nil,
                    beatSyncStatus: .bpmOnly,
                    beatSyncIssue: .missingBeatGrid
                ),
                songID: lookup.appleMusicID,
                title: entry.title,
                artist: entry.artistName,
                albumTitle: entry.albumTitle
            )
        }
    }

    private func startPlaylistBPMPreload(_ entries: [Playlist.Entry]) {
        guard !entries.isEmpty else { return }

        logger.notice("[bpm_preload] start entries=\(entries.count)")
        print("[bpm_preload] start entries=\(entries.count)")
        Task(priority: .utility) { [weak self] in
            for entry in entries {
                let lookup = self?.trackLookup(for: entry) ?? GetSongBPMService.TrackLookup(
                    appleMusicID: entry.id.rawValue,
                    isrc: entry.isrc,
                    title: entry.title,
                    artist: entry.artistName
                )
                guard let result = await GetSongBPMService.shared.lookupBPM(
                    title: lookup.title,
                    artist: lookup.artist,
                    appleMusicID: lookup.appleMusicID,
                    isrc: lookup.isrc
                ) else {
                    await MainActor.run { [weak self] in
                        self?.logger.notice("[bpm_preload] empty title=\(entry.title, privacy: .public) artist=\(entry.artistName, privacy: .public)")
                        print("[bpm_preload] empty title=\(entry.title) artist=\(entry.artistName)")
                    }
                    continue
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let bpmResult = StreamingBPMResult(
                        bpm: result.bpm,
                        source: .metadata,
                        beatOffsetSeconds: nil,
                        beatTimesSeconds: nil,
                        confidence: nil,
                        beatSyncStatus: .bpmOnly,
                        beatSyncIssue: .missingBeatGrid
                    )
                    self.cacheBPMResult(
                        bpmResult,
                        songID: lookup.appleMusicID,
                        title: entry.title,
                        artist: entry.artistName,
                        albumTitle: entry.albumTitle
                    )
                    if self.currentTitle == entry.title && self.currentArtist == entry.artistName {
                        self.applyResolvedBPM(bpmResult)
                    }
                    self.logger.notice("[bpm_preload] success title=\(entry.title, privacy: .public) artist=\(entry.artistName, privacy: .public) bpm=\(result.bpm)")
                    print("[bpm_preload] success title=\(entry.title) artist=\(entry.artistName) bpm=\(result.bpm)")
                }
            }
        }
    }

    private nonisolated func trackLookup(for entry: Playlist.Entry) -> GetSongBPMService.TrackLookup {
        if case .song(let song)? = entry.item {
            return GetSongBPMService.TrackLookup(
                appleMusicID: song.id.rawValue,
                isrc: song.isrc,
                title: song.title,
                artist: song.artistName
            )
        }

        return GetSongBPMService.TrackLookup(
            appleMusicID: entry.id.rawValue,
            isrc: entry.isrc,
            title: entry.title,
            artist: entry.artistName
        )
    }

    func togglePlayback(playbackRate: Double) async {
        guard currentTitle != nil else { return }
        do {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                try await player.play()
                isPlaying = true
                applyPlaybackRate(playbackRate)
                reapplyPlaybackRateAfterStartup()
            }
        } catch {
            errorMessage = "Apple Music 재생 상태를 변경할 수 없습니다"
            isPlaying = false
        }
    }

    func skipToNext(playbackRate: Double) async {
        await skip(direction: .next, playbackRate: playbackRate)
    }

    func skipToPrevious(playbackRate: Double) async {
        await skip(direction: .previous, playbackRate: playbackRate)
    }

    func toggleShuffle() {
        guard canShuffle else { return }
        setShuffleEnabled(!isShuffleEnabled)
    }

    func toggleRepeat() {
        guard canRepeat else { return }
        setRepeatEnabled(!isRepeatEnabled)
    }

    func stop() {
        player.stop()
        queueCancellable = nil
        stateCancellable = nil
        nowPlayingTask?.cancel()
        nowPlayingTask = nil
        currentSong = nil
        currentTitle = nil
        currentArtist = nil
        currentBPM = nil
        currentBPMSource = nil
        currentBeatOffsetSeconds = nil
        currentBeatTimesSeconds = []
        currentBeatAlignmentConfidence = nil
        currentBeatSyncStatus = .needsConfirmation
        currentBeatSyncIssue = .missingBPM
        bpmAnalysisTask?.cancel()
        bpmAnalysisTask = nil
        activePreviewAnalysisKey = nil
        canShuffle = false
        canRepeat = false
        setShuffleEnabled(false)
        setRepeatEnabled(false)
        isPlaying = false
        isLoading = false
    }

    func applyPlaybackRate(_ playbackRate: Double) {
        let clamped = min(max(playbackRate, Double(BPMRange.rateMin)), Double(BPMRange.rateMax))
        desiredPlaybackRate = Float(clamped)
        guard isPlaying || player.state.playbackStatus == .playing else { return }
        enforcePlaybackRate(reason: "requested")
    }

    @discardableResult
    func setManualBPM(_ bpm: Double) -> Bool {
        guard bpm.isFinite, bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else {
            errorMessage = "원본 BPM은 30~300 사이 숫자로 입력하세요"
            return false
        }
        guard let identity = currentBPMIdentity() else {
            errorMessage = "BPM을 저장할 곡 정보가 없습니다"
            return false
        }

        let result = StreamingBPMResult(
            bpm: bpm,
            source: .manual,
            beatOffsetSeconds: nil,
            beatTimesSeconds: nil,
            confidence: nil,
            beatSyncStatus: .bpmOnly,
            beatSyncIssue: .missingBeatGrid
        )
        cacheBPMResult(
            result,
            songID: identity.songID,
            title: identity.title,
            artist: identity.artist,
            albumTitle: identity.albumTitle
        )
        for key in overrideStoreKeys(for: identity) {
            bpmOverrideStore.store(bpm: bpm, forIdentity: key)
        }
        applyResolvedBPM(result)
        errorMessage = nil

        Task {
            await GetSongBPMService.shared.recordBPM(
                bpm,
                title: identity.title,
                artist: identity.artist,
                appleMusicID: identity.songID,
                isrc: identity.isrc
            )
        }
        return true
    }

    private enum SkipDirection {
        case next
        case previous
    }

    private func skip(direction: SkipDirection, playbackRate: Double) async {
        guard currentTitle != nil else { return }

        do {
            switch direction {
            case .next:
                try await player.skipToNextEntry()
            case .previous:
                try await player.skipToPreviousEntry()
            }

            syncPlaybackStatus()
            syncCurrentEntryFromQueue()
            applyPlaybackRate(playbackRate)
            reapplyPlaybackRateAfterStartup()
        } catch {
            errorMessage = direction == .next
                ? "다음 곡으로 넘어갈 수 없습니다"
                : "이전 곡으로 돌아갈 수 없습니다"
        }
    }

    private func startPlayerObservation() {
        nowPlayingTask?.cancel()

        queueCancellable = player.queue.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.syncCurrentEntryFromQueue()
            }
        }

        stateCancellable = player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.syncPlaybackStatus()
                self?.syncShuffleStatus()
                self?.syncRepeatStatus()
                self?.syncCurrentEntryFromQueue()
            }
        }

        nowPlayingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.syncPlaybackStatus()
                self?.syncShuffleStatus()
                self?.syncRepeatStatus()
                self?.syncCurrentEntryFromQueue()
                self?.enforcePlaybackRateIfPlaying(reason: "poll")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func syncCurrentEntryFromQueue() {
        guard let entry = player.queue.currentEntry else { return }
        currentTitle = entry.title
        currentArtist = artistName(for: entry) ?? entry.subtitle
        let resolvedBPM = bpm(for: entry)
        applyResolvedBPM(resolvedBPM)
        if resolvedBPM == nil {
            startPreviewBPMAnalysisIfNeeded(for: entry)
        }
        enforcePlaybackRateIfPlaying(reason: "queue-sync")
    }

    private func artistName(for entry: MusicKit.MusicPlayer.Queue.Entry) -> String? {
        if case .song(let song)? = entry.item {
            return song.artistName
        }

        if let song = entry.transientItem as? Song {
            return song.artistName
        }

        return entry.subtitle
    }

    private func bpm(for song: Song) -> StreamingBPMResult? {
        resolveBPM(
            songID: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            albumTitle: song.albumTitle
        )
    }

    private func bpm(for entry: Playlist.Entry) -> StreamingBPMResult? {
        if case .song(let song)? = entry.item {
            return bpm(for: song)
        }

        return resolveBPM(
            songID: entry.id.rawValue,
            title: entry.title,
            artist: entry.artistName,
            albumTitle: entry.albumTitle
        )
    }

    private func bpm(for entry: MusicKit.MusicPlayer.Queue.Entry) -> StreamingBPMResult? {
        if case .song(let song)? = entry.item {
            return bpm(for: song)
        }

        if let song = entry.transientItem as? Song {
            return bpm(for: song)
        }

        return resolveBPM(
            songID: entry.id,
            title: entry.title,
            artist: entry.subtitle,
            albumTitle: nil
        )
    }

    private func resolveBPM(
        songID: String?,
        title: String,
        artist: String?,
        albumTitle: String?
    ) -> StreamingBPMResult? {
        guard didBuildBPMCache else { return nil }

        if let songID, let bpm = bpmCacheByKey[storeKey(songID)] {
            return bpm
        }

        return bpmCacheByKey[metadataKey(title: title, artist: artist, albumTitle: albumTitle)]
            ?? bpmCacheByKey[metadataKey(title: title, artist: artist, albumTitle: nil)]
    }

    private func prepareBPMCacheIfPossible() async {
        guard !didBuildBPMCache else { return }

        let status = MPMediaLibrary.authorizationStatus()
        let authorizedStatus: MPMediaLibraryAuthorizationStatus
        if status == .notDetermined {
            authorizedStatus = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authorizedStatus = status
        }

        guard authorizedStatus == .authorized else {
            didBuildBPMCache = true
            return
        }

        var cache: [String: StreamingBPMResult] = [:]
        let items = MPMediaQuery.songs().items ?? []
        for item in items {
            let bpm = Double(item.beatsPerMinute)
            guard bpm > 0 else { continue }
            let result = StreamingBPMResult(
                bpm: bpm,
                source: .metadata,
                beatOffsetSeconds: nil,
                beatTimesSeconds: nil,
                confidence: nil,
                beatSyncStatus: .bpmOnly,
                beatSyncIssue: .missingBeatGrid
            )

            if !item.playbackStoreID.isEmpty {
                cache[storeKey(item.playbackStoreID)] = result
            }

            let title = item.title ?? ""
            guard !title.isEmpty else { continue }
            cache[metadataKey(title: title, artist: item.artist, albumTitle: item.albumTitle)] = result
            cache[metadataKey(title: title, artist: item.artist, albumTitle: nil)] = result
        }

        bpmCacheByKey = cache
        didBuildBPMCache = true
    }

    private func applyResolvedBPM(_ result: StreamingBPMResult?) {
        // 사용자가 이 곡에 대해 직접 저장한 BPM이 있으면 모든 자동 결정보다 우선.
        if let overrideBPM = currentTrackOverrideBPM() {
            currentBPMSource = .manual
            currentBPM = overrideBPM
            currentBeatOffsetSeconds = nil
            currentBeatTimesSeconds = []
            currentBeatAlignmentConfidence = nil
            currentBeatSyncStatus = .bpmOnly
            currentBeatSyncIssue = .missingBeatGrid
            return
        }

        currentBPMSource = result?.source
        currentBPM = result?.bpm
        currentBeatOffsetSeconds = result?.beatOffsetSeconds
        currentBeatTimesSeconds = result?.beatTimesSeconds ?? []
        currentBeatAlignmentConfidence = result?.confidence
        currentBeatSyncStatus = result?.beatSyncStatus ?? .needsConfirmation
        currentBeatSyncIssue = result?.beatSyncIssue ?? .missingBPM
    }

    private func currentTrackOverrideBPM() -> Double? {
        guard let identity = currentBPMIdentity() else { return nil }
        return overrideBPM(for: identity)
    }

    private func overrideBPM(
        for identity: (
            songID: String?,
            isrc: String?,
            title: String,
            artist: String?,
            albumTitle: String?
        )
    ) -> Double? {
        for key in overrideStoreKeys(for: identity) {
            if let bpm = bpmOverrideStore.bpm(forIdentity: key) {
                return bpm
            }
        }
        return nil
    }

    private func overrideStoreKeys(
        for identity: (
            songID: String?,
            isrc: String?,
            title: String,
            artist: String?,
            albumTitle: String?
        )
    ) -> [String] {
        var keys: [String] = []
        if let songID = identity.songID, !songID.isEmpty {
            keys.append(TrackBPMOverrideStore.identityKey(.appleMusic(songID: songID)))
        }
        keys.append(
            TrackBPMOverrideStore.identityKey(
                .fileMetadata(
                    title: identity.title,
                    artist: identity.artist,
                    lastPathComponent: identity.albumTitle ?? ""
                )
            )
        )
        return keys
    }

    private func startPreviewBPMAnalysisIfNeeded(for song: Song) {
        startPreviewBPMAnalysisIfNeeded(
            songID: song.id.rawValue,
            isrc: song.isrc,
            title: song.title,
            artist: song.artistName,
            albumTitle: song.albumTitle,
            previewAssets: song.previewAssets
        )
    }

    private func startPreviewBPMAnalysisIfNeeded(for entry: Playlist.Entry) {
        if case .song(let song)? = entry.item {
            startPreviewBPMAnalysisIfNeeded(for: song)
            return
        }

        startPreviewBPMAnalysisIfNeeded(
            songID: entry.id.rawValue,
            isrc: entry.isrc,
            title: entry.title,
            artist: entry.artistName,
            albumTitle: entry.albumTitle,
            previewAssets: entry.previewAssets
        )
    }

    private func startPreviewBPMAnalysisIfNeeded(for entry: MusicKit.MusicPlayer.Queue.Entry) {
        if case .song(let song)? = entry.item {
            startPreviewBPMAnalysisIfNeeded(for: song)
            return
        }

        if let song = entry.transientItem as? Song {
            startPreviewBPMAnalysisIfNeeded(for: song)
        }
    }

    private func startPreviewBPMAnalysisIfNeeded(
        songID: String?,
        isrc: String?,
        title: String,
        artist: String?,
        albumTitle: String?,
        previewAssets: [PreviewAsset]?
    ) {
        let identityKey = songID.map(storeKey) ?? metadataKey(title: title, artist: artist, albumTitle: albumTitle)
        let cachedResult = bpmCacheByKey[identityKey]
        let shouldTryGetSongBPM = !getSongBPMAttemptedKeys.contains(identityKey)
        guard cachedResult == nil || shouldTryGetSongBPM else { return }
        guard activePreviewAnalysisKey != identityKey else { return }
        guard shouldTryGetSongBPM || !failedPreviewAnalysisKeys.contains(identityKey) else { return }
        let previewAsset = previewAssets?.first(where: { $0.url != nil || $0.hlsURL != nil })
        let directPreviewURL = previewAsset?.url
        let hlsPreviewURL = previewAsset?.hlsURL

        activePreviewAnalysisKey = identityKey
        if shouldTryGetSongBPM {
            getSongBPMAttemptedKeys.insert(identityKey)
        }
        logger.info("[bpm_resolver] start title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public) tryGetSongBPM=\(shouldTryGetSongBPM) hasMusicKitPreview=\(previewAsset != nil)")
        bpmAnalysisTask?.cancel()
        bpmAnalysisTask = Task { @MainActor [weak self] in
            let resolver = StreamingBPMResolver(
                getSongBPM: { title, artist, _, isrc in
                    await GetSongBPMService.shared.lookupBPM(
                        title: title,
                        artist: artist,
                        appleMusicID: songID,
                        isrc: isrc
                    )
                },
                previewAnalysis: {
                    await PreviewBPMAnalyzer.shared.estimateBeatAlignment(
                        directURL: directPreviewURL,
                        hlsURL: hlsPreviewURL,
                        title: title,
                        artist: artist
                    )
                }
            )
            let resolution = await resolver.resolve(
                cachedResult: cachedResult,
                shouldTryGetSongBPM: shouldTryGetSongBPM,
                shouldTryPreviewAnalysis: cachedResult == nil,
                title: title,
                artist: artist,
                appleMusicID: songID,
                isrc: isrc
            )
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.activePreviewAnalysisKey = nil
            guard let result = resolution.result else {
                self.failedPreviewAnalysisKeys.insert(identityKey)
                self.logger.info("[bpm_resolver] failed title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public)")
                return
            }

            if let songID {
                self.bpmCacheByKey[self.storeKey(songID)] = result
            }
            self.bpmCacheByKey[self.metadataKey(title: title, artist: artist, albumTitle: albumTitle)] = result
            self.bpmCacheByKey[self.metadataKey(title: title, artist: artist, albumTitle: nil)] = result
            await GetSongBPMService.shared.recordBPM(
                result.bpm,
                title: title,
                artist: artist,
                appleMusicID: songID,
                isrc: isrc
            )

            if self.currentTitle == title && (artist == nil || self.currentArtist == artist) {
                self.applyResolvedBPM(result)
            }
            self.logger.info("[bpm_resolver] success bpm=\(result.bpm) source=\(result.source.badgeText, privacy: .public) title=\(title, privacy: .public)")
        }
    }

    private func cacheBPMResult(
        _ result: StreamingBPMResult,
        songID: String?,
        title: String,
        artist: String?,
        albumTitle: String?
    ) {
        if let songID {
            bpmCacheByKey[storeKey(songID)] = result
        }
        bpmCacheByKey[metadataKey(title: title, artist: artist, albumTitle: albumTitle)] = result
        bpmCacheByKey[metadataKey(title: title, artist: artist, albumTitle: nil)] = result
    }

    private func currentBPMIdentity() -> (
        songID: String?,
        isrc: String?,
        title: String,
        artist: String?,
        albumTitle: String?
    )? {
        if let currentSong {
            return (
                songID: currentSong.id.rawValue,
                isrc: currentSong.isrc,
                title: currentSong.title,
                artist: currentSong.artistName,
                albumTitle: currentSong.albumTitle
            )
        }

        if let entry = player.queue.currentEntry {
            if case .song(let song)? = entry.item {
                return (
                    songID: song.id.rawValue,
                    isrc: song.isrc,
                    title: song.title,
                    artist: song.artistName,
                    albumTitle: song.albumTitle
                )
            }

            if let song = entry.transientItem as? Song {
                return (
                    songID: song.id.rawValue,
                    isrc: song.isrc,
                    title: song.title,
                    artist: song.artistName,
                    albumTitle: song.albumTitle
                )
            }

            return (
                songID: entry.id,
                isrc: nil,
                title: entry.title,
                artist: artistName(for: entry) ?? entry.subtitle,
                albumTitle: nil
            )
        }

        guard let currentTitle else { return nil }
        return (
            songID: nil,
            isrc: nil,
            title: currentTitle,
            artist: currentArtist,
            albumTitle: nil
        )
    }

    private func reapplyPlaybackRateAfterStartup() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.enforcePlaybackRateIfPlaying(reason: "startup-delay")
            try? await Task.sleep(nanoseconds: 850_000_000)
            self?.enforcePlaybackRateIfPlaying(reason: "startup-delay-2")
        }
    }

    private func enforcePlaybackRateIfPlaying(reason: String) {
        guard isPlaying || player.state.playbackStatus == .playing else { return }
        enforcePlaybackRate(reason: reason)
    }

    private func enforcePlaybackRate(reason: String) {
        let before = player.state.playbackRate
        guard abs(before - desiredPlaybackRate) > 0.005 else { return }
        player.state.playbackRate = desiredPlaybackRate
        logger.info("[stream_rate] \(reason, privacy: .public) requested=\(self.desiredPlaybackRate) before=\(before) after=\(self.player.state.playbackRate)")
    }

    private func storeKey(_ id: String) -> String {
        "store:\(id)"
    }

    private func metadataKey(title: String, artist: String?, albumTitle: String?) -> String {
        [
            normalize(title),
            normalize(artist ?? ""),
            normalize(albumTitle ?? ""),
        ].joined(separator: "|")
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func syncPlaybackStatus() {
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward:
            isPlaying = true
        case .paused, .stopped, .interrupted:
            isPlaying = false
        @unknown default:
            isPlaying = false
        }
    }

    private func setShuffleEnabled(_ enabled: Bool) {
        player.state.shuffleMode = enabled ? .songs : .off
        syncShuffleStatus()
    }

    private func syncShuffleStatus() {
        isShuffleEnabled = player.state.shuffleMode == .songs
    }

    private func setRepeatEnabled(_ enabled: Bool) {
        player.state.repeatMode = enabled ? .all : MusicPlayer.RepeatMode.none
        syncRepeatStatus()
    }

    private func syncRepeatStatus() {
        isRepeatEnabled = player.state.repeatMode == .all || player.state.repeatMode == .one
    }

    private func ensureAuthorization() async -> MusicAuthorization.Status {
        let currentStatus = MusicAuthorization.currentStatus
        if currentStatus == .notDetermined {
            return await MusicAuthorization.request()
        }
        return currentStatus
    }
}

private final class PreviewExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

actor PreviewBPMAnalyzer {
    static let shared = PreviewBPMAnalyzer()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var cacheByURL: [URL: BeatAlignmentAnalysis] = [:]
    private var cacheByLookupKey: [String: BeatAlignmentAnalysis] = [:]
    private let logger = Logger(subsystem: "com.jy.cadenza", category: "PreviewBPM")

    init() {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenzaPreviewBPM", isDirectory: true)
    }

    func estimateBeatAlignment(
        directURL: URL?,
        hlsURL: URL?,
        title: String,
        artist: String?
    ) async -> BeatAlignmentAnalysis? {
        let lookupKey = metadataKey(title: title, artist: artist)
        if let cached = cacheByLookupKey[lookupKey] {
            return cached
        }

        if let directURL, let analysis = await estimateBeatAlignment(fromDirectURL: directURL) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        if let hlsURL, let analysis = await estimateBeatAlignment(fromHLSURL: hlsURL) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        if let fallbackURL = await findITunesPreviewURL(title: title, artist: artist),
           let analysis = await estimateBeatAlignment(fromDirectURL: fallbackURL) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        return nil
    }

    private func estimateBeatAlignment(fromDirectURL url: URL) async -> BeatAlignmentAnalysis? {
        if let cached = cacheByURL[url] {
            return cached
        }

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            let extensionHint = response.suggestedFilename
                .flatMap { URL(fileURLWithPath: $0).pathExtension }
            let pathExtension = extensionHint?.isEmpty == false ? extensionHint! : (url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
            let localURL = cacheDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)
            try? fileManager.removeItem(at: localURL)
            try fileManager.moveItem(at: temporaryURL, to: localURL)
            let analysis = await analyze(localURL: localURL)
            if let analysis {
                cacheByURL[url] = analysis
            }
            logger.info("[preview_bpm] direct analyzed bpm=\(analysis?.estimatedBPM ?? -1) offset=\(analysis?.beatOffsetSeconds ?? -1)s url=\(url.absoluteString, privacy: .public)")
            return analysis
        } catch {
            logger.info("[preview_bpm] direct failed url=\(url.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func estimateBeatAlignment(fromHLSURL url: URL) async -> BeatAlignmentAnalysis? {
        if let cached = cacheByURL[url] {
            return cached
        }

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let localURL = cacheDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try? fileManager.removeItem(at: localURL)

            let asset = AVURLAsset(url: url)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
                  exporter.supportedFileTypes.contains(.m4a) else {
                return nil
            }
            exporter.outputURL = localURL
            exporter.outputFileType = .m4a
            exporter.shouldOptimizeForNetworkUse = false

            let exportBox = PreviewExportSessionBox(exporter)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportBox.session.exportAsynchronously {
                    switch exportBox.session.status {
                    case .completed:
                        continuation.resume()
                    case .failed:
                        continuation.resume(throwing: exportBox.session.error ?? URLError(.cannotDecodeContentData))
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
            }

            let analysis = await analyze(localURL: localURL)
            if let analysis {
                cacheByURL[url] = analysis
            }
            logger.info("[preview_bpm] hls analyzed bpm=\(analysis?.estimatedBPM ?? -1) offset=\(analysis?.beatOffsetSeconds ?? -1)s url=\(url.absoluteString, privacy: .public)")
            return analysis
        } catch {
            logger.info("[preview_bpm] hls failed url=\(url.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func analyze(localURL: URL) async -> BeatAlignmentAnalysis? {
        await Task.detached(priority: .userInitiated) {
            try? BeatAlignmentAnalyzer.loadOrAnalyze(url: localURL, expectedBPM: nil).analysis
        }.value
    }

    private func findITunesPreviewURL(title: String, artist: String?) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: [artist, title].compactMap { $0 }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            let normalizedTitle = normalize(title)
            let normalizedArtist = normalize(artist ?? "")
            let exactMatch = response.results.first { result in
                normalize(result.trackName ?? "") == normalizedTitle &&
                (normalizedArtist.isEmpty || normalize(result.artistName ?? "") == normalizedArtist)
            }
            let candidate = exactMatch ?? response.results.first(where: { $0.previewUrl != nil })
            guard let previewURL = candidate?.previewUrl.flatMap(URL.init(string:)) else { return nil }
            logger.info("[preview_bpm] itunes fallback url=\(previewURL.absoluteString, privacy: .public) title=\(title, privacy: .public)")
            return previewURL
        } catch {
            logger.info("[preview_bpm] itunes fallback failed title=\(title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func metadataKey(title: String, artist: String?) -> String {
        "\(normalize(title))|\(normalize(artist ?? ""))"
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesSearchResult]
}

private struct ITunesSearchResult: Decodable {
    let artistName: String?
    let trackName: String?
    let previewUrl: String?
}
