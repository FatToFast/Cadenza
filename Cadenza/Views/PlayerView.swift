import MusicKit
import SwiftUI
import UniformTypeIdentifiers

/// 메인 플레이어 화면 (DESIGN.md 2.1)
struct PlayerView: View {
    @EnvironmentObject private var audio: AudioManager
    @StateObject private var streaming = AppleMusicStreamingController()

    private var nowPlaying: NowPlayingInfo { audio.currentNowPlayingInfo }

    @State private var showFilePicker = false
    @State private var showPlaylistFilePicker = false
    @State private var showAppleMusicPicker = false
    @State private var showAppleMusicStreamingSearch = false
    @State private var showAppleMusicStreamingPlaylists = false
    @State private var isImportingAppleMusic = false
    @State private var originalBPMText = "\(Int(BPMRange.originalDefault))"
    @State private var seekPreviewProgress = 0.0
    @State private var isSeekingPlayback = false
    @State private var localPlaylist = LocalFilePlaylist()

    var body: some View {
        ZStack {
            Color.cadenzaBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider().background(Color.cadenzaDivider)

                ScrollView {
                    VStack(spacing: 24) {
                        // 곡 정보 또는 empty state
                        trackInfoSection
                            .padding(.top, 20)

                        // BPM 디스플레이
                        BPMDisplayView(
                            targetBPM: audio.targetBPM,
                            originalBPM: nowPlaying.originalBPM,
                            playbackRate: audio.playbackRate,
                            originalBPMSource: nowPlaying.originalBPMSource
                        )
                        .padding(.vertical, 16)

                        // BPM 슬라이더
                        BPMSliderView(
                            targetBPM: $audio.targetBPM,
                            playbackRate: audio.playbackRate,
                            onDecrease: { audio.nudgeTargetBPM(by: -5) },
                            onReset: { audio.resetTargetBPM() },
                            onIncrease: { audio.nudgeTargetBPM(by: 5) }
                        )
                            .padding(.horizontal, 20)

                        if audio.hasLoadedTrack && !streaming.hasSong {
                            Divider().background(Color.cadenzaDivider)

                            playbackProgressSection
                                .padding(.horizontal, 20)

                            Divider().background(Color.cadenzaDivider)

                            originalBPMControls
                                .padding(.horizontal, 20)

                            if audio.hasBeatAlignmentAnalysis {
                                Divider().background(Color.cadenzaDivider)

                                syncDebugSection
                                    .padding(.horizontal, 20)
                            }
                        }

                        Divider().background(Color.cadenzaDivider)

                        metronomeControls
                            .padding(.horizontal, 20)

                        Divider().background(Color.cadenzaDivider)

                        // 재생 버튼 + 파일 선택
                        playbackControls
                            .padding(.bottom, 32)
                    }
                }
            }

            // 에러 배너 (DESIGN.md 2.2.2)
            if let error = audio.errorMessage {
                VStack {
                    errorBanner(message: error)
                        .padding(.horizontal, 16)
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.mp3, .mpeg4Audio, .wav],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .fileImporter(
            isPresented: $showPlaylistFilePicker,
            allowedContentTypes: [.mp3],
            allowsMultipleSelection: true
        ) { result in
            handlePlaylistFileSelection(result)
        }
        .sheet(isPresented: $showAppleMusicPicker) {
            AppleMusicLibraryView { track in
                loadAppleMusicTrack(track)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAppleMusicStreamingSearch) {
            AppleMusicStreamingSearchView { song in
                playAppleMusicStream(song)
            }
        }
        .sheet(isPresented: $showAppleMusicStreamingPlaylists) {
            AppleMusicStreamingPlaylistView { playlist, entry in
                playAppleMusicPlaylist(playlist, entry: entry)
            }
        }
        .onAppear(perform: syncOriginalBPMText)
        .onChange(of: audio.originalBPM) { _, _ in
            syncOriginalBPMText()
        }
        .onChange(of: audio.playbackProgress) { _, newValue in
            guard !isSeekingPlayback else { return }
            seekPreviewProgress = newValue
        }
        .onChange(of: audio.playbackRate) { _, newValue in
            if streaming.hasSong {
                streaming.applyPlaybackRate(newValue)
                syncStreamingMetronome()
            }
        }
        .onChange(of: audio.metronomeEnabled) { _, _ in
            syncStreamingMetronome()
        }
        .onChange(of: streaming.isPlaying) { _, _ in
            syncStreamingMetronome()
        }
        .onChange(of: streaming.errorMessage) { _, message in
            if let message {
                audio.presentError(message)
            }
        }
        .onChange(of: streaming.currentBPM) { _, bpm in
            applyStreamingTempoAndAlignment(bpm: bpm)
        }
        .onChange(of: streaming.currentBPMSource) { _, _ in
            applyStreamingTempoAndAlignment()
        }
        .onChange(of: streaming.currentBeatOffsetSeconds) { _, _ in
            applyStreamingTempoAndAlignment()
        }
        .onChange(of: streaming.currentBeatTimesSeconds) { _, _ in
            applyStreamingTempoAndAlignment()
        }
        .onReceive(audio.trackEndedSubject) { _ in
            handleLocalPlaylistTrackEnded()
        }
        .animation(.easeInOut(duration: 0.2), value: audio.state)
        .animation(.easeInOut(duration: 0.3), value: audio.errorMessage)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Cadenza")
                .font(.cadenzaTitle2)
                .foregroundColor(.cadenzaTextPrimary)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Track Info / Empty State

    @ViewBuilder
    private var trackInfoSection: some View {
        if let streamingTitle = streaming.title {
            VStack(spacing: 6) {
                Text(streamingTitle)
                    .font(.cadenzaTitle2)
                    .foregroundColor(.cadenzaTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let artist = streaming.artist {
                    Text(artist)
                        .font(.cadenzaBody)
                        .foregroundColor(.cadenzaTextSecondary)
                        .lineLimit(1)
                }

                Label("Apple Music 스트리밍 - 피치락 미지원", systemImage: "cloud.fill")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaWarning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.cadenzaWarning.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        } else if let title = nowPlaying.title {
            // 곡 로드됨
            VStack(spacing: 6) {
                Text(title)
                    .font(.cadenzaTitle2)
                    .foregroundColor(.cadenzaTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let artist = nowPlaying.artist {
                    Text(artist)
                        .font(.cadenzaBody)
                        .foregroundColor(.cadenzaTextSecondary)
                        .lineLimit(1)
                }

                // 상태 배지
                Label("키 락 ON", systemImage: "music.note")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.cadenzaAccent.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.top, 4)

                if let queueContext = localPlaylist.queueContext {
                    VStack(spacing: 4) {
                        Label(
                            "\(queueContext.currentIndex + 1) / \(queueContext.totalCount)",
                            systemImage: localPlaylist.isShuffled ? "shuffle" : "list.bullet"
                        )
                        .font(.cadenzaCaption)
                        .foregroundColor(localPlaylist.isShuffled ? .cadenzaAccent : .cadenzaTextSecondary)

                        if let nextTitle = queueContext.nextTitle {
                            Text("다음 곡: \(nextTitle)")
                                .font(.cadenzaCaption)
                                .foregroundColor(.cadenzaTextTertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
        } else if audio.isMetronomeOnlyMode {
            VStack(spacing: 8) {
                Image(systemName: "metronome")
                    .font(.system(size: 32))
                    .foregroundColor(.cadenzaAccent)

                Text("메트로놈 모드")
                    .font(.cadenzaTitle2)
                    .foregroundColor(.cadenzaTextPrimary)

                Text("파일 없이 목표 BPM으로 클릭을 재생합니다")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 20)
        } else {
            // Empty state (DESIGN.md 2.2.1)
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 32))
                    .foregroundColor(.cadenzaTextTertiary)

                Text("음악을 선택하거나\n메트로놈만 사용하세요")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextTertiary)
                    .multilineTextAlignment(.center)

                Text("지원 형식: mp3, m4a, wav")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
            }
            .padding(.vertical, 20)
        }
    }

    private var originalBPMControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("원본 BPM")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                if audio.needsOriginalBPMInput {
                    Text("입력 권장")
                        .font(.cadenzaCaption)
                        .foregroundColor(.cadenzaWarning)
                }
            }

            HStack(spacing: 10) {
                TextField("예: 172", text: $originalBPMText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(applyOriginalBPM)

                Button("적용", action: applyOriginalBPM)
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaBackground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(canApplyOriginalBPM ? Color.cadenzaAccent : Color.cadenzaTextTertiary)
                    .clipShape(Capsule())
                    .disabled(!canApplyOriginalBPM)
            }

            Text(nowPlaying.originalBPMSource.helperText)
                .font(.cadenzaCaption)
                .foregroundColor(audio.needsOriginalBPMInput ? .cadenzaWarning : .cadenzaTextSecondary)
        }
    }

    private var playbackProgressSection: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { isSeekingPlayback ? seekPreviewProgress : nowPlaying.playbackProgress },
                    set: { seekPreviewProgress = $0 }
                ),
                in: 0...1,
                onEditingChanged: handleSeekEditingChanged
            )
            .tint(.cadenzaAccent)

            HStack {
                Text(formattedTime(displayedPlaybackTime))
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
                Spacer()
                Text(formattedTime(nowPlaying.playbackDuration))
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("재생 진행")
        .accessibilityValue("\(formattedTime(displayedPlaybackTime)) / \(formattedTime(nowPlaying.playbackDuration))")
    }

    private var syncDebugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sync Debug")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                Text(cacheLabel)
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
            }

            HStack {
                debugMetric(label: "Offset", value: "\(Int((audio.effectiveBeatOffset * 1000).rounded()))ms")
                Spacer()
                debugMetric(label: "Nudge", value: signedMilliseconds(audio.manualBeatOffsetNudge))
                Spacer()
                debugMetric(label: "Confidence", value: confidenceLabel)
            }

            HStack(spacing: 10) {
                Button("지금 맞추기") {
                    audio.alignBeatOffsetToCurrentTap()
                }
                .buttonStyle(SyncNudgeButtonStyle())

                Button("-40ms") {
                    audio.nudgeBeatOffset(by: -40)
                }
                .buttonStyle(SyncNudgeButtonStyle())

                Button("리셋") {
                    audio.resetBeatOffsetNudge()
                }
                .buttonStyle(SyncNudgeButtonStyle())

                Button("+40ms") {
                    audio.nudgeBeatOffset(by: 40)
                }
                .buttonStyle(SyncNudgeButtonStyle())
            }

            Text("분석값이 어긋나면 곡별로 미세 보정되고 다음 재생에도 그대로 적용됩니다.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
        }
    }

    // MARK: - Metronome Controls

    private var metronomeControls: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $audio.metronomeEnabled) {
                Text("메트로놈")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
            }
            .tint(.cadenzaAccent)
            .accessibilityLabel("메트로놈")
            .accessibilityValue(audio.metronomeEnabled ? "켜짐" : "꺼짐")

            HStack {
                Text("클릭")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
                Spacer()
                Text("\(Int(audio.metronomeBPM)) BPM")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
            }

            VStack(spacing: 6) {
                HStack {
                    Text("볼륨")
                        .font(.cadenzaCaption)
                        .foregroundColor(.cadenzaTextSecondary)
                    Spacer()
                    Text("\(Int(audio.metronomeVolume * 100))%")
                        .font(.cadenzaCaption)
                        .foregroundColor(.cadenzaTextTertiary)
                }

                Slider(
                    value: Binding(
                        get: { Double(audio.metronomeVolume) },
                        set: { audio.metronomeVolume = Float($0) }
                    ),
                    in: 0...1
                )
                .tint(.cadenzaAccent)
                .accessibilityLabel("메트로놈 볼륨")
                .accessibilityValue("\(Int(audio.metronomeVolume * 100)) 퍼센트")
            }
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 16) {
            // 재생/정지 버튼 — 큰 버튼, 엄지 도달 영역 (DESIGN.md 2.1)
            HStack(spacing: 22) {
                if streaming.hasSong {
                    circularPlaybackButton(
                        systemImage: "backward.fill",
                        accessibilityLabel: "이전 곡",
                        isDisabled: streaming.isLoading,
                        action: handleStreamingPrevious
                    )
                } else if localPlaylist.count > 1 {
                    circularPlaybackButton(
                        systemImage: "backward.fill",
                        accessibilityLabel: "이전 MP3",
                        isDisabled: !localPlaylist.canMovePrevious || audio.state == .loading,
                        action: handleLocalPlaylistPrevious
                    )
                }

                Button(action: handlePrimaryPlayback) {
                    Image(systemName: primaryPlaybackIcon)
                        .font(.system(size: 36))
                        .foregroundColor(.cadenzaBackground)
                        .frame(width: 80, height: 80)
                        .background(
                            isPlayable ? Color.cadenzaAccent : Color.cadenzaTextTertiary
                        )
                        .clipShape(Circle())
                }
                .disabled(!isPlayable)
                .accessibilityLabel(primaryPlaybackLabel)

                if streaming.hasSong {
                    circularPlaybackButton(
                        systemImage: "forward.fill",
                        accessibilityLabel: "다음 곡",
                        isDisabled: streaming.isLoading,
                        action: handleStreamingNext
                    )
                } else if localPlaylist.count > 1 {
                    circularPlaybackButton(
                        systemImage: "forward.fill",
                        accessibilityLabel: "다음 MP3",
                        isDisabled: !localPlaylist.canMoveNext || audio.state == .loading,
                        action: handleLocalPlaylistNext
                    )
                }
            }

            if audio.metronomeEnabled && (audio.state == .playing || streaming.isPlaying) {
                Label("메트로놈 동작 중", systemImage: "metronome")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
            }

            if localPlaylist.canShuffle && !streaming.hasSong {
                Button(action: handleLocalPlaylistShuffleToggle) {
                    Label(localPlaylist.isShuffled ? "셔플 켜짐" : "셔플", systemImage: "shuffle")
                        .font(.cadenzaBody)
                        .foregroundColor(localPlaylist.isShuffled ? .cadenzaBackground : .cadenzaAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(localPlaylist.isShuffled ? Color.cadenzaAccent : Color.cadenzaBackgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.cadenzaDivider, lineWidth: 1)
                        )
                }
                .disabled(audio.state == .loading)
                .opacity(audio.state == .loading ? 0.45 : 1.0)
                .padding(.horizontal, 20)
                .accessibilityLabel(localPlaylist.isShuffled ? "셔플 끄기" : "셔플 켜기")
            }

            // 파일 선택
            Button(action: {
                audio.clearError()
                streaming.stop()
                audio.stopExternalMetronomePlayback()
                showFilePicker = true
            }) {
                Label("파일 선택", systemImage: "folder")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing)
            .opacity(audio.state == .playing ? 0.4 : 1.0)
            .accessibilityLabel("파일 선택")

            Button(action: {
                audio.clearError()
                streaming.stop()
                audio.stopExternalMetronomePlayback()
                showPlaylistFilePicker = true
            }) {
                Label("MP3 플레이리스트", systemImage: "music.note.list")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing)
            .opacity(audio.state == .playing ? 0.4 : 1.0)
            .accessibilityLabel("MP3 플레이리스트 만들기")

            Button(action: {
                audio.clearError()
                streaming.stop()
                audio.stopExternalMetronomePlayback()
                showAppleMusicPicker = true
            }) {
                Label(
                    isImportingAppleMusic ? "Apple Music 불러오는 중" : "Apple Music 보관함",
                    systemImage: "music.note.list"
                )
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing || isImportingAppleMusic)
            .opacity(audio.state == .playing || isImportingAppleMusic ? 0.4 : 1.0)
            .accessibilityLabel("Apple Music 보관함")

            Button(action: {
                audio.clearError()
                showAppleMusicStreamingSearch = true
            }) {
                Label("Apple Music 곡 검색", systemImage: "magnifyingglass")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing || streaming.isLoading)
            .opacity(audio.state == .playing || streaming.isLoading ? 0.4 : 1.0)
            .accessibilityLabel("Apple Music 곡 검색")

            Button(action: {
                audio.clearError()
                showAppleMusicStreamingPlaylists = true
            }) {
                Label("Apple Music 플레이리스트", systemImage: "cloud")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing || streaming.isLoading)
            .opacity(audio.state == .playing || streaming.isLoading ? 0.4 : 1.0)
            .accessibilityLabel("Apple Music 플레이리스트")

            sampleTrackButtons

            Text("파일/다운로드 곡은 피치락, 스트리밍 곡은 Apple Music 플레이어로 재생")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
        }
    }

    private func circularPlaybackButton(
        systemImage: String,
        accessibilityLabel: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.cadenzaAccent)
                .frame(width: 52, height: 52)
                .background(Color.cadenzaBackgroundSecondary)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.cadenzaDivider, lineWidth: 1)
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sampleTrackButtons: some View {
        VStack(spacing: 8) {
            Text("샘플 오디오")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(SampleTrackPreset.allCases) { preset in
                    Button(action: { loadSampleTrack(preset) }) {
                        Text(preset.title)
                            .font(.cadenzaCaption)
                            .foregroundColor(.cadenzaTextPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.cadenzaBackgroundSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(audio.state == .playing)
                    .opacity(audio.state == .playing ? 0.4 : 1.0)
                    .accessibilityLabel("\(preset.title) 샘플")
                }
            }
        }
    }

    private var isPlayable: Bool {
        if streaming.isLoading {
            return false
        }
        if streaming.hasSong {
            return true
        }
        switch audio.state {
        case .ready, .paused, .playing:
            return true
        case .idle:
            return audio.canStartPlayback
        case .loading, .error:
            return false
        }
    }

    // MARK: - Error Banner (DESIGN.md 2.2.2)

    private func errorBanner(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.cadenzaWarning)
            Text(message)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextPrimary)
            Spacer()
            Button("다른 파일 선택") {
                audio.clearError()
                showFilePicker = true
            }
            .font(.cadenzaCaption)
            .foregroundColor(.cadenzaWarning)
        }
        .padding(12)
        .background(Color.cadenzaBackgroundSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cadenzaWarning, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - File Selection

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            audio.clearError()
            streaming.stop()
            clearLocalPlaylist()
            Task {
                await audio.loadFile(url: url)
            }
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            audio.presentError("파일 가져오기에 실패했습니다. 지원 형식은 mp3, m4a, wav 입니다")
        }
    }

    private func handlePlaylistFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let sortedURLs = urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            guard !sortedURLs.isEmpty else { return }
            audio.clearError()
            streaming.stop()
            audio.stopExternalMetronomePlayback()
            guard let item = localPlaylist.replace(withFileURLs: sortedURLs) else { return }
            updateLocalPlaylistEndBehavior()
            Task {
                await loadLocalPlaylistItem(item, autoPlay: false)
            }
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            audio.presentError("MP3 플레이리스트를 만들 수 없습니다")
        }
    }

    private func loadSampleTrack(_ preset: SampleTrackPreset = .clickLoop) {
        audio.clearError()
        streaming.stop()
        audio.stopExternalMetronomePlayback()
        clearLocalPlaylist()
        Task {
            await audio.loadSampleTrack(preset)
        }
    }

    private func loadAppleMusicTrack(_ track: AppleMusicTrack) {
        audio.clearError()
        streaming.stop()
        clearLocalPlaylist()
        isImportingAppleMusic = true
        Task {
            do {
                let resolvedURL = try await AssetResolver.shared.resolve(track)
                await audio.loadResolvedTrack(
                    url: resolvedURL,
                    title: track.title,
                    artist: track.artist,
                    bpmHint: track.beatsPerMinute.map(Double.init)
                )
            } catch {
                audio.presentError(error.localizedDescription)
            }
            isImportingAppleMusic = false
        }
    }

    private func playAppleMusicStream(_ song: Song) {
        audio.clearError()
        clearLocalPlaylist()
        audio.setStreamingBeatAlignment(bpm: nil, beatOffsetSeconds: nil)
        if audio.state == .playing {
            audio.pause()
        }
        Task {
            await streaming.play(song, playbackRate: audio.playbackRate)
            syncStreamingMetronome()
        }
    }

    private func playAppleMusicPlaylist(_ playlist: Playlist, entry: Playlist.Entry) {
        audio.clearError()
        clearLocalPlaylist()
        audio.setStreamingBeatAlignment(bpm: nil, beatOffsetSeconds: nil)
        if audio.state == .playing {
            audio.pause()
        }
        Task {
            await streaming.play(playlist: playlist, startingAt: entry, playbackRate: audio.playbackRate)
            syncStreamingMetronome()
        }
    }

    private func handlePrimaryPlayback() {
        if streaming.hasSong {
            Task {
                await streaming.togglePlayback(playbackRate: audio.playbackRate)
                syncStreamingMetronome()
            }
        } else {
            updateLocalPlaylistEndBehavior()
            audio.togglePlayPause()
        }
    }

    private func handleStreamingNext() {
        Task {
            await streaming.skipToNext(playbackRate: audio.playbackRate)
            applyStreamingTempoAndAlignment()
        }
    }

    private func handleStreamingPrevious() {
        Task {
            await streaming.skipToPrevious(playbackRate: audio.playbackRate)
            applyStreamingTempoAndAlignment()
        }
    }

    private func handleLocalPlaylistNext() {
        let shouldAutoPlay = audio.state == .playing
        guard let item = localPlaylist.moveToNext() else { return }
        updateLocalPlaylistEndBehavior()
        Task {
            await loadLocalPlaylistItem(item, autoPlay: shouldAutoPlay)
        }
    }

    private func handleLocalPlaylistPrevious() {
        let shouldAutoPlay = audio.state == .playing
        guard let item = localPlaylist.moveToPrevious() else { return }
        updateLocalPlaylistEndBehavior()
        Task {
            await loadLocalPlaylistItem(item, autoPlay: shouldAutoPlay)
        }
    }

    private func handleLocalPlaylistShuffleToggle() {
        guard localPlaylist.toggleShuffle() != nil else { return }
        updateLocalPlaylistEndBehavior()
    }

    private func handleLocalPlaylistTrackEnded() {
        guard !localPlaylist.isEmpty else { return }
        guard let item = localPlaylist.moveToNext() else {
            updateLocalPlaylistEndBehavior()
            return
        }
        updateLocalPlaylistEndBehavior()
        Task {
            await loadLocalPlaylistItem(item, autoPlay: true)
        }
    }

    private func loadLocalPlaylistItem(_ item: QueueItem, autoPlay: Bool) async {
        guard case .file(let url) = item.source else { return }
        audio.clearError()
        await audio.loadFile(url: url)
        updateLocalPlaylistEndBehavior()
        guard autoPlay, audio.state == .ready else { return }
        audio.play()
    }

    private func clearLocalPlaylist() {
        localPlaylist = LocalFilePlaylist()
        audio.playbackEndBehavior = .loop
    }

    private func updateLocalPlaylistEndBehavior() {
        audio.playbackEndBehavior = localPlaylist.isEmpty ? .loop : .notify
    }

    private func syncStreamingMetronome() {
        guard streaming.hasSong, streaming.isPlaying, audio.metronomeEnabled else {
            audio.stopExternalMetronomePlayback()
            return
        }

        audio.startExternalMetronomePlayback(alignedToSourceTime: streaming.playbackTime)
    }

    private func applyStreamingTempoAndAlignment(bpm: Double? = nil) {
        guard streaming.hasSong else { return }
        audio.setStreamingBeatAlignment(
            bpm: bpm ?? streaming.currentBPM,
            source: streaming.currentBPMSource ?? .metadata,
            beatOffsetSeconds: streaming.currentBeatOffsetSeconds,
            beatTimesSeconds: streaming.currentBeatTimesSeconds
        )
        syncStreamingMetronome()
    }

    private var primaryPlaybackIcon: String {
        if streaming.hasSong {
            return streaming.isPlaying ? "pause.fill" : "play.fill"
        }
        return audio.state == .playing ? "pause.fill" : "play.fill"
    }

    private var primaryPlaybackLabel: String {
        if streaming.hasSong {
            return streaming.isPlaying ? "Apple Music 일시정지" : "Apple Music 재생"
        }
        return audio.state == .playing ? "정지" : "재생"
    }

    private var canApplyOriginalBPM: Bool {
        guard let bpm = Double(originalBPMText) else { return false }
        return bpm >= BPMRange.originalMin && bpm <= BPMRange.originalMax
    }

    private func syncOriginalBPMText() {
        originalBPMText = "\(Int(audio.originalBPM.rounded()))"
    }

    private func applyOriginalBPM() {
        guard let bpm = Double(originalBPMText) else {
            audio.presentError("원본 BPM은 30~300 사이 숫자로 입력하세요")
            return
        }
        audio.setOriginalBPM(bpm)
    }

    private func debugMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
            Text(value)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextPrimary)
        }
    }

    private var cacheLabel: String {
        switch audio.beatAlignmentCacheStatus {
        case .hit:
            return "cache hit"
        case .miss:
            return "cache miss"
        case .none:
            return "cache none"
        }
    }

    private var confidenceLabel: String {
        guard let confidence = audio.beatAlignmentConfidence else { return "-" }
        return "\(Int((confidence * 100).rounded()))%"
    }

    private func signedMilliseconds(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return milliseconds >= 0 ? "+\(milliseconds)ms" : "\(milliseconds)ms"
    }

    private var displayedPlaybackTime: TimeInterval {
        guard isSeekingPlayback else { return audio.currentPlaybackTime }
        return nowPlaying.playbackDuration * seekPreviewProgress
    }

    private func handleSeekEditingChanged(_ isEditing: Bool) {
        isSeekingPlayback = isEditing
        if isEditing {
            seekPreviewProgress = audio.playbackProgress
        } else {
            audio.seek(toProgress: seekPreviewProgress)
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

// MARK: - UTType extensions for fileImporter

extension UTType {
    static let mp3 = UTType(filenameExtension: "mp3") ?? .audio
    static let mpeg4Audio = UTType("public.mpeg-4-audio") ?? .audio
    static let wav = UTType(filenameExtension: "wav") ?? .audio
}

private struct SyncNudgeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cadenzaCaption)
            .foregroundColor(.cadenzaTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cadenzaBackgroundSecondary.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(Capsule())
    }
}
