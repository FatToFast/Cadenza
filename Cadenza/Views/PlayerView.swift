import SwiftUI
import UniformTypeIdentifiers

/// 메인 플레이어 화면 (DESIGN.md 2.1)
struct PlayerView: View {
    @EnvironmentObject private var audio: AudioManager
    @State private var showFilePicker = false

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
                            originalBPM: audio.originalBPM,
                            playbackRate: audio.playbackRate,
                            hasBPMFromMetadata: audio.hasBPMFromMetadata
                        )
                        .padding(.vertical, 16)

                        // BPM 슬라이더
                        BPMSliderView(targetBPM: $audio.targetBPM)
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
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
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
        if let title = audio.trackTitle {
            // 곡 로드됨
            VStack(spacing: 6) {
                Text(title)
                    .font(.cadenzaTitle2)
                    .foregroundColor(.cadenzaTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let artist = audio.trackArtist {
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
            }
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
            }
            .padding(.vertical, 20)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 16) {
            // 재생/정지 버튼 — 큰 버튼, 엄지 도달 영역 (DESIGN.md 2.1)
            Button(action: { audio.togglePlayPause() }) {
                Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.cadenzaBackground)
                    .frame(width: 80, height: 80)
                    .background(
                        isPlayable ? Color.cadenzaAccent : Color.cadenzaTextTertiary
                    )
                    .clipShape(Circle())
            }
            .disabled(!isPlayable)
            .accessibilityLabel(audio.state == .playing ? "정지" : "재생")

            // 파일 선택
            Button(action: { showFilePicker = true }) {
                Label("파일 선택", systemImage: "folder")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaAccent)
            }
            .disabled(audio.state == .playing)
            .opacity(audio.state == .playing ? 0.4 : 1.0)
        }
    }

    private var isPlayable: Bool {
        audio.state == .ready || audio.state == .paused || audio.state == .playing
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
            Task {
                await audio.loadFile(url: url)
            }
        case .failure:
            break // 사용자가 취소한 경우
        }
    }
}

// MARK: - UTType extensions for fileImporter

extension UTType {
    static let mp3 = UTType(filenameExtension: "mp3") ?? .audio
    static let mpeg4Audio = UTType("public.mpeg-4-audio") ?? .audio
    static let wav = UTType(filenameExtension: "wav") ?? .audio
}
