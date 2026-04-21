import MusicKit
import SwiftUI

@MainActor
struct AppleMusicStreamingPlaylistView: View {
    let onEntryPicked: (Playlist, Playlist.Entry, [Playlist.Entry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var playlists: [Playlist] = []
    @State private var entriesByPlaylist: [MusicItemID: [Playlist.Entry]] = [:]
    @State private var cadenceFitsByEntryID: [MusicItemID: RunningCadenceFit] = [:]
    @State private var hiddenEntryIDs: Set<MusicItemID> = []
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

            let visibleEntries = (entriesByPlaylist[playlist.id] ?? []).filter { !hiddenEntryIDs.contains($0.id) }
            ForEach(visibleEntries, id: \.id) { entry in
                Button {
                    onEntryPicked(playlist, entry, entriesByPlaylist[playlist.id] ?? [])
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
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

                        Spacer(minLength: 8)

                        cadenceFitBadge(for: entry)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        hiddenEntryIDs.insert(entry.id)
                    } label: {
                        Label("숨기기", systemImage: "eye.slash")
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
            analyzeRunningCadenceFit(for: entries)
        } catch {
            entriesByPlaylist[playlist.id] = []
            errorMessage = "곡 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func cadenceFitBadge(for entry: Playlist.Entry) -> some View {
        if let fit = cadenceFitsByEntryID[entry.id] {
            VStack(alignment: .trailing, spacing: 3) {
                Text(fit.badgeText)
                    .font(.cadenzaCaption)
                    .foregroundColor(color(for: fit.status))
                    .lineLimit(1)

                Text(fit.detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 82, alignment: .trailing)
        } else {
            Text("분석 중")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 82, alignment: .trailing)
        }
    }

    private func analyzeRunningCadenceFit(for entries: [Playlist.Entry]) {
        let pendingEntries = entries.filter { cadenceFitsByEntryID[$0.id] == nil }
        guard !pendingEntries.isEmpty else { return }

        Task(priority: .utility) {
            for entry in pendingEntries {
                let bpm = await GetSongBPMService.shared.lookupBPM(
                    title: entry.title,
                    artist: entry.artistName
                )?.bpm
                let previewSignal = await previewSignal(for: entry)
                let fit = RunningCadenceFit.evaluate(
                    originalBPM: bpm,
                    previewSignal: previewSignal
                )
                await MainActor.run {
                    cadenceFitsByEntryID[entry.id] = fit
                }
            }
        }
    }

    private func previewSignal(for entry: Playlist.Entry) async -> RunningPreviewSignal? {
        guard let previewAsset = entry.previewAssets?.first(where: { $0.url != nil || $0.hlsURL != nil }) else {
            return nil
        }
        guard let analysis = await PreviewBPMAnalyzer.shared.estimateBeatAlignment(
            directURL: previewAsset.url,
            hlsURL: previewAsset.hlsURL,
            title: entry.title,
            artist: entry.artistName
        ) else {
            return nil
        }

        return RunningPreviewSignal(
            confidence: analysis.confidence,
            beatTimesSeconds: analysis.beatTimesSeconds ?? []
        )
    }

    private func color(for status: RunningCadenceFitStatus) -> Color {
        switch status {
        case .excellent:
            return .cadenzaAccent
        case .usable:
            return .cadenzaTextSecondary
        case .awkward:
            return .cadenzaWarning
        case .unsuitable:
            return .cadenzaWarning
        case .unknown:
            return .cadenzaTextTertiary
        }
    }
}
