import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.cadenza.app", category: "AudioManager")

enum SampleTrackPreset: String, CaseIterable, Identifiable {
    case clickLoop
    case synthPulse
    case warmupGroove
    case kickdrumRocket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clickLoop:
            return "클릭 루프"
        case .synthPulse:
            return "신스 펄스"
        case .warmupGroove:
            return "워밍업 그루브"
        case .kickdrumRocket:
            return "Kickdrum"
        }
    }

    var artist: String {
        switch self {
        case .kickdrumRocket:
            return "Bundled MP3"
        default:
            return "Built-in Sample"
        }
    }

    var bpm: Double {
        switch self {
        case .clickLoop:
            return 120
        case .synthPulse:
            return 160
        case .warmupGroove:
            return 180
        case .kickdrumRocket:
            return 180
        }
    }

    var filename: String {
        switch self {
        case .kickdrumRocket:
            return "Kickdrum Rocket-2.mp3"
        default:
            return "Cadenza-\(rawValue).wav"
        }
    }

    var isBundledFile: Bool {
        self == .kickdrumRocket
    }
}

// MARK: - AudioManager

/// AVAudioEngine 래핑. 앱의 오디오 재생 전체를 관리한다.
///
/// Node graph (SPEC.md 1.6):
///   PlayerNode → TimePitch → MainMixer → Output
///
/// 루핑: completion handler 재스케줄 방식 (Eng Review 결정)
/// 소유: 앱 루트에서 @StateObject로 생성 (Eng Review 결정)
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: PlaybackState = .idle
    @Published var targetBPM: Double = BPMRange.targetDefault {
        didSet {
            updateRate()
            restartMetronomeIfNeeded()
        }
    }
    @Published private(set) var originalBPM: Double = BPMRange.originalDefault
    @Published private(set) var originalBPMSource: OriginalBPMSource = .assumedDefault
    @Published private(set) var trackTitle: String?
    @Published private(set) var trackArtist: String?
    @Published private(set) var currentArtworkData: Data?
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPlaybackTime: TimeInterval = 0
    @Published private(set) var trackDuration: TimeInterval = 0
    @Published private(set) var beatAlignmentConfidence: Double?
    @Published private(set) var beatAlignmentCacheStatus: BeatAlignmentCacheStatus = .none
    @Published private(set) var beatSyncStatus: BeatSyncStatus = .needsConfirmation
    @Published private(set) var beatSyncIssue: BeatSyncReliabilityIssue? = .missingBPM
    @Published private(set) var manualBeatOffsetNudge: TimeInterval = 0
    @Published var metronomeEnabled: Bool = MetronomeDefaults.enabled {
        didSet { handleMetronomeEnabledChange() }
    }
    @Published var metronomeVolume: Float = MetronomeDefaults.volume {
        didSet { metronomeNode.volume = metronomeVolume }
    }

    var playbackRate: Double {
        guard originalBPM > 0 else { return 1.0 }
        let rate = targetBPM / originalBPM
        return min(max(rate, Double(BPMRange.rateMin)), Double(BPMRange.rateMax))
    }

    var metronomeBPM: Double {
        BPMRange.metronomeCadence(forTargetBPM: targetBPM)
    }

    var hasBPMFromMetadata: Bool { _bpmFromMetadata }
    var hasLoadedTrack: Bool { audioFile != nil }
    var canStartPlayback: Bool { audioFile != nil || canRunMetronomeForCurrentBeatSync }
    var needsOriginalBPMInput: Bool { audioFile != nil && originalBPMSource == .assumedDefault }
    var playbackProgress: Double {
        guard trackDuration > 0 else { return 0 }
        return min(max(currentPlaybackTime / trackDuration, 0), 1)
    }
    var hasBeatAlignmentAnalysis: Bool { beatAlignmentAnalysis != nil }
    /// 메트로놈을 동작시킬 수 있는 조건. BPM이 잡혔으면 (`bpmOnly`도 포함) 균등 간격
    /// 클릭은 가능하다. `needsConfirmation`은 BPM 자체가 미확정이라 막는다.
    /// grid 기반 정렬은 별도로 `beatSyncStatus.usesBeatGrid`만 본다.
    var canRunMetronomeForCurrentBeatSync: Bool {
        metronomeEnabled && beatSyncStatus.allowsMetronome
    }
    var effectiveBeatOffset: TimeInterval {
        let beatDuration = 60.0 / max(originalBPM, 1)
        return BeatOffsetAdjustment.effectiveOffset(
            detectedOffset: beatAlignmentAnalysis?.beatOffsetSeconds ?? 0,
            manualNudge: manualBeatOffsetNudge,
            beatDuration: beatDuration
        )
    }
    var isMetronomeOnlyMode: Bool {
        audioFile == nil && (state == .playing || state == .paused) && metronomeEnabled
    }

    var currentNowPlayingInfo: NowPlayingInfo {
        NowPlayingInfo(
            title: trackTitle, artist: trackArtist,
            originalBPM: originalBPM, originalBPMSource: originalBPMSource,
            playbackProgress: trackDuration > 0 ? currentPlaybackTime / trackDuration : 0,
            playbackDuration: trackDuration,
            queueContext: nil
        )
    }

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let metronomeNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var beatAlignmentAnalysis: BeatAlignmentAnalysis?
    private var _bpmFromMetadata = false
    private var hasScheduledPlayback = false
    private var isScheduling = false
    private var scheduledLoopStartFrame: AVAudioFramePosition = 0
    private var currentScheduledStartFrame: AVAudioFramePosition = 0
    private var sourceBeatOffsetSeconds: TimeInterval = 0
    private var sourceBeatTimesSeconds: [TimeInterval] = []
    private var metronomeBeatIndex = 0
    private var metronomeScheduledBeats = 0
    private var metronomeNextBeatGridIndex: Int?
    private var isMetronomeRunning = false
    private var isExternalMetronomePlaybackActive = false
    private let metronomeLookaheadBeats = 4
    private let metronomeFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            fatalError("[M-01] Standard mono 44.1kHz format unavailable on this device")
        }
        return format
    }()
    private var accentBeatBuffer: AVAudioPCMBuffer?
    private var regularBeatBuffer: AVAudioPCMBuffer?

    /// 현재 로드된 파일의 security-scoped URL.
    /// 트랙 수명 동안 권한을 유지하고, 새 파일 로드 또는 해제 시 반납한다.
    private var currentAccessedURL: URL?
    private var currentTrackURL: URL?
    private var currentTrackOverrideKey: String?
    private let bpmOverrideStore: TrackBPMOverrideStore
    private var isAudioSessionConfigured = false
    private var progressTimer: Timer?
    private var pendingPresetBPMHint: Double?
    private var cachedMetronomeDelay: TimeInterval?
    private var trackGeneration: Int = 0
    let trackEndedSubject = PassthroughSubject<Void, Never>()
    @Published var playbackEndBehavior: PlaybackEndBehavior = .loop
    @Published private(set) var localPlaylist = LocalFilePlaylist()
    @Published var localRepeatEnabled: Bool = false {
        didSet { syncPlaybackEndBehavior() }
    }

    // MARK: - Init

    init(bpmOverrideStore: TrackBPMOverrideStore = .shared) {
        self.bpmOverrideStore = bpmOverrideStore
        setupEngine()
        observeInterruptions()
        observeRouteChanges()
    }

    deinit {
        // deinit은 nonisolated이므로 security-scoped URL을 직접 해제
        currentAccessedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Audio Session (SPEC.md 1.1~1.4)

    private func configureAudioSessionIfNeeded() throws {
        guard !isAudioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        isAudioSessionConfigured = true
    }

    private func activateAudioSessionIfNeeded() throws {
        try configureAudioSessionIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
    }

    /// SPEC.md 1.3: 인터럽트 처리
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            // Extract all values from userInfo BEFORE entering the Task
            // to avoid sending non-Sendable dictionary across isolation boundary
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let shouldResume: Bool = {
                let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                return AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            }()

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    if self.state == .playing {
                        self.playerNode.pause()
                        self.stopMetronome()
                        self.state = .paused
                        logger.info("Interruption began, paused playback")
                    }
                case .ended:
                    // 인터럽션 후 엔진이 재시작되면 AU latency가 달라질 수 있어 캐시 무효화.
                    self.cachedMetronomeDelay = nil
                    if shouldResume {
                        self.play()
                        logger.info("Interruption ended, auto-resumed")
                    } else {
                        logger.info("Interruption ended, waiting for manual resume")
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// SPEC.md 1.4: 오디오 라우트 변경 처리 (헤드폰 언플러그 등)
    private func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // 라우트(AirPods/BT/스피커) 변경 시 latency 값이 크게 달라질 수 있으므로 캐시 무효화.
                self.cachedMetronomeDelay = nil
                if reason == .oldDeviceUnavailable, self.state == .playing {
                    self.playerNode.pause()
                    self.stopMetronome()
                    self.state = .paused
                    logger.info("Headphone/BT disconnected, paused playback")
                }
            }
        }
    }

    // MARK: - Engine Setup

    /// Attach nodes BEFORE connecting them (SPEC.md 주의사항)
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(metronomeNode)
        engine.attach(timePitch)

        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(metronomeNode, to: engine.mainMixerNode, format: metronomeFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        timePitch.pitch = 0 // 피치 유지 (key lock)
        metronomeNode.volume = metronomeVolume
    }

    // MARK: - Security-Scoped URL Management

    /// 이전 파일의 security-scoped 권한을 반납한다.
    private func releaseCurrentURL() {
        if let url = currentAccessedURL {
            url.stopAccessingSecurityScopedResource()
            currentAccessedURL = nil
        }
    }

    // MARK: - File Loading

    func loadFile(url: URL) async {
        trackGeneration += 1
        let gen = trackGeneration
        await loadFile(url: url, generation: gen)
    }

    // MARK: - Local Playlist

    /// 로컬 파일 플레이리스트를 새로 만들고, 첫 곡을 로드한다 (autoPlay false 기본).
    /// 빈 URL 배열이면 noop.
    func loadPlaylist(fileURLs urls: [URL], autoPlay: Bool = false) async {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard !sorted.isEmpty else { return }
        var playlist = LocalFilePlaylist(fileURLs: sorted)
        guard let item = playlist.currentItem, case .file(let url) = item.source else { return }
        localPlaylist = playlist
        syncPlaybackEndBehavior()
        await loadFile(url: url)
        if autoPlay, state == .ready { play() }
    }

    /// 외부에서 단일 곡 로드 시 (Apple Music 보관함 import 등) — 플레이리스트 비우기.
    func clearLocalPlaylist() {
        localPlaylist = LocalFilePlaylist()
        syncPlaybackEndBehavior()
    }

    func nextLocalTrack() async {
        let shouldAutoPlay = state == .playing
        var playlist = localPlaylist
        guard let item = playlist.moveToNext(), case .file(let url) = item.source else { return }
        localPlaylist = playlist
        syncPlaybackEndBehavior()
        await loadFile(url: url)
        if shouldAutoPlay, state == .ready { play() }
    }

    func previousLocalTrack() async {
        let shouldAutoPlay = state == .playing
        var playlist = localPlaylist
        guard let item = playlist.moveToPrevious(), case .file(let url) = item.source else { return }
        localPlaylist = playlist
        syncPlaybackEndBehavior()
        await loadFile(url: url)
        if shouldAutoPlay, state == .ready { play() }
    }

    /// 큐 시트에서 사용자가 곡을 직접 선택했을 때 호출. 같은 곡이면 noop.
    /// 재생 중이었다면 새 곡도 재생 상태를 이어간다.
    func jumpToLocalTrack(at index: Int) async {
        let shouldAutoPlay = state == .playing
        guard localPlaylist.currentIndex != index else { return }
        var playlist = localPlaylist
        guard let item = playlist.jumpTo(index: index),
              case .file(let url) = item.source else { return }
        localPlaylist = playlist
        syncPlaybackEndBehavior()
        await loadFile(url: url)
        if shouldAutoPlay, state == .ready { play() }
    }

    func toggleLocalShuffle() {
        var playlist = localPlaylist
        guard playlist.toggleShuffle() != nil else { return }
        localPlaylist = playlist
        syncPlaybackEndBehavior()
    }

    /// 곡 끝에 도달했을 때 자동 진행. trackEndedSubject 구독자가 호출한다.
    func advanceAfterTrackEnded() async {
        guard !localPlaylist.isEmpty else { return }
        var playlist = localPlaylist

        if let item = playlist.moveToNext(), case .file(let url) = item.source {
            localPlaylist = playlist
            syncPlaybackEndBehavior()
            await loadFile(url: url)
            if state == .ready { play() }
            return
        }

        // 마지막 곡 — repeat 켜져 있으면 처음으로
        if localRepeatEnabled, let item = playlist.moveToStart(), case .file(let url) = item.source {
            localPlaylist = playlist
            syncPlaybackEndBehavior()
            await loadFile(url: url)
            if state == .ready { play() }
        }
    }

    private func syncPlaybackEndBehavior() {
        // 단일 트랙 + repeat ON이면 loop, 그 외(플레이리스트 또는 repeat OFF)는 notify로
        // → trackEndedSubject 구독자가 다음 곡으로 이어갈지 멈출지 결정.
        if localPlaylist.isEmpty {
            playbackEndBehavior = localRepeatEnabled ? .loop : .notify
        } else {
            playbackEndBehavior = .notify
        }
    }

    func loadResolvedTrack(
        url: URL,
        title: String,
        artist: String?,
        bpmHint: Double?
    ) async {
        pendingPresetBPMHint = bpmHint
        await loadFile(url: url)

        if state == .ready {
            trackTitle = title
            trackArtist = artist
            if let bpmHint, originalBPMSource == .assumedDefault {
                originalBPM = bpmHint
                _bpmFromMetadata = false
                originalBPMSource = .metadata
                applyAutomaticTargetBPM()
            }
        }
    }

    private func loadFile(url: URL, generation: Int) async {
        self.trackGeneration = generation
        // `pendingPresetBPMHint`은 호출자(loadSampleTrack)가 set — 분석 후 항상 정리한다.
        defer { pendingPresetBPMHint = nil }
        // [P1 fix] 기존 재생 큐 정리: 이전 트랙이 남아 있으면 깨끗이 정리
        playerNode.stop()
        playerNode.reset()
        isExternalMetronomePlaybackActive = false
        stopMetronome()
        hasScheduledPlayback = false
        isScheduling = false
        scheduledLoopStartFrame = 0
        currentScheduledStartFrame = 0
        stopProgressUpdates()
        if engine.isRunning {
            engine.stop()
        }

        // 이전 파일의 security-scoped 권한 반납
        releaseCurrentURL()
        currentTrackURL = nil
        currentTrackOverrideKey = nil

        state = .loading
        errorMessage = nil
        audioFile = nil
        beatAlignmentAnalysis = nil
        originalBPM = BPMRange.originalDefault
        originalBPMSource = .assumedDefault
        currentPlaybackTime = 0
        trackDuration = 0
        trackTitle = nil
        trackArtist = nil
        currentArtworkData = nil
        beatAlignmentConfidence = nil
        beatAlignmentCacheStatus = .none
        beatSyncStatus = .needsConfirmation
        beatSyncIssue = .missingBPM
        manualBeatOffsetNudge = 0
        sourceBeatOffsetSeconds = 0
        sourceBeatTimesSeconds = []
        _bpmFromMetadata = false

        // [P1 fix] 새 파일의 security-scoped 권한 획득 → 트랙 수명 동안 유지
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing {
            currentAccessedURL = url
        }
        currentTrackURL = url

        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            trackDuration = Double(file.length) / file.processingFormat.sampleRate

            // 트랙 메타데이터 읽기
            let asset = AVAsset(url: url)
            if let metadata = try? await asset.load(.metadata) {
                trackTitle = await Self.loadMetadataString(
                    from: metadata,
                    identifier: .commonIdentifierTitle
                ) ?? url.deletingPathExtension().lastPathComponent
                trackArtist = await Self.loadMetadataString(
                    from: metadata,
                    identifier: .commonIdentifierArtist
                )
            } else {
                trackTitle = url.deletingPathExtension().lastPathComponent
            }

            // 아트워크 로딩 (Now Playing Info Center 공급용)
            let artworkData = await Self.loadArtworkData(from: asset)
            guard generation == trackGeneration else { return }
            currentArtworkData = artworkData

            // 곡 영구 BPM override를 위한 identity 키
            let overrideKey = TrackBPMOverrideStore.identityKey(
                .fileMetadata(
                    title: trackTitle,
                    artist: trackArtist,
                    lastPathComponent: url.lastPathComponent
                )
            )
            currentTrackOverrideKey = overrideKey
            let storedOverride = bpmOverrideStore.bpm(forIdentity: overrideKey)

            // BPM 메타데이터 읽기
            let metadataBPM = await BPMMetadataReader.readBPM(from: url)
            if let bpm = metadataBPM {
                originalBPM = bpm
                _bpmFromMetadata = true
                originalBPMSource = .metadata
                beatSyncStatus = .bpmOnly
                beatSyncIssue = .missingBeatGrid
                logger.info("[track_loaded] BPM from metadata: \(bpm)")
            } else {
                originalBPM = BPMRange.originalDefault
                _bpmFromMetadata = false
                originalBPMSource = .assumedDefault
                beatSyncStatus = .needsConfirmation
                beatSyncIssue = .missingBPM
                logger.info("[track_loaded] No BPM metadata, using default \(BPMRange.originalDefault)")
            }

            let analysisHint = metadataBPM ?? pendingPresetBPMHint
            let alignmentResult = try? await (
                Task.detached(priority: .userInitiated) {
                    try BeatAlignmentAnalyzer.loadOrAnalyze(url: url, expectedBPM: analysisHint)
                }.value
            )
            beatAlignmentCacheStatus = alignmentResult?.cacheStatus ?? .none

            if let analysis = alignmentResult?.analysis {
                beatAlignmentAnalysis = analysis
                beatAlignmentConfidence = analysis.confidence
                manualBeatOffsetNudge = analysis.manualNudgeSeconds
                applyBeatSyncAssessment(from: analysis)
                if metadataBPM == nil {
                    originalBPM = analysis.estimatedBPM
                    _bpmFromMetadata = false
                    originalBPMSource = .analysis
                    logger.info("[track_loaded] BPM from audio analysis: \(analysis.estimatedBPM)")
                }
                logger.info("[track_loaded] Beat offset from analysis: \(analysis.beatOffsetSeconds)s beatCount=\(analysis.beatTimesSeconds?.count ?? 0) confidence=\(analysis.confidence) cache=\(self.beatAlignmentCacheStatus.rawValue)")
            }

            // 사용자 override는 모든 자동 결정보다 우선
            if let storedOverride,
               storedOverride >= BPMRange.originalMin,
               storedOverride <= BPMRange.originalMax {
                originalBPM = storedOverride
                _bpmFromMetadata = false
                originalBPMSource = .manual
                beatSyncStatus = .bpmOnly
                beatSyncIssue = .missingBeatGrid
                sourceBeatOffsetSeconds = 0
                sourceBeatTimesSeconds = []
                logger.info("[track_loaded] Applied user BPM override: \(storedOverride)")
            }

            applyAutomaticTargetBPM()
            state = .ready
            logger.info("[track_loaded] \(url.lastPathComponent) loaded successfully")

        } catch {
            audioFile = nil
            originalBPM = BPMRange.originalDefault
            originalBPMSource = .assumedDefault
            beatSyncStatus = .needsConfirmation
            beatSyncIssue = .missingBPM
            state = .error
            errorMessage = Self.userFacingLoadError(for: url)
            // 로드 실패 시 권한도 반납
            releaseCurrentURL()
            logger.error("[F-01] File load failed: \(error.localizedDescription)")
        }
    }

    func loadSampleTrack(_ preset: SampleTrackPreset = .clickLoop) async {
        do {
            let sampleURL: URL
            if preset.isBundledFile {
                sampleURL = try Self.bundledSampleURL(for: preset)
            } else {
                // 파일 합성은 디스크 I/O를 포함하므로 메인 액터를 벗어나 수행한다.
                sampleURL = try await Task.detached(priority: .userInitiated) {
                    try Self.sampleAudioURL(for: preset)
                }.value
            }

            pendingPresetBPMHint = preset.bpm
            await loadFile(url: sampleURL)

            if state == .ready {
                trackTitle = preset.title
                trackArtist = preset.artist
                // Preset BPM fallback applies only when no stronger source already set
                // originalBPM. Manual override and parsed metadata both win over preset.
                let strongerSourceWins = hasBPMFromMetadata || originalBPMSource == .manual
                if !strongerSourceWins {
                    originalBPM = preset.bpm
                    _bpmFromMetadata = false
                    originalBPMSource = .preset
                    if sourceBeatTimesSeconds.isEmpty {
                        beatSyncStatus = .bpmOnly
                        beatSyncIssue = .missingBeatGrid
                    }
                    applyAutomaticTargetBPM()
                }
            }
        } catch {
            state = .error
            errorMessage = "샘플 오디오를 준비할 수 없습니다"
            logger.error("[F-02] Sample audio creation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback Control

    func play() {
        let canResumeTrack = state == .ready || state == .paused
        let canStartMetronomeOnly = state == .idle && audioFile == nil && canRunMetronomeForCurrentBeatSync
        guard canResumeTrack || canStartMetronomeOnly else { return }
        guard canStartPlayback else { return }

        do {
            try activateAudioSessionIfNeeded()
            if !engine.isRunning {
                try engine.start()
            }
            refreshMetronomeLatencyIfNeeded()

            if audioFile != nil, !hasScheduledPlayback {
                scheduleLoop()
            }

            let sourceTime = currentSourcePlaybackTime()
            let playbackAnchor = makePlaybackAnchor()
            if audioFile != nil {
                playerNode.play(at: playbackAnchor)
                startProgressUpdates()
            }
            if canRunMetronomeForCurrentBeatSync {
                startMetronome(
                    alignedToSourceTime: sourceTime,
                    anchorHostTime: playbackAnchor.hostTime
                )
            }
            state = .playing
            logger.info("[run_started] targetBPM=\(self.targetBPM) hasFile=\(self.audioFile != nil) metronomeOn=\(self.metronomeEnabled)")

        } catch {
            state = .error
            errorMessage = "오디오 재생을 시작할 수 없습니다"
            logger.error("[A-01] Playback start failed: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard state == .playing else { return }
        if audioFile != nil {
            playerNode.pause()
        }
        updateCurrentPlaybackTime()
        stopProgressUpdates()
        stopMetronome()
        state = .paused
    }

    func togglePlayPause() {
        switch state {
        case .ready, .paused:
            play()
        case .playing:
            pause()
        default:
            break
        }
    }

    func startExternalMetronomePlayback(alignedToSourceTime sourceTime: TimeInterval = 0) {
        guard metronomeEnabled else {
            stopExternalMetronomePlayback()
            return
        }
        guard canRunMetronomeForCurrentBeatSync else {
            stopExternalMetronomePlayback()
            return
        }

        do {
            try activateAudioSessionIfNeeded()
            if !engine.isRunning {
                try engine.start()
            }
            refreshMetronomeLatencyIfNeeded()

            let playbackAnchor = makePlaybackAnchor()
            startMetronome(
                alignedToSourceTime: max(sourceTime, 0),
                anchorHostTime: playbackAnchor.hostTime
            )
            isExternalMetronomePlaybackActive = true
            logger.info("[external_metronome_started] targetBPM=\(self.targetBPM) sourceTime=\(sourceTime)s beatOffset=\(self.sourceBeatOffsetSeconds)s")
        } catch {
            isExternalMetronomePlaybackActive = false
            stopMetronome()
            errorMessage = "메트로놈을 시작할 수 없습니다"
            logger.error("[M-04] External metronome start failed: \(error.localizedDescription)")
        }
    }

    func stopExternalMetronomePlayback() {
        guard isExternalMetronomePlaybackActive else { return }
        isExternalMetronomePlaybackActive = false
        stopMetronome()

        if audioFile == nil, state != .playing, engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Looping (completion handler 재스케줄)

    /// 곡 끝에서 completion handler로 다시 스케줄하여 반복 재생.
    /// completion handler는 private audio thread에서 호출됨 → MainActor로 돌아와야 함.
    private func scheduleLoop() {
        guard let file = audioFile else { return }
        guard !isScheduling else { return }
        let totalFrames = file.length
        guard totalFrames > 0 else { return }

        let startFrame = min(max(scheduledLoopStartFrame, 0), max(totalFrames - 1, 0))
        let framesRemaining = totalFrames - startFrame
        guard framesRemaining > 0 else { return }

        isScheduling = true
        hasScheduledPlayback = true
        currentScheduledStartFrame = startFrame
        scheduledLoopStartFrame = 0

        let capturedGeneration = self.trackGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(framesRemaining),
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.trackGeneration == capturedGeneration else { return } // stale drop
                guard self.state == .playing else {
                    self.isScheduling = false
                    self.hasScheduledPlayback = false
                    return
                }
                self.currentPlaybackTime = 0
                self.isScheduling = false
                self.hasScheduledPlayback = false
                self.currentScheduledStartFrame = 0
                switch self.playbackEndBehavior {
                case .loop:
                    self.scheduleLoop()
                    if self.canRunMetronomeForCurrentBeatSync {
                        self.startMetronome(alignedToSourceTime: 0, anchorHostTime: mach_absolute_time())
                    }
                    logger.debug("Loop: re-scheduled (gen=\(capturedGeneration))")
                case .notify:
                    self.state = .paused
                    self.trackEndedSubject.send(())
                    logger.debug("Track ended, notify (gen=\(capturedGeneration))")
                }
            }
        }
    }

    // MARK: - Rate

    private func applyAutomaticTargetBPM() {
        let automaticTarget = BPMRange.automaticTarget(forOriginalBPM: originalBPM)
        if targetBPM == automaticTarget {
            updateRate()
        } else {
            targetBPM = automaticTarget
        }
    }

    func setOriginalBPM(_ bpm: Double) {
        // SPEC.md 2.8: 30~300 범위만 허용
        guard bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else {
            errorMessage = "원본 BPM은 30~300 사이 숫자로 입력하세요"
            return
        }
        originalBPM = bpm
        _bpmFromMetadata = false
        originalBPMSource = .manual
        beatSyncStatus = .bpmOnly
        beatSyncIssue = .missingBeatGrid
        stopMetronomeIfBeatSyncRejected()
        sourceBeatOffsetSeconds = 0
        sourceBeatTimesSeconds = []
        errorMessage = nil
        if let key = currentTrackOverrideKey {
            bpmOverrideStore.store(bpm: bpm, forIdentity: key)
        }
        applyAutomaticTargetBPM()
    }

    /// half/double-time 후보 중 목표 케이던스에 가까운 BPM을 임시로 적용한다.
    /// 사용자가 명시적으로 선택한 것이 아니므로 영구 저장하지 않고
    /// `originalBPMSource`도 바꾸지 않아 UI에 후보 버튼이 계속 보인다.
    func applyAutoBPMDefault(_ bpm: Double) {
        guard bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else { return }
        guard originalBPMSource != .manual else { return }
        guard abs(originalBPM - bpm) > 0.5 else {
            applyAutomaticTargetBPM()
            return
        }
        originalBPM = bpm
        _bpmFromMetadata = false
        applyAutomaticTargetBPM()
    }

    func setStreamingOriginalBPM(_ bpm: Double?, source: OriginalBPMSource = .metadata) {
        setStreamingBeatAlignment(bpm: bpm, source: source, beatOffsetSeconds: nil)
    }

    func setStreamingBeatAlignment(
        bpm: Double?,
        source: OriginalBPMSource = .metadata,
        beatOffsetSeconds: TimeInterval?,
        beatTimesSeconds: [TimeInterval]? = nil,
        confidence: Double? = nil
    ) {
        guard let bpm, bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else {
            originalBPM = BPMRange.originalDefault
            _bpmFromMetadata = false
            originalBPMSource = .assumedDefault
            beatSyncStatus = .needsConfirmation
            beatSyncIssue = .missingBPM
            stopMetronomeIfBeatSyncRejected()
            sourceBeatOffsetSeconds = 0
            sourceBeatTimesSeconds = []
            applyAutomaticTargetBPM()
            return
        }

        originalBPM = bpm
        _bpmFromMetadata = source == .metadata
        originalBPMSource = source
        let assessment = BeatSyncReliability.assess(
            originalBPM: bpm,
            confidence: confidence,
            beatTimesSeconds: beatTimesSeconds ?? []
        )
        beatSyncStatus = assessment.status
        beatSyncIssue = assessment.issue
        stopMetronomeIfBeatSyncRejected()
        // grid 자체는 못 믿더라도 첫 비트 offset은 종종 phase 추정에 도움이 된다.
        // bpm이 확정된 상태에서 BPM 균등 메트로놈에 첫 박 위상으로 활용한다.
        if let beatOffsetSeconds {
            let beatDuration = 60.0 / max(bpm, 1)
            sourceBeatOffsetSeconds = MetronomeSyncPlanner.normalizedOffset(
                beatOffsetSeconds,
                beatDuration: beatDuration
            )
        } else {
            sourceBeatOffsetSeconds = 0
        }
        sourceBeatTimesSeconds = assessment.shouldUseBeatGrid
            ? sanitizedBeatTimes(beatTimesSeconds ?? [])
            : []
        errorMessage = nil
        applyAutomaticTargetBPM()
    }

    func nudgeTargetBPM(by delta: Double) {
        let next = min(max(targetBPM + delta, BPMRange.targetMin), BPMRange.targetMax)
        targetBPM = next.rounded()
    }

    /// 사용자가 음악 박자에 맞춰 탭한 순간을 다음 강박 위치로 등록한다.
    /// streaming은 PCM 분석이 안 되므로 자동 phase가 어긋날 때 한 번 탭으로 정렬한다.
    /// `currentSourceTime`은 호출 시점의 player.playbackTime.
    /// 메트로놈이 동작 중이면 새 phase로 즉시 재시작한다.
    func alignBeatPhaseToNow(currentSourceTime: TimeInterval) {
        guard originalBPM > 0 else { return }
        let beatDuration = 60.0 / originalBPM
        sourceBeatOffsetSeconds = MetronomeSyncPlanner.normalizedOffset(
            currentSourceTime,
            beatDuration: beatDuration
        )
        // grid는 더 이상 신뢰하지 않는다 — 사용자 탭이 새 phase의 진실이 됨.
        sourceBeatTimesSeconds = []
        if isExternalMetronomePlaybackActive {
            startExternalMetronomePlayback(alignedToSourceTime: currentSourceTime)
        }
    }

    func nudgeBeatOffset(by milliseconds: Double) {
        guard let analysis = beatAlignmentAnalysis,
              let url = currentTrackURL else { return }

        let nextNudge = manualBeatOffsetNudge + (milliseconds / 1000)
        if let updated = try? BeatAlignmentAnalyzer.updateManualNudge(nextNudge, for: url, analysis: analysis) {
            beatAlignmentAnalysis = updated
            manualBeatOffsetNudge = updated.manualNudgeSeconds
            applyBeatSyncAssessment(from: updated)
            if state == .playing, canRunMetronomeForCurrentBeatSync {
                startMetronome(
                    alignedToSourceTime: currentSourcePlaybackTime(),
                    anchorHostTime: mach_absolute_time()
                )
            }
        }
    }

    func resetBeatOffsetNudge() {
        guard manualBeatOffsetNudge != 0 else { return }
        guard let analysis = beatAlignmentAnalysis,
              let url = currentTrackURL else { return }

        if let updated = try? BeatAlignmentAnalyzer.updateManualNudge(0, for: url, analysis: analysis) {
            beatAlignmentAnalysis = updated
            manualBeatOffsetNudge = updated.manualNudgeSeconds
            applyBeatSyncAssessment(from: updated)
            if state == .playing, canRunMetronomeForCurrentBeatSync {
                startMetronome(
                    alignedToSourceTime: currentSourcePlaybackTime(),
                    anchorHostTime: mach_absolute_time()
                )
            }
        }
    }

    func alignBeatOffsetToCurrentTap() {
        guard let analysis = beatAlignmentAnalysis,
              let url = currentTrackURL else { return }

        let beatDuration = 60.0 / max(analysis.estimatedBPM, 1)
        let targetNudge = BeatOffsetAdjustment.manualNudgeToAlignTap(
            currentSourceTime: currentSourcePlaybackTime(),
            detectedOffset: analysis.beatOffsetSeconds,
            beatDuration: beatDuration
        )

        if let updated = try? BeatAlignmentAnalyzer.updateManualNudge(targetNudge, for: url, analysis: analysis) {
            beatAlignmentAnalysis = updated
            manualBeatOffsetNudge = updated.manualNudgeSeconds
            applyBeatSyncAssessment(from: updated)
            if state == .playing, canRunMetronomeForCurrentBeatSync {
                startMetronome(
                    alignedToSourceTime: currentSourcePlaybackTime(),
                    anchorHostTime: mach_absolute_time()
                )
            }
        }
    }

    func resetTargetBPM() {
        targetBPM = BPMRange.targetDefault
    }

    func seek(toProgress progress: Double) {
        guard let file = audioFile else { return }

        let wasPlaying = state == .playing
        let clampedProgress = min(max(progress, 0), 1)
        let maxFrame = max(file.length - 1, 0)
        let targetFrame = min(AVAudioFramePosition((Double(file.length) * clampedProgress).rounded(.down)), maxFrame)

        playerNode.stop()
        playerNode.reset()
        hasScheduledPlayback = false
        isScheduling = false
        scheduledLoopStartFrame = targetFrame
        currentScheduledStartFrame = targetFrame
        currentPlaybackTime = Double(targetFrame) / file.processingFormat.sampleRate

        scheduleLoop()

        if wasPlaying {
            let playbackAnchor = makePlaybackAnchor()
            playerNode.play(at: playbackAnchor)
            startProgressUpdates()
            if canRunMetronomeForCurrentBeatSync {
                startMetronome(
                    alignedToSourceTime: currentPlaybackTime,
                    anchorHostTime: playbackAnchor.hostTime
                )
            }
        } else {
            stopProgressUpdates()
        }
    }

    func clearError() {
        errorMessage = nil
        state = PlaybackStateRecovery.stateAfterClearingError(
            currentState: state,
            hasLoadedTrack: hasLoadedTrack
        )
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    private func updateRate() {
        // A-04: division by zero 방어
        guard originalBPM > 0 else {
            originalBPM = BPMRange.originalDefault
            logger.error("[A-04] originalBPM was 0, reset to default \(BPMRange.originalDefault)")
            return
        }
        let rate = Float(playbackRate)
        timePitch.rate = rate
    }

    private func handleMetronomeEnabledChange() {
        logger.info("[metronome_toggled] isOn=\(self.metronomeEnabled, privacy: .public) currentVolume=\(self.metronomeVolume)")

        if metronomeEnabled {
            if state == .playing {
                startMetronome(
                    alignedToSourceTime: currentSourcePlaybackTime(),
                    anchorHostTime: mach_absolute_time()
                )
            }
            return
        }

        isExternalMetronomePlaybackActive = false
        stopMetronome()

        // 메트로놈-only 모드에서 끄면 세션 종료. 엔진도 멈춰 배터리/세션을 반납한다.
        if audioFile == nil, state == .playing || state == .paused {
            if engine.isRunning {
                engine.stop()
            }
            state = .idle
        }
    }

    private func restartMetronomeIfNeeded() {
        guard isMetronomeRunning, metronomeEnabled else { return }
        guard canRunMetronomeForCurrentBeatSync else {
            stopMetronome()
            return
        }
        guard !isExternalMetronomePlaybackActive else { return }
        startMetronome(
            alignedToSourceTime: currentSourcePlaybackTime(),
            anchorHostTime: mach_absolute_time()
        )
    }

    private func stopMetronomeIfBeatSyncRejected() {
        guard !beatSyncStatus.usesBeatGrid else { return }
        isExternalMetronomePlaybackActive = false
        stopMetronome()
    }

    /// playerNode → timePitch → mixer 경로와 metronomeNode → mixer 경로의 지연 차이를 캐시한다.
    /// `engine.start()` 이후에만 AU latency가 유효하므로 호출 순서가 중요하다.
    private func refreshMetronomeLatencyIfNeeded() {
        guard cachedMetronomeDelay == nil else { return }
        let auLatency = timePitch.auAudioUnit.latency
        let compensation = LatencyCompensator.metronomeDelaySeconds(
            timePitchAULatency: auLatency,
            timePitchPresentation: 0,
            mixerPresentation: 0
        )
        cachedMetronomeDelay = compensation
        logger.debug("[latency_refresh] timePitchAULatency=\(auLatency)s compensation=\(compensation)s")
    }

    private func startMetronome(
        alignedToSourceTime sourceTime: TimeInterval = 0,
        anchorHostTime: UInt64
    ) {
        guard canRunMetronomeForCurrentBeatSync else {
            stopMetronome()
            return
        }

        stopMetronome()
        let gridPlan = BeatGridSyncPlanner.planNextBeat(
            currentSourceTime: sourceTime,
            beatTimesSeconds: metronomeBeatTimesSeconds,
            fallbackSourceBeatOffset: sourceBeatOffsetSeconds,
            originalBPM: metronomeSourceCadenceBPM,
            targetBPM: metronomeBPM
        )
        let syncPlan = gridPlan.syncPlan
        metronomeBeatIndex = syncPlan.startingBeatIndex
        metronomeScheduledBeats = 0
        metronomeNextBeatGridIndex = gridPlan.beatGridIndex
        isMetronomeRunning = true
        scheduleMetronomeBeatsIfNeeded()
        let latencyComp = cachedMetronomeDelay ?? 0
        let firstBeatHostTime = anchorHostTime + AVAudioTime.hostTime(
            forSeconds: syncPlan.nextBeatDelay + latencyComp
        )
        metronomeNode.play(at: AVAudioTime(hostTime: firstBeatHostTime))
    }

    private func stopMetronome() {
        metronomeNode.stop()
        metronomeNode.reset()
        metronomeBeatIndex = 0
        metronomeScheduledBeats = 0
        metronomeNextBeatGridIndex = nil
        isMetronomeRunning = false
    }

    private func scheduleMetronomeBeatsIfNeeded() {
        guard isMetronomeRunning, metronomeEnabled else { return }
        while metronomeScheduledBeats < metronomeLookaheadBeats {
            scheduleNextMetronomeBeat()
        }
    }

    private func scheduleNextMetronomeBeat() {
        let beat = metronomeBeatIndex
        let isDownbeat = beat.isMultiple(of: MetronomeDefaults.beatsPerBar)
        let intervalDuration = nextMetronomeIntervalDuration()
        guard let buffer = Self.makeMetronomeBeatBuffer(
            format: metronomeFormat,
            frequency: isDownbeat ? 1_320 : 880,
            gain: isDownbeat ? 0.95 : 0.72,
            beatDuration: intervalDuration
        ) else {
            logger.error("[M-02] Metronome buffer unavailable, stopping metronome")
            stopMetronome()
            return
        }

        // 한 박 길이의 버퍼를 큐에 이어 붙여 메인 런루프와 분리된 샘플 정확도로 재생한다.
        metronomeNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.metronomeScheduledBeats = max(0, self.metronomeScheduledBeats - 1)
                guard self.isMetronomeRunning else { return }
                self.scheduleMetronomeBeatsIfNeeded()
            }
        }

        metronomeScheduledBeats += 1
        advanceMetronomeBeatGridCursor()
        metronomeBeatIndex = (beat + 1) % MetronomeDefaults.beatsPerBar
    }

    private func nextMetronomeIntervalDuration() -> TimeInterval {
        BeatGridSyncPlanner.intervalAfterBeat(
            at: metronomeNextBeatGridIndex,
            beatTimesSeconds: metronomeBeatTimesSeconds,
            originalBPM: metronomeSourceCadenceBPM,
            targetBPM: metronomeBPM
        )
    }

    private func advanceMetronomeBeatGridCursor() {
        guard let nextIndex = metronomeNextBeatGridIndex else { return }
        let followingIndex = nextIndex + 1
        metronomeNextBeatGridIndex = metronomeBeatTimesSeconds.indices.contains(followingIndex)
            ? followingIndex
            : nil
    }

    private func rebuildMetronomeBuffers() {
        let beatDuration = 60.0 / metronomeBPM
        accentBeatBuffer = Self.makeMetronomeBeatBuffer(
            format: metronomeFormat,
            frequency: 1_320,
            gain: 0.95,
            beatDuration: beatDuration
        )
        regularBeatBuffer = Self.makeMetronomeBeatBuffer(
            format: metronomeFormat,
            frequency: 880,
            gain: 0.72,
            beatDuration: beatDuration
        )
    }

    private var metronomeSourceCadenceBPM: Double {
        guard targetBPM > 0 else { return originalBPM }
        return originalBPM * (metronomeBPM / targetBPM)
    }

    private var metronomeBeatTimesSeconds: [TimeInterval] {
        guard metronomeBPM > targetBPM * 1.5 else { return sourceBeatTimesSeconds }
        return doubledBeatTimes(sourceBeatTimesSeconds)
    }

    private func doubledBeatTimes(_ beatTimes: [TimeInterval]) -> [TimeInterval] {
        guard beatTimes.count >= 2 else { return beatTimes }

        var doubled: [TimeInterval] = []
        doubled.reserveCapacity(beatTimes.count * 2 - 1)
        for index in beatTimes.indices {
            let beatTime = beatTimes[index]
            doubled.append(beatTime)

            let nextIndex = beatTimes.index(after: index)
            if beatTimes.indices.contains(nextIndex) {
                doubled.append((beatTime + beatTimes[nextIndex]) / 2)
            }
        }
        return doubled
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentPlaybackTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        updateCurrentPlaybackTime()
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func currentSourcePlaybackTime() -> TimeInterval {
        if state == .playing {
            updateCurrentPlaybackTime()
        }
        return max(currentPlaybackTime, 0)
    }

    private func effectiveOffset(for analysis: BeatAlignmentAnalysis) -> TimeInterval {
        let beatDuration = 60.0 / max(analysis.estimatedBPM, 1)
        return BeatOffsetAdjustment.effectiveOffset(
            detectedOffset: analysis.beatOffsetSeconds,
            manualNudge: analysis.manualNudgeSeconds,
            beatDuration: beatDuration
        )
    }

    private func applyBeatSyncAssessment(from analysis: BeatAlignmentAnalysis) {
        let effectiveTimes = effectiveBeatTimes(for: analysis)
        let assessment = BeatSyncReliability.assess(
            originalBPM: analysis.estimatedBPM,
            confidence: analysis.confidence,
            beatTimesSeconds: effectiveTimes
        )
        beatSyncStatus = assessment.status
        beatSyncIssue = assessment.issue
        stopMetronomeIfBeatSyncRejected()
        sourceBeatOffsetSeconds = assessment.shouldUseBeatGrid ? effectiveOffset(for: analysis) : 0
        sourceBeatTimesSeconds = assessment.shouldUseBeatGrid ? effectiveTimes : []
    }

    private func effectiveBeatTimes(for analysis: BeatAlignmentAnalysis) -> [TimeInterval] {
        sanitizedBeatTimes((analysis.beatTimesSeconds ?? []).map { beatTime in
            beatTime + analysis.manualNudgeSeconds
        })
    }

    private func sanitizedBeatTimes(_ beatTimes: [TimeInterval]) -> [TimeInterval] {
        var previous: TimeInterval?
        return beatTimes
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
            .filter { beatTime in
                defer { previous = beatTime }
                guard let previous else { return true }
                return beatTime - previous > 0.05
            }
    }

    private func makePlaybackAnchor(secondsFromNow: TimeInterval = 0.06) -> AVAudioTime {
        AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: secondsFromNow))
    }

    private func updateCurrentPlaybackTime() {
        guard let file = audioFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            if state != .playing {
                currentPlaybackTime = min(currentPlaybackTime, trackDuration)
            }
            return
        }

        let currentFrame = currentScheduledStartFrame + AVAudioFramePosition(playerTime.sampleTime)
        let seconds = Double(currentFrame) / playerTime.sampleRate
        let duration = Double(file.length) / file.processingFormat.sampleRate
        currentPlaybackTime = min(max(seconds, 0), duration)
    }

    private static func bundledSampleURL(for preset: SampleTrackPreset) throws -> URL {
        let filename = preset.filename
        let resourceName = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else {
            throw NSError(
                domain: "AudioManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Bundled sample not found: \(filename)"]
            )
        }
        return url
    }

    nonisolated private static func sampleAudioURL(for preset: SampleTrackPreset) throws -> URL {
        // Caches 디렉터리를 사용해 앱 재실행 간 재사용하되, 시스템이 공간 회수 시 폐기될 수 있음을 허용.
        let fileManager = FileManager.default
        let cachesDir = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = cachesDir.appendingPathComponent(preset.filename)

        if !fileManager.fileExists(atPath: url.path) {
            try Self.createSampleAudioFile(at: url, preset: preset)
        }

        return url
    }

    nonisolated private static func createSampleAudioFile(at url: URL, preset: SampleTrackPreset) throws {
        let sampleRate = 44_100
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let beatCount = 8
        let bpm = preset.bpm
        let beatDuration = 60.0 / bpm
        let duration = Double(beatCount) * beatDuration
        let frameCount = Int(Double(sampleRate) * duration)
        let dataSize = frameCount * channels * bytesPerSample

        var wav = Data()
        wav.reserveCapacity(44 + dataSize)

        wav.append("RIFF".data(using: .ascii)!)
        wav.appendLE32(UInt32(36 + dataSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.appendLE32(16)
        wav.appendLE16(1)
        wav.appendLE16(UInt16(channels))
        wav.appendLE32(UInt32(sampleRate))
        wav.appendLE32(UInt32(sampleRate * channels * bytesPerSample))
        wav.appendLE16(UInt16(channels * bytesPerSample))
        wav.appendLE16(UInt16(bitsPerSample))
        wav.append("data".data(using: .ascii)!)
        wav.appendLE32(UInt32(dataSize))

        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let beatIndex = Int(time / beatDuration)
            let beatStart = Double(beatIndex) * beatDuration
            let beatOffset = time - beatStart

            let sampleValue: Double
            switch preset {
            case .clickLoop:
                if beatOffset < 0.08 {
                    let envelope = exp(-beatOffset * 28)
                    let accentBoost = beatIndex.isMultiple(of: 4) ? 1.0 : 0.72
                    let baseTone = sin(2 * .pi * 880 * beatOffset)
                    let overtone = 0.45 * sin(2 * .pi * 1760 * beatOffset)
                    sampleValue = (baseTone + overtone) * envelope * 0.55 * accentBoost
                } else {
                    sampleValue = 0
                }
            case .synthPulse:
                let phase = beatOffset / beatDuration
                let synthEnvelope = exp(-beatOffset * 6.5)
                let pulse = sin(2 * .pi * 220 * time) + 0.35 * sin(2 * .pi * 440 * time)
                let gate = phase < 0.42 ? 1.0 : 0.0
                sampleValue = pulse * synthEnvelope * gate * 0.33
            case .warmupGroove:
                let eighthDuration = beatDuration / 2
                let eighthIndex = Int(beatOffset / eighthDuration)
                let localOffset = beatOffset.truncatingRemainder(dividingBy: eighthDuration)
                let hitGain = (eighthIndex == 0 || beatIndex.isMultiple(of: 4)) ? 1.0 : 0.58
                if localOffset < 0.07 {
                    let envelope = exp(-localOffset * 18)
                    let low = sin(2 * .pi * 110 * localOffset)
                    let mid = 0.6 * sin(2 * .pi * 330 * localOffset)
                    sampleValue = (low + mid) * envelope * hitGain * 0.42
                } else {
                    sampleValue = 0
                }
            case .kickdrumRocket:
                // Bundled MP3 preset never uses synthesized sample generation.
                sampleValue = 0
            }

            let pcm = Int16(max(-1, min(1, sampleValue)) * Double(Int16.max))
            wav.appendLE16(UInt16(bitPattern: pcm))
        }

        try wav.write(to: url, options: .atomic)
    }

    private static func makeMetronomeBeatBuffer(
        format: AVAudioFormat,
        frequency: Double,
        gain: Float,
        beatDuration: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * beatDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            logger.error("[M-03] Failed to allocate metronome PCM buffer (freq=\(frequency))")
            return nil
        }
        buffer.frameLength = frameCount

        let channel = channelData[0]
        let clickDuration = min(0.05, beatDuration)
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            guard time < clickDuration else {
                channel[frame] = 0
                continue
            }
            let envelope = Float(exp(-time * 36))
            let fundamental = sin(2 * .pi * frequency * time)
            let overtone = 0.35 * sin(2 * .pi * frequency * 1.8 * time)
            channel[frame] = Float(fundamental + overtone) * envelope * gain
        }

        return buffer
    }

    private static func userFacingLoadError(for url: URL) -> String {
        let supportedExtensions = ["mp3", "m4a", "wav"]
        let fileExtension = url.pathExtension.lowercased()
        if !supportedExtensions.contains(fileExtension) {
            return "지원 형식은 mp3, m4a, wav 입니다"
        }
        return "파일을 열 수 없습니다. mp3, m4a, wav 파일인지 확인하세요"
    }

    private static func loadMetadataString(
        from metadata: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else {
            return nil
        }
        return value
    }

    private static func loadArtworkData(from asset: AVAsset) async -> Data? {
        do {
            let metadata = try await asset.load(.commonMetadata)
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try await item.load(.dataValue) {
                    return data
                }
            }
        } catch {
            // 아트워크 로딩 실패는 치명적이지 않음 — 조용히 무시
        }
        return nil
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLE32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
