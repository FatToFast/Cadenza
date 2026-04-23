import MediaPlayer
import SwiftUI

@MainActor
struct AppleMusicLibraryView: View {
    let library: any MusicLibrary
    let onTrackPicked: (AppleMusicTrack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus: MPMediaLibraryAuthorizationStatus
    @State private var playlists: [PlaylistSummary] = []
    @State private var tracksByPlaylist: [UInt64: [AppleMusicTrack]] = [:]
    @State private var resolvedBPMByTrackID: [String: Int] = [:]
    @State private var bpmLookupAttemptedTrackIDs: Set<String> = []
    @State private var loadingMessage: String?
    @State private var errorMessage: String?

    init(
        library: any MusicLibrary = MusicLibraryService(),
        onTrackPicked: @escaping (AppleMusicTrack) -> Void
    ) {
        self.library = library
        self.onTrackPicked = onTrackPicked
        _authorizationStatus = State(initialValue: library.authorizationStatus())
    }

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    playlistList
                case .notDetermined:
                    permissionPrompt
                case .denied, .restricted:
                    deniedView
                @unknown default:
                    deniedView
                }
            }
            .navigationTitle("Apple Music 보관함")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .task {
            await refreshAuthorizationAndLoad()
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundColor(.cadenzaAccent)

            Text("Apple Music 보관함 접근 권한이 필요합니다")
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaTextPrimary)
                .multilineTextAlignment(.center)

            Button("권한 허용") {
                Task { await requestAuthorizationAndLoad() }
            }
            .font(.cadenzaBody)
            .foregroundColor(.cadenzaBackground)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.cadenzaAccent)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.cadenzaBackground.ignoresSafeArea())
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundColor(.cadenzaWarning)

            Text("Apple Music 보관함에 접근할 수 없습니다")
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaTextPrimary)
                .multilineTextAlignment(.center)

            Text("설정에서 미디어 및 Apple Music 권한을 허용한 뒤 다시 시도하세요.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)

            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.cadenzaBody)
            .foregroundColor(.cadenzaWarning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.cadenzaBackground.ignoresSafeArea())
    }

    private var playlistList: some View {
        List {
            if let loadingMessage {
                HStack {
                    ProgressView()
                    Text(loadingMessage)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.cadenzaWarning)
            }

            ForEach(playlists) { playlist in
                NavigationLink {
                    trackList(for: playlist)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .font(.body)
                        Text("\(playlist.trackCount)곡")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay {
            if playlists.isEmpty && loadingMessage == nil && errorMessage == nil {
                ContentUnavailableView(
                    "플레이리스트 없음",
                    systemImage: "music.note.list",
                    description: Text("보관함 플레이리스트가 없습니다.")
                )
            }
        }
        .refreshable {
            await loadPlaylists()
        }
    }

    private func trackList(for playlist: PlaylistSummary) -> some View {
        List {
            if tracksByPlaylist[playlist.id] == nil {
                HStack {
                    ProgressView()
                    Text("곡 불러오는 중")
                }
            }

            ForEach(tracksByPlaylist[playlist.id] ?? []) { track in
                Button {
                    guard track.canLoadAudio else { return }
                    onTrackPicked(track)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .foregroundColor(.primary)
                            if let artist = track.artist {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let reason = track.unavailableReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                        if let bpm = displayBPM(for: track) {
                            Text("\(bpm) BPM")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if !bpmLookupAttemptedTrackIDs.contains(track.id) {
                            Text("BPM 조회 중")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("BPM 미확인")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(!track.canLoadAudio)
            }
        }
        .navigationTitle(playlist.name)
        .task {
            await loadTracksIfNeeded(for: playlist)
        }
    }

    private func refreshAuthorizationAndLoad() async {
        authorizationStatus = library.authorizationStatus()
        if authorizationStatus == .authorized {
            await loadPlaylists()
        }
    }

    private func requestAuthorizationAndLoad() async {
        authorizationStatus = await library.requestAuthorization()
        if authorizationStatus == .authorized {
            await loadPlaylists()
        }
    }

    private func loadPlaylists() async {
        loadingMessage = "플레이리스트 불러오는 중"
        errorMessage = nil
        do {
            playlists = try await library.fetchPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
        loadingMessage = nil
    }

    private func loadTracksIfNeeded(for playlist: PlaylistSummary) async {
        guard tracksByPlaylist[playlist.id] == nil else { return }
        do {
            let tracks = try await library.fetchTracks(in: playlist.id)
            tracksByPlaylist[playlist.id] = tracks
            preloadMissingBPMs(for: tracks)
        } catch {
            tracksByPlaylist[playlist.id] = []
            errorMessage = error.localizedDescription
        }
    }

    private func displayBPM(for track: AppleMusicTrack) -> Int? {
        track.beatsPerMinute ?? resolvedBPMByTrackID[track.id]
    }

    private func preloadMissingBPMs(for tracks: [AppleMusicTrack]) {
        let pendingTracks = tracks.filter { track in
            track.beatsPerMinute == nil &&
                resolvedBPMByTrackID[track.id] == nil &&
                !bpmLookupAttemptedTrackIDs.contains(track.id)
        }
        guard !pendingTracks.isEmpty else { return }

        Task(priority: .utility) {
            for track in pendingTracks {
                let result = await GetSongBPMService.shared.lookupBPM(
                    title: track.title,
                    artist: track.artist,
                    appleMusicID: track.appleMusicID
                )

                await MainActor.run {
                    if let result {
                        resolvedBPMByTrackID[track.id] = Int(result.bpm.rounded())
                    }
                    bpmLookupAttemptedTrackIDs.insert(track.id)
                }
            }
        }
    }
}
