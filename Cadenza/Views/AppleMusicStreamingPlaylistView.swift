import MusicKit
import SwiftUI

@MainActor
struct AppleMusicStreamingPlaylistView: View {
    let onEntryPicked: (Playlist, Playlist.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var playlists: [Playlist] = []
    @State private var entriesByPlaylist: [MusicItemID: [Playlist.Entry]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if authorizationStatus == .authorized {
                    playlistList
                } else {
                    permissionContent
                }
            }
            .navigationTitle("Apple Music 플레이리스트")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if authorizationStatus == .authorized {
                await loadPlaylists()
            }
        }
    }

    private var permissionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundColor(.cadenzaAccent)

            Text("Apple Music 권한이 필요합니다")
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaTextPrimary)
                .multilineTextAlignment(.center)

            Text("플레이리스트는 Apple Music 플레이어로 스트리밍 재생되며, 피치락은 적용되지 않을 수 있습니다.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)

            Button("권한 허용") {
                Task {
                    authorizationStatus = await MusicAuthorization.request()
                    if authorizationStatus == .authorized {
                        await loadPlaylists()
                    }
                }
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

    private var playlistList: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("플레이리스트 불러오는 중")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.orange)
            }

            ForEach(playlists, id: \.id) { playlist in
                NavigationLink {
                    entryList(for: playlist)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .foregroundColor(.primary)
                        if let curatorName = playlist.curatorName {
                            Text(curatorName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if playlists.isEmpty && !isLoading && errorMessage == nil {
                ContentUnavailableView(
                    "플레이리스트 없음",
                    systemImage: "music.note.list",
                    description: Text("Apple Music 보관함의 플레이리스트를 찾지 못했습니다.")
                )
            }
        }
        .refreshable {
            await loadPlaylists()
        }
    }

    private func entryList(for playlist: Playlist) -> some View {
        List {
            if entriesByPlaylist[playlist.id] == nil {
                HStack {
                    ProgressView()
                    Text("곡 불러오는 중")
                }
            }

            ForEach(entriesByPlaylist[playlist.id] ?? [], id: \.id) { entry in
                Button {
                    onEntryPicked(playlist, entry)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .foregroundColor(.primary)
                        Text(entry.artistName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let albumTitle = entry.albumTitle {
                            Text(albumTitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .task {
            await loadEntriesIfNeeded(for: playlist)
        }
    }

    private func loadPlaylists() async {
        isLoading = true
        errorMessage = nil
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 100
            request.includeOnlyDownloadedContent = false
            let response = try await request.response()
            playlists = Array(response.items)
        } catch {
            errorMessage = "플레이리스트를 불러오지 못했습니다: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadEntriesIfNeeded(for playlist: Playlist) async {
        guard entriesByPlaylist[playlist.id] == nil else { return }
        do {
            let detailedPlaylist = try await playlist.with(.entries)
            let entries = Array(detailedPlaylist.entries ?? [])
            entriesByPlaylist[playlist.id] = entries
            prefetchGetSongBPM(for: entries)
        } catch {
            entriesByPlaylist[playlist.id] = []
            errorMessage = "곡 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func prefetchGetSongBPM(for entries: [Playlist.Entry]) {
        let lookups = entries.map {
            GetSongBPMService.TrackLookup(title: $0.title, artist: $0.artistName)
        }
        guard !lookups.isEmpty else { return }

        Task(priority: .utility) {
            await GetSongBPMService.shared.prefetchBPMs(lookups)
        }
    }
}
