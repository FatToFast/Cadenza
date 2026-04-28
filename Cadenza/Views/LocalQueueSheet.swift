import SwiftUI

/// 로컬 파일 플레이리스트 곡 목록 시트.
/// 매번 file picker로 다시 import할 필요 없이 큐 안에서 직접 곡을 선택한다.
struct LocalQueueSheet: View {
    @EnvironmentObject private var audio: AudioManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if audio.localPlaylist.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .background(Color.cadenzaBackground.ignoresSafeArea())
            .navigationTitle("재생 목록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundColor(.cadenzaAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var queueList: some View {
        List {
            ForEach(Array(audio.localPlaylist.items.enumerated()), id: \.element.id) { index, item in
                QueueRow(
                    title: item.title,
                    artist: item.artist,
                    isCurrent: audio.localPlaylist.currentIndex == index,
                    onTap: {
                        Task {
                            await audio.jumpToLocalTrack(at: index)
                            dismiss()
                        }
                    }
                )
                .listRowBackground(Color.cadenzaBackground)
                .listRowSeparatorTint(.cadenzaDivider)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundColor(.cadenzaTextTertiary)
            Text("재생 목록이 비어 있습니다")
                .font(.cadenzaBody)
                .foregroundColor(.cadenzaTextSecondary)
            Text("MP3 플레이리스트 또는 파일 선택으로 곡을 불러오세요.")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QueueRow: View {
    let title: String
    let artist: String?
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 16))
                    .foregroundColor(isCurrent ? .cadenzaAccent : .cadenzaTextTertiary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cadenzaBody)
                        .foregroundColor(isCurrent ? .cadenzaAccent : .cadenzaTextPrimary)
                        .lineLimit(1)
                    if let artist {
                        Text(artist)
                            .font(.cadenzaCaption)
                            .foregroundColor(.cadenzaTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "현재 곡: \(title)" : title)
    }
}
