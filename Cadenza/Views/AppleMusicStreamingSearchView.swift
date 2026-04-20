import MusicKit
import SwiftUI

@MainActor
struct AppleMusicStreamingSearchView: View {
    let onSongPicked: (Song) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var authorizationStatus = MusicAuthorization.currentStatus

    var body: some View {
        NavigationStack {
            Group {
                if authorizationStatus == .authorized {
                    searchContent
                } else {
                    permissionContent
                }
            }
            .navigationTitle("Apple Music 스트리밍")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var permissionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundColor(.cadenzaAccent)

            Text("Apple Music 스트리밍 권한이 필요합니다")
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaTextPrimary)
                .multilineTextAlignment(.center)

            Text("카탈로그 곡은 Apple Music 플레이어로 재생되며, 피치락은 적용되지 않을 수 있습니다.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)

            Button("권한 허용") {
                Task {
                    authorizationStatus = await MusicAuthorization.request()
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

    private var searchContent: some View {
        List {
            Section {
                HStack {
                    TextField("아티스트, 곡명, 앨범 검색", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { search() }

                    Button {
                        search()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
            }

            if isSearching {
                HStack {
                    ProgressView()
                    Text("검색 중")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.orange)
            }

            Section {
                ForEach(songs, id: \.id) { song in
                    Button {
                        onSongPicked(song)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title)
                                .foregroundColor(.primary)
                            Text(song.artistName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let albumTitle = song.albumTitle {
                                Text(albumTitle)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        Task {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
                request.limit = 25
                let response = try await request.response()
                songs = Array(response.songs)
            } catch {
                errorMessage = "검색에 실패했습니다: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }
}
