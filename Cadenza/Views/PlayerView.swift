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
    @State private var isLocalRepeatEnabled = false

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
                        // 곡 정보/선택
                        trackInfoSection
                            .padding(.top, 20)

                        // BPM 디스플레이
                        BPMDisplayView(
                            targetBPM: audio.targetBPM,
                            originalBPM: nowPlaying.originalBPM,
                            playbackRate: audio.playbackRate,
                            originalBPMSource: nowPlaying.originalBPMSource,
                            cadenceFit: currentCadenceFit
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
                        }

                        if audio.hasLoadedTrack || streaming.hasSong {
                            Divider().background(Color.cadenzaDivider)

                            originalBPMControls
                                .padding(.horizontal, 20)

                            if let pair = ambiguousBPMOctaveChoicePair {
                                Divider().background(Color.cadenzaDivider)

                                bpmChoiceSection(pair: pair)
                                    .padding(.horizontal, 20)
                            }

                            Divider().background(Color.cadenzaDivider)

                            beatSyncStatusSection
                                .padding(.horizontal, 20)
                        }

                        Divider().background(Color.cadenzaDivider)

                        // 플레이어 컨트롤
                        playbackControls

                        Divider().background(Color.cadenzaDivider)

                        metronomeControls
                            .padding(.horizontal, 20)

                        Divider().background(Color.cadenzaDivider)

                        trackSelectionControls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                    }
                    .padding(.bottom, 32)
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
            AppleMusicStreamingPlaylistView { playlist, entry, entries in
                playAppleMusicPlaylist(playlist, entry: entry, entries: entries)
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
        .onChange(of: streaming.currentBeatSyncStatus) { _, _ in
            applyStreamingTempoAndAlignment()
        }
        .onChange(of: audio.originalBPM) { _, _ in
            applyAutoBPMDefaultIfNeeded()
        }
        .onChange(of: audio.originalBPMSource) { _, _ in
            applyAutoBPMDefaultIfNeeded()
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
            VStack(spacing: 8) {
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

                trackSelectionControls
                    .padding(.top, 2)

                playbackControls
                    .padding(.top, 4)

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
            // 곡 로드됨 — 곡 정보가 주인공 (runner-first redesign)
            VStack(spacing: 6) {
                Text(title)
                    .font(.cadenzaTrackTitle)
                    .foregroundColor(.cadenzaTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let artist = nowPlaying.artist {
                    Text(artist)
                        .font(.cadenzaBody)
                        .foregroundColor(.cadenzaTextSecondary)
                        .lineLimit(1)
                }

                trackSelectionControls
                    .padding(.top, 2)

                playbackControls
                    .padding(.top, 4)

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

                trackSelectionControls
                    .padding(.top, 2)

                playbackControls
                    .padding(.top, 4)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 20)
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

                trackSelectionControls
                    .padding(.top, 2)

                playbackControls
                    .padding(.top, 4)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 20)
        }
    }

    private var trackSelectionControls: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                selectionButton(
                    title: "파일 선택",
                    systemImage: "folder",
                    isDisabled: audio.state == .playing,
                    action: {
                        audio.clearError()
                        streaming.stop()
                        audio.stopExternalMetronomePlayback()
                        showFilePicker = true
                    }
                )
                .accessibilityLabel("파일 선택")

                selectionButton(
                    title: "MP3 플레이리스트",
                    systemImage: "music.note.list",
                    isDisabled: audio.state == .playing,
                    action: {
                        audio.clearError()
                        streaming.stop()
                        audio.stopExternalMetronomePlayback()
                        showPlaylistFilePicker = true
                    }
                )
                .accessibilityLabel("MP3 플레이리스트 만들기")

                selectionButton(
                    title: isImportingAppleMusic ? "Apple Music 불러오는 중" : "Apple Music 보관함",
                    systemImage: "music.note.list",
                    isDisabled: audio.state == .playing || isImportingAppleMusic,
                    action: {
                        audio.clearError()
                        streaming.stop()
                        audio.stopExternalMetronomePlayback()
                        showAppleMusicPicker = true
                    }
                )
                .accessibilityLabel("Apple Music 보관함")

                selectionButton(
                    title: "Apple Music 곡 검색",
                    systemImage: "magnifyingglass",
                    isDisabled: audio.state == .playing || streaming.isLoading,
                    action: {
                        audio.clearError()
                        showAppleMusicStreamingSearch = true
                    }
                )
                .accessibilityLabel("Apple Music 곡 검색")

                selectionButton(
                    title: "Apple Music 플레이리스트",
                    systemImage: "cloud",
                    isDisabled: audio.state == .playing || streaming.isLoading,
                    action: {
                        audio.clearError()
                        showAppleMusicStreamingPlaylists = true
                    }
                )
                .accessibilityLabel("Apple Music 플레이리스트")
            }
        }
    }

    private func selectionButton(
        title: String,
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 42)
                .padding(.horizontal, 10)
                .background(Color.cadenzaBackgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cadenzaDivider, lineWidth: 1)
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
    }

    private var originalBPMControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("원본 BPM")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                if needsOriginalBPMInput {
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
                .foregroundColor(needsOriginalBPMInput ? .cadenzaWarning : .cadenzaTextSecondary)
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
                    .font(.cadenzaMonoTimecode)
                    .foregroundColor(.cadenzaTextSecondary)
                Spacer()
                Text(formattedTime(nowPlaying.playbackDuration))
                    .font(.cadenzaMonoTimecode)
                    .foregroundColor(.cadenzaTextTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("재생 진행")
        .accessibilityValue("\(formattedTime(displayedPlaybackTime)) / \(formattedTime(nowPlaying.playbackDuration))")
    }

    private var ambiguousBPMOctaveChoicePair: BPMOctaveChoicePair? {
        guard nowPlaying.originalBPMSource != .manual else { return nil }
        return BPMOctaveChoice.ambiguousPair(for: nowPlaying.originalBPM)
    }

    private var currentCadenceFit: RunningCadenceFit? {
        guard audio.hasLoadedTrack || streaming.hasSong else { return nil }
        guard nowPlaying.originalBPMSource != .assumedDefault else { return nil }

        let previewSignal: RunningPreviewSignal?
        if streaming.hasSong {
            previewSignal = RunningPreviewSignal(
                confidence: streaming.currentBeatAlignmentConfidence,
                beatTimesSeconds: streaming.currentBeatTimesSeconds
            )
        } else if let confidence = audio.beatAlignmentConfidence {
            previewSignal = RunningPreviewSignal(
                confidence: confidence,
                beatTimesSeconds: []
            )
        } else {
            previewSignal = nil
        }

        return RunningCadenceFit.evaluate(
            originalBPM: nowPlaying.originalBPM,
            targetCadence: audio.targetBPM,
            previewSignal: previewSignal
        )
    }

    private func bpmChoiceSection(pair: BPMOctaveChoicePair) -> some View {
        let goal = audio.targetBPM
        let defaultChoice = BPMOctaveChoice.defaultChoice(for: pair, goalCadence: goal)
        let activeBPM = nowPlaying.originalBPM.rounded()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BPM 확인")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                Text("자동 선택됨")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
            }

            HStack(spacing: 10) {
                bpmChoiceButton(bpm: pair.lower, activeBPM: activeBPM, defaultBPM: defaultChoice)
                bpmChoiceButton(bpm: pair.upper, activeBPM: activeBPM, defaultBPM: defaultChoice)
            }

            Text("목표 \(Int(goal.rounded())) BPM에 가까운 \(Int(defaultChoice)) BPM을 적용했습니다. 다른 값을 누르면 변경됩니다.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
        }
    }

    private func bpmChoiceButton(bpm: Double, activeBPM: Double, defaultBPM: Double) -> some View {
        let isActive = abs(activeBPM - bpm) < 0.5
        let label = "\(Int(bpm)) BPM"
        return Button {
            confirmBPMChoice(bpm)
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.cadenzaBody)
                if abs(bpm - defaultBPM) < 0.5 {
                    Text("목표에 가까움")
                        .font(.cadenzaCaption)
                        .foregroundColor(isActive ? .cadenzaBackground : .cadenzaTextTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isActive ? Color.cadenzaAccent : Color.cadenzaBackgroundSecondary)
            .foregroundColor(isActive ? .cadenzaBackground : .cadenzaTextPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("\(label) 적용")
    }

    private func confirmBPMChoice(_ bpm: Double) {
        if streaming.hasSong {
            _ = streaming.setManualBPM(bpm)
            audio.setStreamingBeatAlignment(
                bpm: bpm,
                source: .manual,
                beatOffsetSeconds: nil
            )
        } else {
            audio.setOriginalBPM(bpm)
        }
        originalBPMText = "\(Int(bpm))"
    }

    private func applyAutoBPMDefaultIfNeeded() {
        guard let pair = ambiguousBPMOctaveChoicePair else { return }
        let choice = BPMOctaveChoice.defaultChoice(for: pair, goalCadence: audio.targetBPM)
        if streaming.hasSong {
            // Streaming controller already published a BPM; only adjust if it's the
            // wrong octave. Avoid touching streaming's source-of-truth except via
            // the audio manager's lighter auto-default path.
            audio.applyAutoBPMDefault(choice)
        } else {
            audio.applyAutoBPMDefault(choice)
        }
    }

    private var beatSyncStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("박자 상태")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                Text(currentBeatSyncStatus.labelText)
                    .font(.cadenzaCaption)
                    .foregroundColor(beatSyncStatusColor)
            }

            HStack {
                beatSyncMetric(label: "신뢰도", value: beatSyncConfidenceLabel)
                Spacer(minLength: 16)
                beatSyncMetric(label: "방식", value: currentBeatSyncStatus.usesBeatGrid ? "박자 기준" : "미실행")
            }

            Text(currentBeatSyncStatus.helperText(issue: currentBeatSyncIssue))
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
            HStack(spacing: 14) {
                if streaming.hasSong {
                    circularToggleButton(
                        systemImage: "shuffle",
                        accessibilityLabel: streaming.isShuffleEnabled ? "Apple Music 셔플 끄기" : "Apple Music 셔플 켜기",
                        isOn: streaming.isShuffleEnabled,
                        isDisabled: !streaming.canShuffle || streaming.isLoading,
                        action: handleStreamingShuffleToggle
                    )

                    circularPlaybackButton(
                        systemImage: "backward.fill",
                        accessibilityLabel: "이전 곡",
                        isDisabled: streaming.isLoading,
                        action: handleStreamingPrevious
                    )
                } else {
                    circularToggleButton(
                        systemImage: "shuffle",
                        accessibilityLabel: localPlaylist.isShuffled ? "셔플 끄기" : "셔플 켜기",
                        isOn: localPlaylist.isShuffled,
                        isDisabled: !localPlaylist.canShuffle || audio.state == .loading,
                        action: handleLocalPlaylistShuffleToggle
                    )

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
                    circularToggleButton(
                        systemImage: "repeat",
                        accessibilityLabel: streaming.isRepeatEnabled ? "Apple Music 반복 끄기" : "Apple Music 반복 켜기",
                        isOn: streaming.isRepeatEnabled,
                        isDisabled: !streaming.canRepeat || streaming.isLoading,
                        action: handleStreamingRepeatToggle
                    )
                } else {
                    circularPlaybackButton(
                        systemImage: "forward.fill",
                        accessibilityLabel: "다음 MP3",
                        isDisabled: !localPlaylist.canMoveNext || audio.state == .loading,
                        action: handleLocalPlaylistNext
                    )
                    circularToggleButton(
                        systemImage: "repeat",
                        accessibilityLabel: isLocalRepeatEnabled ? "반복 끄기" : "반복 켜기",
                        isOn: isLocalRepeatEnabled,
                        isDisabled: !hasLocalPlaybackItem || audio.state == .loading,
                        action: handleLocalRepeatToggle
                    )
                }
            }

            if audio.metronomeEnabled && currentBeatSyncStatus.usesBeatGrid && (audio.state == .playing || streaming.isPlaying) {
                Label("메트로놈 동작 중", systemImage: "metronome")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
            }
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

    private func circularToggleButton(
        systemImage: String,
        accessibilityLabel: String,
        isOn: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isOn ? .cadenzaBackground : .cadenzaAccent)
                .frame(width: 52, height: 52)
                .background(isOn ? Color.cadenzaAccent : Color.cadenzaBackgroundSecondary)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.cadenzaDivider, lineWidth: 1)
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "켜짐" : "꺼짐")
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

    private var hasLocalPlaybackItem: Bool {
        !streaming.hasSong && (audio.hasLoadedTrack || !localPlaylist.isEmpty)
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
                updateLocalPlaylistEndBehavior()
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
                updateLocalPlaylistEndBehavior()
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
            await streaming.play(song, playbackRate: 1.0)
            applyStreamingTempoAndAlignment()
        }
    }

    private func playAppleMusicPlaylist(_ playlist: Playlist, entry: Playlist.Entry, entries: [Playlist.Entry]) {
        audio.clearError()
        clearLocalPlaylist()
        audio.setStreamingBeatAlignment(bpm: nil, beatOffsetSeconds: nil)
        if audio.state == .playing {
            audio.pause()
        }
        Task {
            await streaming.play(
                playlist: playlist,
                startingAt: entry,
                playbackRate: 1.0,
                preloadedEntries: entries
            )
            applyStreamingTempoAndAlignment()
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
            await streaming.skipToNext(playbackRate: 1.0)
            applyStreamingTempoAndAlignment()
        }
    }

    private func handleStreamingPrevious() {
        Task {
            await streaming.skipToPrevious(playbackRate: 1.0)
            applyStreamingTempoAndAlignment()
        }
    }

    private func handleStreamingShuffleToggle() {
        streaming.toggleShuffle()
    }

    private func handleStreamingRepeatToggle() {
        streaming.toggleRepeat()
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

    private func handleLocalRepeatToggle() {
        isLocalRepeatEnabled.toggle()
        updateLocalPlaylistEndBehavior()
    }

    private func handleLocalPlaylistTrackEnded() {
        guard !localPlaylist.isEmpty else { return }
        guard let item = localPlaylist.moveToNext() else {
            if isLocalRepeatEnabled, let firstItem = localPlaylist.moveToStart() {
                updateLocalPlaylistEndBehavior()
                Task {
                    await loadLocalPlaylistItem(firstItem, autoPlay: true)
                }
                return
            }
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
        updateLocalPlaylistEndBehavior()
    }

    private func updateLocalPlaylistEndBehavior() {
        if localPlaylist.isEmpty {
            audio.playbackEndBehavior = isLocalRepeatEnabled ? .loop : .notify
        } else {
            audio.playbackEndBehavior = .notify
        }
    }

    private func syncStreamingMetronome() {
        guard streaming.hasSong,
              streaming.isPlaying,
              audio.metronomeEnabled,
              streaming.currentBeatSyncStatus.usesBeatGrid else {
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
            beatTimesSeconds: streaming.currentBeatTimesSeconds,
            confidence: streaming.currentBeatAlignmentConfidence
        )
        streaming.applyPlaybackRate(audio.playbackRate)
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

    private var needsOriginalBPMInput: Bool {
        if streaming.hasSong {
            return audio.originalBPMSource == .assumedDefault
        }
        return audio.needsOriginalBPMInput
    }

    private func syncOriginalBPMText() {
        originalBPMText = "\(Int(audio.originalBPM.rounded()))"
    }

    private func applyOriginalBPM() {
        guard let bpm = Double(originalBPMText) else {
            audio.presentError("원본 BPM은 30~300 사이 숫자로 입력하세요")
            return
        }

        if streaming.hasSong {
            guard streaming.setManualBPM(bpm) else { return }
            applyStreamingTempoAndAlignment(bpm: bpm)
        } else {
            audio.setOriginalBPM(bpm)
        }
    }

    private func beatSyncMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
            Text(value)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextPrimary)
        }
    }

    private var currentBeatSyncStatus: BeatSyncStatus {
        streaming.hasSong ? streaming.currentBeatSyncStatus : audio.beatSyncStatus
    }

    private var currentBeatSyncIssue: BeatSyncReliabilityIssue? {
        streaming.hasSong ? streaming.currentBeatSyncIssue : audio.beatSyncIssue
    }

    private var beatSyncConfidenceLabel: String {
        let confidence = streaming.hasSong
            ? streaming.currentBeatAlignmentConfidence
            : audio.beatAlignmentConfidence
        guard let confidence else { return "-" }
        return "\(Int((confidence * 100).rounded()))%"
    }

    private var beatSyncStatusColor: Color {
        switch currentBeatSyncStatus {
        case .automaticBeatSync:
            return .cadenzaAccent
        case .bpmOnly:
            return .cadenzaTextSecondary
        case .needsConfirmation, .unstableBeatGrid:
            return .cadenzaWarning
        }
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
