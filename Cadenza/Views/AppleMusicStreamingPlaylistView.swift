import MusicKit
import SwiftUI

@MainActor
struct AppleMusicStreamingPlaylistView: View {
    let onEntryPicked: (Playlist, Playlist.Entry, [Playlist.Entry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var playlists: [Playlist] = []
    @State private var entriesByPlaylist: [MusicItemID: [Playlist.Entry]] = [:]
    @State private var bpmByEntryID: [String: Int] = [:]
    @State private var cadenceFitsByEntryID: [String: RunningCadenceFit] = [:]
    @State private var bpmLookupAttemptedEntryIDs: Set<String> = []
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

                        bpmBadge(for: entry)
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
            preloadBPMs(for: entries)
        } catch {
            entriesByPlaylist[playlist.id] = []
            errorMessage = "곡 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func bpmBadge(for entry: Playlist.Entry) -> some View {
        let entryID = entry.id.rawValue
        VStack(alignment: .trailing, spacing: 3) {
            if let bpm = bpmByEntryID[entryID] {
                Text("\(bpm) BPM")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaAccent)
                    .lineLimit(1)
            } else if bpmLookupAttemptedEntryIDs.contains(entryID) {
                Text("BPM 미확인")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("BPM 조회 중")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let fit = cadenceFitsByEntryID[entryID], fit.originalBPM != nil {
                Text(fit.detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 86, alignment: .trailing)
    }

    private func preloadBPMs(for entries: [Playlist.Entry]) {
        let lookups = entries
            .map(bpmLookup(for:))
            .filter { lookup in
                bpmByEntryID[lookup.entryID] == nil &&
                    !bpmLookupAttemptedEntryIDs.contains(lookup.entryID)
            }
        guard !lookups.isEmpty else { return }

        Task(priority: .utility) {
            var uncachedLookups: [PlaylistEntryBPMLookup] = []

            for lookup in lookups {
                if let cached = await GetSongBPMService.shared.cachedBPM(
                    title: lookup.title,
                    artist: lookup.artist,
                    appleMusicID: lookup.appleMusicID,
                    isrc: lookup.isrc
                ) {
                    await MainActor.run {
                        applyBPM(cached.bpm, for: lookup)
                        bpmLookupAttemptedEntryIDs.insert(lookup.entryID)
                    }
                } else {
                    uncachedLookups.append(lookup)
                }
            }

            guard !uncachedLookups.isEmpty else { return }

            await withTaskGroup(of: (PlaylistEntryBPMLookup, Double?).self) { group in
                var nextIndex = 0
                let requestLimit = min(4, uncachedLookups.count)

                func enqueueNext() {
                    guard nextIndex < uncachedLookups.count else { return }
                    let lookup = uncachedLookups[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let bpm = await GetSongBPMService.shared.lookupBPM(
                            title: lookup.title,
                            artist: lookup.artist,
                            appleMusicID: lookup.appleMusicID,
                            isrc: lookup.isrc
                        )?.bpm
                        return (lookup, bpm)
                    }
                }

                for _ in 0..<requestLimit {
                    enqueueNext()
                }

                while let (lookup, bpm) = await group.next() {
                    await MainActor.run {
                        if let bpm {
                            applyBPM(bpm, for: lookup)
                        }
                        bpmLookupAttemptedEntryIDs.insert(lookup.entryID)
                    }
                    enqueueNext()
                }
            }
        }
    }

    private func applyBPM(_ bpm: Double, for lookup: PlaylistEntryBPMLookup) {
        bpmByEntryID[lookup.entryID] = Int(bpm.rounded())
        cadenceFitsByEntryID[lookup.entryID] = RunningCadenceFit.evaluate(originalBPM: bpm)
    }

    private func bpmLookup(for entry: Playlist.Entry) -> PlaylistEntryBPMLookup {
        if case .song(let song)? = entry.item {
            return PlaylistEntryBPMLookup(
                entryID: entry.id.rawValue,
                appleMusicID: song.id.rawValue,
                isrc: song.isrc,
                title: song.title,
                artist: song.artistName
            )
        }

        return PlaylistEntryBPMLookup(
            entryID: entry.id.rawValue,
            appleMusicID: entry.id.rawValue,
            isrc: entry.isrc,
            title: entry.title,
            artist: entry.artistName
        )
    }

}

private struct PlaylistEntryBPMLookup: Sendable, Hashable {
    let entryID: String
    let appleMusicID: String?
    let isrc: String?
    let title: String
    let artist: String?
}
