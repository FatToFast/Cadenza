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

    var validated: StreamingBPMResult? {
        BPMRange.validatedOriginalBPM(bpm).map { _ in self }
    }
}

struct StreamingBPMResolution: Equatable, Sendable {
    let result: StreamingBPMResult?
    let didAttemptGetSongBPM: Bool
}

enum StreamingBPMPreloadDecision: Equatable, Sendable {
    case apply(StreamingBPMResult)
    case ignore(currentResult: StreamingBPMResult?)

    var nextPublishedResult: StreamingBPMResult? {
        switch self {
        case .apply(let result):
            return result
        case .ignore(let currentResult):
            return currentResult
        }
    }

    static func decide(
        currentResult: StreamingBPMResult?,
        delayedResult: StreamingBPMResult
    ) -> Self {
        guard let delayedResult = delayedResult.validated else {
            return .ignore(currentResult: currentResult)
        }

        switch currentResult?.source {
        case .analysis?, .manual?:
            return .ignore(currentResult: currentResult)
        default:
            return .apply(delayedResult)
        }
    }
}

struct PreviewAnalysisRetryPolicy: Equatable, Sendable {
    let maxAutomaticAttempts: Int
    private var failureCountsByIdentity: [String: Int] = [:]

    init(maxAutomaticAttempts: Int = 1) {
        self.maxAutomaticAttempts = max(0, maxAutomaticAttempts)
    }

    func shouldAttempt(identity: String) -> Bool {
        failureCountsByIdentity[identity, default: 0] < maxAutomaticAttempts
    }

    mutating func recordFailure(identity: String) {
        let currentCount = failureCountsByIdentity[identity, default: 0]
        guard currentCount < maxAutomaticAttempts else { return }
        failureCountsByIdentity[identity] = currentCount + 1
    }

    mutating func reset(identity: String) {
        failureCountsByIdentity.removeValue(forKey: identity)
    }
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
        forcePreviewAnalysis: Bool = false,
        title: String,
        artist: String?,
        appleMusicID: String?,
        isrc: String? = nil
    ) async -> StreamingBPMResolution {
        var externalResult: StreamingBPMResult?
        if shouldTryGetSongBPM,
           let external = await getSongBPM(title, artist, appleMusicID, isrc) {
            externalResult = StreamingBPMResult(
                bpm: external.bpm,
                source: .metadata,
                beatOffsetSeconds: nil,
                beatTimesSeconds: nil,
                confidence: nil,
                beatSyncStatus: .bpmOnly,
                beatSyncIssue: .missingBeatGrid
            ).validated
        }

        if !forcePreviewAnalysis, let externalResult {
            return StreamingBPMResolution(
                result: externalResult,
                didAttemptGetSongBPM: shouldTryGetSongBPM
            )
        }

        if forcePreviewAnalysis,
           shouldTryPreviewAnalysis,
           let analysis = await previewAnalysis() {
            if let previewResult = result(for: analysis).validated {
                return StreamingBPMResolution(
                    result: previewResult,
                    didAttemptGetSongBPM: shouldTryGetSongBPM
                )
            }

            return StreamingBPMResolution(
                result: externalResult ?? cachedResult?.validated,
                didAttemptGetSongBPM: shouldTryGetSongBPM
            )
        }

        if let externalResult {
            return StreamingBPMResolution(
                result: externalResult,
                didAttemptGetSongBPM: shouldTryGetSongBPM
            )
        }

        if let cachedResult = cachedResult?.validated {
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

        return StreamingBPMResolution(
            result: result(for: analysis).validated,
            didAttemptGetSongBPM: shouldTryGetSongBPM
        )
    }

    private func result(for analysis: BeatAlignmentAnalysis) -> StreamingBPMResult {
        let assessment = BeatSyncReliability.assess(
            originalBPM: analysis.estimatedBPM,
            confidence: analysis.confidence,
            beatTimesSeconds: analysis.beatTimesSeconds ?? []
        )
        return StreamingBPMResult(
            bpm: analysis.estimatedBPM,
            source: .analysis,
            beatOffsetSeconds: assessment.shouldUseBeatGrid ? analysis.beatOffsetSeconds : nil,
            beatTimesSeconds: assessment.shouldUseBeatGrid ? analysis.beatTimesSeconds : nil,
            confidence: analysis.confidence,
            beatSyncStatus: assessment.status,
            beatSyncIssue: assessment.issue
        )
    }
}

struct StreamingQueuePolicyContext: Sendable, Equatable {
    private(set) var isPlaylist: Bool
    private(set) var identity: String?

    static let empty = StreamingQueuePolicyContext(isPlaylist: false, identity: nil)

    static func song(identity: String?) -> StreamingQueuePolicyContext {
        StreamingQueuePolicyContext(
            isPlaylist: false,
            identity: QueueIdentityNormalizer.normalized(identity)
        )
    }

    static func playlist(identity: String?) -> StreamingQueuePolicyContext {
        StreamingQueuePolicyContext(
            isPlaylist: true,
            identity: QueueIdentityNormalizer.normalized(identity)
        )
    }

    mutating func replaceIdentity(_ identity: String?) {
        self.identity = QueueIdentityNormalizer.normalized(identity)
    }

    mutating func clearAfterFailure() {
        self = .empty
    }
}

@MainActor
final class StreamingQueueMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }

        waiters.removeFirst().resume()
    }
}

@MainActor
final class AppleMusicStreamingController: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentArtist: String?
    @Published private(set) var currentArtworkURL: URL?
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
    @Published private(set) var currentQueueIdentity: String?
    @Published private(set) var currentPlaylistName: String?
    @Published private(set) var currentPlaylistEntries: [Playlist.Entry] = []
    @Published private(set) var currentPlaylistEntryID: String?
    @Published private(set) var currentPlaylistIndex: Int?
    private(set) var isPlaylistQueueContext = false

    private let player = ApplicationMusicPlayer.shared
    private var queueCancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?
    private var nowPlayingTask: Task<Void, Never>?
    private var bpmAnalysisTask: Task<Void, Never>?
    private var activePreviewAnalysisKey: String?
    private var previewAnalysisRetryPolicy = PreviewAnalysisRetryPolicy(maxAutomaticAttempts: 1)
    private var getSongBPMAttemptedKeys: Set<String> = []
    private var bpmCacheByKey: [String: StreamingBPMResult] = [:]
    private var didBuildBPMCache = false
    private var desiredPlaybackRate: Float = 1.0
    private var queuePolicyContext = StreamingQueuePolicyContext.empty
    private var selectionGeneration = 0
    private var currentPlaylist: Playlist?
    private let queueMutationGate = StreamingQueueMutationGate()
    private var isQueueMutationInFlight = false
    private let logger = Logger(subsystem: "com.jy.cadenza", category: "AppleMusicStreaming")
    private let bpmOverrideStore: TrackBPMOverrideStore

    init(bpmOverrideStore: TrackBPMOverrideStore = .shared) {
        self.bpmOverrideStore = bpmOverrideStore
    }

    var hasSong: Bool {
        currentTitle != nil
    }

    var hasCurrentPlaylist: Bool {
        currentPlaylistName != nil && !currentPlaylistEntries.isEmpty
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

    func cachedBPMValue(for entry: Playlist.Entry) -> Double? {
        bpm(for: entry)?.bpm
    }

    private func beginExplicitSelection(
        context: StreamingQueuePolicyContext,
        song: Song?,
        title: String,
        artist: String?,
        artworkURL: URL?
    ) -> Int {
        selectionGeneration &+= 1
        let generation = selectionGeneration

        queueCancellable = nil
        stateCancellable = nil
        nowPlayingTask?.cancel()
        nowPlayingTask = nil
        bpmAnalysisTask?.cancel()
        bpmAnalysisTask = nil
        activePreviewAnalysisKey = nil

        applyQueuePolicyContext(context)
        currentSong = song
        currentTitle = title
        currentArtist = artist
        currentArtworkURL = artworkURL
        clearResolvedBPMState()
        isPlaying = false
        isLoading = true
        canShuffle = context.isPlaylist
        canRepeat = true
        isShuffleEnabled = false
        isRepeatEnabled = false
        errorMessage = nil
        return generation
    }

    private func failExplicitSelection(generation: Int, message: String) {
        guard generation == selectionGeneration else { return }

        player.stop()
        queueCancellable = nil
        stateCancellable = nil
        nowPlayingTask?.cancel()
        nowPlayingTask = nil
        bpmAnalysisTask?.cancel()
        bpmAnalysisTask = nil
        activePreviewAnalysisKey = nil

        var clearedContext = queuePolicyContext
        clearedContext.clearAfterFailure()
        applyQueuePolicyContext(clearedContext)
        currentSong = nil
        currentTitle = nil
        currentArtist = nil
        currentArtworkURL = nil
        clearResolvedBPMState()
        canShuffle = false
        canRepeat = false
        isShuffleEnabled = false
        isRepeatEnabled = false
        isPlaying = false
        isLoading = false
        errorMessage = message
    }

    private func applyQueuePolicyContext(_ context: StreamingQueuePolicyContext) {
        queuePolicyContext = context
        currentQueueIdentity = context.identity
        isPlaylistQueueContext = context.isPlaylist
    }

    private func clearResolvedBPMState() {
        currentBPM = nil
        currentBPMSource = nil
        currentBeatOffsetSeconds = nil
        currentBeatTimesSeconds = []
        currentBeatAlignmentConfidence = nil
        currentBeatSyncStatus = .needsConfirmation
        currentBeatSyncIssue = .missingBPM
    }

    private func clearCurrentPlaylistSession() {
        currentPlaylist = nil
        currentPlaylistName = nil
        currentPlaylistEntries = []
        currentPlaylistEntryID = nil
        currentPlaylistIndex = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func play(_ song: Song, playbackRate: Double) async {
        clearCurrentPlaylistSession()
        let generation = beginExplicitSelection(
            context: .song(identity: storeKey(song.id.rawValue)),
            song: song,
            title: song.title,
            artist: song.artistName,
            artworkURL: song.artwork?.url(width: 600, height: 600)
        )

        await queueMutationGate.acquire()
        defer { queueMutationGate.release() }
        guard generation == selectionGeneration else { return }
        player.stop()

        let status = await ensureAuthorization()
        guard generation == selectionGeneration else { return }
        guard status == .authorized else {
            failExplicitSelection(
                generation: generation,
                message: "Apple Music 스트리밍 권한이 필요합니다"
            )
            return
        }
        await prepareBPMCacheIfPossible()
        guard generation == selectionGeneration else { return }

        do {
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
            guard generation == selectionGeneration else { return }
            applyPlaybackRate(playbackRate)
            try await player.play()
            guard StreamingPlayCompletionGuard.commitIfCurrent(
                startedGeneration: generation,
                currentGeneration: selectionGeneration,
                stopStalePlayback: { player.stop() },
                commitCurrentPlayback: {
                    isPlaying = true
                    enforcePlaybackRate(reason: "song-play-started")
                    reapplyPlaybackRateAfterStartup()
                }
            ) else { return }
        } catch {
            failExplicitSelection(
                generation: generation,
                message: "Apple Music 스트리밍을 시작할 수 없습니다: \(error.localizedDescription)"
            )
            return
        }

        if generation == selectionGeneration {
            isLoading = false
        }
    }

    func play(
        playlist: Playlist,
        startingAt entry: Playlist.Entry,
        playbackRate: Double,
        preloadedEntries: [Playlist.Entry] = []
    ) async {
        guard let plan = StreamingPlaylistSelectionPlan.make(
            entryIDs: preloadedEntries.map { $0.id.rawValue },
            selectedEntryID: entry.id.rawValue
        ) else {
            errorMessage = "선택한 곡을 현재 플레이리스트에서 찾을 수 없습니다"
            return
        }

        await playPlaylistEntries(
            playlist: playlist,
            entries: preloadedEntries,
            plan: plan,
            playbackRate: playbackRate
        )
    }

    func playCurrentPlaylistEntry(
        _ entry: Playlist.Entry,
        playbackRate: Double
    ) async {
        guard let currentPlaylist,
              let plan = StreamingPlaylistSelectionPlan.make(
                entryIDs: currentPlaylistEntries.map { $0.id.rawValue },
                selectedEntryID: entry.id.rawValue
              ) else {
            errorMessage = "선택한 곡을 현재 플레이리스트에서 찾을 수 없습니다"
            return
        }

        await playPlaylistEntries(
            playlist: currentPlaylist,
            entries: currentPlaylistEntries,
            plan: plan,
            playbackRate: playbackRate
        )
    }

    private func playPlaylistEntries(
        playlist: Playlist,
        entries: [Playlist.Entry],
        plan: StreamingPlaylistSelectionPlan,
        playbackRate: Double
    ) async {
        guard entries.indices.contains(plan.selectedIndex) else {
            errorMessage = "선택한 곡을 현재 플레이리스트에서 찾을 수 없습니다"
            return
        }
        let selectedEntry = entries[plan.selectedIndex]

        currentPlaylist = playlist
        currentPlaylistName = playlist.name
        currentPlaylistEntries = entries
        currentPlaylistEntryID = selectedEntry.id.rawValue
        currentPlaylistIndex = plan.selectedIndex

        let generation = beginExplicitSelection(
            context: .playlist(identity: queueIdentity(for: selectedEntry)),
            song: nil,
            title: selectedEntry.title,
            artist: selectedEntry.artistName,
            artworkURL: selectedEntry.artwork?.url(width: 600, height: 600)
        )

        await queueMutationGate.acquire()
        defer { queueMutationGate.release() }
        guard generation == selectionGeneration else { return }
        player.stop()

        let status = await ensureAuthorization()
        guard generation == selectionGeneration else { return }
        guard status == .authorized else {
            failExplicitSelection(
                generation: generation,
                message: "Apple Music 스트리밍 권한이 필요합니다"
            )
            return
        }
        await prepareBPMCacheIfPossible()
        guard generation == selectionGeneration else { return }
        await seedBPMCacheFromPrefetchedLookups(entries)
        guard generation == selectionGeneration else { return }
        startPlaylistBPMPreload(entries)

        do {
            applyResolvedBPM(bpm(for: selectedEntry))
            startPreviewBPMAnalysisIfNeeded(for: selectedEntry)
            canShuffle = true
            canRepeat = true
            setShuffleEnabled(false)
            setRepeatEnabled(false)
            let queue = ApplicationMusicPlayer.Queue(
                playlist: playlist,
                startingAt: selectedEntry
            )
            player.queue = queue
            try await player.prepareToPlay()
            guard generation == selectionGeneration else { return }
            let preparedQueue = player.queue
            let actualIndex = preparedQueue.currentEntry.flatMap { currentEntry in
                preparedQueue.entries.firstIndex(where: { $0.id == currentEntry.id }).map {
                    preparedQueue.entries.distance(
                        from: preparedQueue.entries.startIndex,
                        to: $0
                    )
                }
            }
            guard StreamingQueueStartVerifier.matches(
                expectedIndex: plan.selectedIndex,
                actualIndex: actualIndex
            ) else {
                failExplicitSelection(
                    generation: generation,
                    message: "선택한 곡을 재생 대기열에 설정하지 못했습니다"
                )
                return
            }
            syncCurrentEntryFromQueue()
            startPlayerObservation()
            applyPlaybackRate(playbackRate)
            try await player.play()
            guard StreamingPlayCompletionGuard.commitIfCurrent(
                startedGeneration: generation,
                currentGeneration: selectionGeneration,
                stopStalePlayback: { player.stop() },
                commitCurrentPlayback: {
                    isPlaying = true
                    enforcePlaybackRate(reason: "playlist-play-started")
                    reapplyPlaybackRateAfterStartup()
                }
            ) else { return }
        } catch {
            failExplicitSelection(
                generation: generation,
                message: "Apple Music 플레이리스트를 재생할 수 없습니다: \(error.localizedDescription)"
            )
            return
        }

        if generation == selectionGeneration {
            isLoading = false
        }
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
                    }
                    continue
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let delayedResult = StreamingBPMResult(
                        bpm: result.bpm,
                        source: .metadata,
                        beatOffsetSeconds: nil,
                        beatTimesSeconds: nil,
                        confidence: nil,
                        beatSyncStatus: .bpmOnly,
                        beatSyncIssue: .missingBeatGrid
                    )
                    let entryIdentity = self.queueIdentity(for: entry)
                    let isCurrentEntry = self.currentQueueIdentity == entryIdentity
                    let decision = StreamingBPMPreloadDecision.decide(
                        currentResult: isCurrentEntry
                            ? self.publishedBPMResult
                            : nil,
                        delayedResult: delayedResult
                    )
                    if isCurrentEntry {
                        self.applyResolvedBPM(decision.nextPublishedResult)
                    }
                    guard case .apply(let bpmResult) = decision else { return }
                    self.cacheBPMResult(
                        bpmResult,
                        songID: lookup.appleMusicID,
                        title: entry.title,
                        artist: entry.artistName,
                        albumTitle: entry.albumTitle
                    )
                    self.logger.notice("[bpm_preload] success title=\(entry.title, privacy: .public) artist=\(entry.artistName, privacy: .public) bpm=\(result.bpm)")
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
        let generation = selectionGeneration
        await queueMutationGate.acquire()
        defer { queueMutationGate.release() }
        guard generation == selectionGeneration, currentTitle != nil else { return }

        do {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                try await player.play()
                guard StreamingPlayCompletionGuard.commitIfCurrent(
                    startedGeneration: generation,
                    currentGeneration: selectionGeneration,
                    stopStalePlayback: { player.stop() },
                    commitCurrentPlayback: {
                        isPlaying = true
                        applyPlaybackRate(playbackRate)
                        reapplyPlaybackRateAfterStartup()
                    }
                ) else { return }
            }
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = "Apple Music 재생 상태를 변경할 수 없습니다"
            isPlaying = false
        }
    }

    @discardableResult
    func skipToNext(
        playbackRate: Double,
        expectedIdentity: String? = nil,
        validateBeforeSkip: @MainActor () -> Bool = { true }
    ) async -> Bool {
        await skip(
            direction: .next,
            playbackRate: playbackRate,
            expectedIdentity: expectedIdentity,
            validateBeforeSkip: validateBeforeSkip
        )
    }

    func skipToPrevious(playbackRate: Double) async {
        _ = await skip(
            direction: .previous,
            playbackRate: playbackRate,
            expectedIdentity: nil,
            validateBeforeSkip: { true }
        )
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
        selectionGeneration &+= 1
        player.stop()
        queueCancellable = nil
        stateCancellable = nil
        nowPlayingTask?.cancel()
        nowPlayingTask = nil
        currentSong = nil
        clearCurrentPlaylistSession()
        applyQueuePolicyContext(.empty)
        currentTitle = nil
        currentArtist = nil
        currentArtworkURL = nil
        clearResolvedBPMState()
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

    func pause() {
        guard isPlaying || player.state.playbackStatus == .playing else { return }
        player.pause()
        isPlaying = false
    }

    func applyPlaybackRate(_ playbackRate: Double) {
        let clamped = min(max(playbackRate, Double(BPMRange.rateMin)), Double(BPMRange.rateMax))
        desiredPlaybackRate = Float(clamped)
        guard isPlaying || player.state.playbackStatus == .playing else { return }
        enforcePlaybackRate(reason: "requested")
    }

    @discardableResult
    func setManualBPM(_ bpm: Double) -> Bool {
        guard let bpm = BPMRange.validatedOriginalBPM(bpm) else {
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

    @discardableResult
    func retryCurrentBPMAnalysis() -> Bool {
        guard currentBPMSource != .manual, currentTrackOverrideBPM() == nil else {
            return false
        }

        if let currentSong {
            return retryPreviewBPMAnalysis(for: currentSong)
        }

        guard let entry = player.queue.currentEntry else { return false }
        return retryPreviewBPMAnalysis(for: entry)
    }

    private enum SkipDirection {
        case next
        case previous
    }

    private func skip(
        direction: SkipDirection,
        playbackRate: Double,
        expectedIdentity: String?,
        validateBeforeSkip: @MainActor () -> Bool
    ) async -> Bool {
        guard currentTitle != nil else { return false }
        let snapshot = StreamingQueueCommandSnapshot(
            selectionGeneration: selectionGeneration,
            expectedIdentity: expectedIdentity
        )
        if expectedIdentity != nil, snapshot.expectedIdentity == nil {
            return false
        }

        await queueMutationGate.acquire()
        defer { queueMutationGate.release() }
        guard currentTitle != nil,
              snapshot.isCurrent(
                selectionGeneration: selectionGeneration,
                currentIdentity: currentQueueIdentity
              ),
              validateBeforeSkip() else { return false }

        isQueueMutationInFlight = true
        defer { isQueueMutationInFlight = false }

        do {
            switch direction {
            case .next:
                try await player.skipToNextEntry()
            case .previous:
                try await player.skipToPreviousEntry()
            }

            guard snapshot.isCurrent(
                selectionGeneration: selectionGeneration,
                currentIdentity: currentQueueIdentity
            ) else { return false }

            isQueueMutationInFlight = false
            syncPlaybackStatus()
            syncCurrentEntryFromQueue()
            applyPlaybackRate(playbackRate)
            reapplyPlaybackRateAfterStartup()
            return true
        } catch {
            guard snapshot.isCurrent(
                selectionGeneration: selectionGeneration,
                currentIdentity: currentQueueIdentity
            ) else { return false }
            errorMessage = direction == .next
                ? "다음 곡으로 넘어갈 수 없습니다"
                : "이전 곡으로 돌아갈 수 없습니다"
            return false
        }
    }

    private func startPlayerObservation() {
        nowPlayingTask?.cancel()
        let generation = selectionGeneration

        queueCancellable = player.queue.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.selectionGeneration == generation else { return }
                self.syncCurrentEntryFromQueue()
            }
        }

        stateCancellable = player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.selectionGeneration == generation else { return }
                self.syncPlaybackStatus()
                self.syncShuffleStatus()
                self.syncRepeatStatus()
                self.syncCurrentEntryFromQueue()
            }
        }

        nowPlayingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.selectionGeneration == generation else { return }
                self.syncPlaybackStatus()
                self.syncShuffleStatus()
                self.syncRepeatStatus()
                self.syncCurrentEntryFromQueue()
                self.enforcePlaybackRateIfPlaying(reason: "poll")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func syncCurrentEntryFromQueue() {
        guard !isQueueMutationInFlight else { return }
        guard let entry = player.queue.currentEntry else { return }
        syncCurrentPlaylistPosition(from: entry)
        var context = queuePolicyContext
        context.replaceIdentity(queueIdentity(for: entry))
        applyQueuePolicyContext(context)
        currentTitle = entry.title
        currentArtist = artistName(for: entry) ?? entry.subtitle
        currentArtworkURL = artworkURL(for: entry)
        let resolvedBPM = bpm(for: entry)
        applyResolvedBPM(resolvedBPM)
        if resolvedBPM == nil {
            startPreviewBPMAnalysisIfNeeded(for: entry)
        }
        enforcePlaybackRateIfPlaying(reason: "queue-sync")
    }

    private func syncCurrentPlaylistPosition(
        from entry: MusicKit.MusicPlayer.Queue.Entry
    ) {
        guard isPlaylistQueueContext, !currentPlaylistEntries.isEmpty else { return }
        let queueEntries = player.queue.entries
        guard let queueIndex = queueEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        let observedIndex = queueEntries.distance(
            from: queueEntries.startIndex,
            to: queueIndex
        )
        guard currentPlaylistEntries.indices.contains(observedIndex) else { return }

        currentPlaylistIndex = observedIndex
        currentPlaylistEntryID = currentPlaylistEntries[observedIndex].id.rawValue
    }

    private func artworkURL(for entry: MusicKit.MusicPlayer.Queue.Entry) -> URL? {
        if case .song(let song)? = entry.item {
            return song.artwork?.url(width: 600, height: 600)
        }
        if let song = entry.transientItem as? Song {
            return song.artwork?.url(width: 600, height: 600)
        }
        return entry.artwork?.url(width: 600, height: 600)
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

        if let songID,
           let bpm = bpmCacheByKey[storeKey(songID)]?.validated {
            return bpm
        }

        if let bpm = bpmCacheByKey[
            metadataKey(title: title, artist: artist, albumTitle: albumTitle)
        ]?.validated {
            return bpm
        }

        return bpmCacheByKey[
            metadataKey(title: title, artist: artist, albumTitle: nil)
        ]?.validated
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
            guard let bpm = BPMRange.validatedOriginalBPM(Double(item.beatsPerMinute)) else {
                continue
            }
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

        let validatedResult = result?.validated
        currentBPMSource = validatedResult?.source
        currentBPM = validatedResult?.bpm
        currentBeatOffsetSeconds = validatedResult?.beatOffsetSeconds
        currentBeatTimesSeconds = validatedResult?.beatTimesSeconds ?? []
        currentBeatAlignmentConfidence = validatedResult?.confidence
        currentBeatSyncStatus = validatedResult?.beatSyncStatus ?? .needsConfirmation
        currentBeatSyncIssue = validatedResult?.beatSyncIssue ?? .missingBPM
    }

    private var publishedBPMResult: StreamingBPMResult? {
        guard let bpm = currentBPM,
              let source = currentBPMSource else { return nil }
        return StreamingBPMResult(
            bpm: bpm,
            source: source,
            beatOffsetSeconds: currentBeatOffsetSeconds,
            beatTimesSeconds: currentBeatTimesSeconds,
            confidence: currentBeatAlignmentConfidence,
            beatSyncStatus: currentBeatSyncStatus,
            beatSyncIssue: currentBeatSyncIssue
        ).validated
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

    private func retryPreviewBPMAnalysis(for song: Song) -> Bool {
        let identityKey = previewAnalysisIdentityKey(
            songID: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            albumTitle: song.albumTitle
        )
        preparePreviewBPMRetry(identityKey: identityKey)
        startPreviewBPMAnalysisIfNeeded(for: song, forcePreviewAnalysis: true)
        return true
    }

    private func retryPreviewBPMAnalysis(for entry: MusicKit.MusicPlayer.Queue.Entry) -> Bool {
        if case .song(let song)? = entry.item {
            return retryPreviewBPMAnalysis(for: song)
        }
        if let song = entry.transientItem as? Song {
            return retryPreviewBPMAnalysis(for: song)
        }

        let identityKey = previewAnalysisIdentityKey(
            songID: entry.id,
            title: entry.title,
            artist: artistName(for: entry) ?? entry.subtitle,
            albumTitle: nil
        )
        preparePreviewBPMRetry(identityKey: identityKey)
        startPreviewBPMAnalysisIfNeeded(for: entry, forcePreviewAnalysis: true)
        return true
    }

    private func preparePreviewBPMRetry(identityKey: String) {
        previewAnalysisRetryPolicy.reset(identity: identityKey)
        getSongBPMAttemptedKeys.remove(identityKey)
        bpmAnalysisTask?.cancel()
        bpmAnalysisTask = nil
        activePreviewAnalysisKey = nil
        errorMessage = nil
    }

    private func startPreviewBPMAnalysisIfNeeded(
        for song: Song,
        forcePreviewAnalysis: Bool = false
    ) {
        startPreviewBPMAnalysisIfNeeded(
            songID: song.id.rawValue,
            isrc: song.isrc,
            title: song.title,
            artist: song.artistName,
            albumTitle: song.albumTitle,
            previewAssets: song.previewAssets,
            forcePreviewAnalysis: forcePreviewAnalysis
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

    private func startPreviewBPMAnalysisIfNeeded(
        for entry: MusicKit.MusicPlayer.Queue.Entry,
        forcePreviewAnalysis: Bool = false
    ) {
        if case .song(let song)? = entry.item {
            startPreviewBPMAnalysisIfNeeded(
                for: song,
                forcePreviewAnalysis: forcePreviewAnalysis
            )
            return
        }

        if let song = entry.transientItem as? Song {
            startPreviewBPMAnalysisIfNeeded(
                for: song,
                forcePreviewAnalysis: forcePreviewAnalysis
            )
            return
        }

        startPreviewBPMAnalysisIfNeeded(
            songID: entry.id,
            isrc: nil,
            title: entry.title,
            artist: artistName(for: entry) ?? entry.subtitle,
            albumTitle: nil,
            previewAssets: nil,
            forcePreviewAnalysis: forcePreviewAnalysis
        )
    }

    private func startPreviewBPMAnalysisIfNeeded(
        songID: String?,
        isrc: String?,
        title: String,
        artist: String?,
        albumTitle: String?,
        previewAssets: [PreviewAsset]?,
        forcePreviewAnalysis: Bool = false
    ) {
        let identityKey = previewAnalysisIdentityKey(
            songID: songID,
            title: title,
            artist: artist,
            albumTitle: albumTitle
        )
        let cachedResult = bpmCacheByKey[identityKey]?.validated
        let shouldTryGetSongBPM = !getSongBPMAttemptedKeys.contains(identityKey)
        let shouldTryPreviewAnalysis = forcePreviewAnalysis
            || (cachedResult == nil && previewAnalysisRetryPolicy.shouldAttempt(identity: identityKey))
        guard cachedResult == nil || shouldTryGetSongBPM || shouldTryPreviewAnalysis else { return }
        guard activePreviewAnalysisKey != identityKey else { return }
        guard shouldTryGetSongBPM || shouldTryPreviewAnalysis else { return }
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
                        artist: artist,
                        forceRefresh: forcePreviewAnalysis
                    )
                }
            )
            let resolution = await resolver.resolve(
                cachedResult: cachedResult,
                shouldTryGetSongBPM: shouldTryGetSongBPM,
                shouldTryPreviewAnalysis: shouldTryPreviewAnalysis,
                forcePreviewAnalysis: forcePreviewAnalysis,
                title: title,
                artist: artist,
                appleMusicID: songID,
                isrc: isrc
            )
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.activePreviewAnalysisKey = nil
            guard let result = resolution.result else {
                self.previewAnalysisRetryPolicy.recordFailure(identity: identityKey)
                self.logger.info("[bpm_resolver] failed title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public)")
                return
            }

            self.cacheBPMResult(
                result,
                songID: songID,
                title: title,
                artist: artist,
                albumTitle: albumTitle
            )
            await GetSongBPMService.shared.recordBPM(
                result.bpm,
                title: title,
                artist: artist,
                appleMusicID: songID,
                isrc: isrc
            )

            if self.currentQueueIdentity == identityKey {
                self.applyResolvedBPM(result)
            }
            self.logger.info("[bpm_resolver] success bpm=\(result.bpm) source=\(result.source.badgeText, privacy: .public) title=\(title, privacy: .public)")
        }
    }

    private func previewAnalysisIdentityKey(
        songID: String?,
        title: String,
        artist: String?,
        albumTitle: String?
    ) -> String {
        songID.map(storeKey)
            ?? metadataKey(title: title, artist: artist, albumTitle: albumTitle)
    }

    private func cacheBPMResult(
        _ result: StreamingBPMResult,
        songID: String?,
        title: String,
        artist: String?,
        albumTitle: String?
    ) {
        guard let result = result.validated else { return }
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

        if let currentPlaylistIndex,
           currentPlaylistEntries.indices.contains(currentPlaylistIndex) {
            let playlistEntry = currentPlaylistEntries[currentPlaylistIndex]
            if case .song(let song)? = playlistEntry.item {
                return (
                    songID: song.id.rawValue,
                    isrc: song.isrc,
                    title: song.title,
                    artist: song.artistName,
                    albumTitle: song.albumTitle
                )
            }

            return (
                songID: playlistEntry.id.rawValue,
                isrc: playlistEntry.isrc,
                title: playlistEntry.title,
                artist: playlistEntry.artistName,
                albumTitle: playlistEntry.albumTitle
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

    private func queueIdentity(for entry: MusicKit.MusicPlayer.Queue.Entry) -> String? {
        if case .song(let song)? = entry.item {
            return storeKey(song.id.rawValue)
        }
        if let song = entry.transientItem as? Song {
            return storeKey(song.id.rawValue)
        }
        let entryID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entryID.isEmpty else { return nil }
        return storeKey(entryID)
    }

    private func queueIdentity(for entry: Playlist.Entry) -> String? {
        if case .song(let song)? = entry.item {
            return storeKey(song.id.rawValue)
        }
        let entryID = entry.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entryID.isEmpty else { return nil }
        return storeKey(entryID)
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
        artist: String?,
        forceRefresh: Bool = false
    ) async -> BeatAlignmentAnalysis? {
        let lookupKey = metadataKey(title: title, artist: artist)
        if !forceRefresh, let cached = cacheByLookupKey[lookupKey] {
            return cached
        }

        if let directURL,
           let analysis = await estimateBeatAlignment(
                fromDirectURL: directURL,
                forceRefresh: forceRefresh
           ) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        if let hlsURL,
           let analysis = await estimateBeatAlignment(
                fromHLSURL: hlsURL,
                forceRefresh: forceRefresh
           ) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        if let fallbackURL = await findITunesPreviewURL(title: title, artist: artist),
           let analysis = await estimateBeatAlignment(
                fromDirectURL: fallbackURL,
                forceRefresh: forceRefresh
           ) {
            cacheByLookupKey[lookupKey] = analysis
            return analysis
        }

        return nil
    }

    private func estimateBeatAlignment(
        fromDirectURL url: URL,
        forceRefresh: Bool = false
    ) async -> BeatAlignmentAnalysis? {
        if !forceRefresh, let cached = cacheByURL[url] {
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

    private func estimateBeatAlignment(
        fromHLSURL url: URL,
        forceRefresh: Bool = false
    ) async -> BeatAlignmentAnalysis? {
        if !forceRefresh, let cached = cacheByURL[url] {
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
