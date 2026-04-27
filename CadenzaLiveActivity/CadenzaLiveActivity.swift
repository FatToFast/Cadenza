import ActivityKit
import SwiftUI
import WidgetKit

struct CadenzaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CadenzaActivityAttributes.self) { context in
            // Lock Screen / banner UI
            LiveActivityExpandedView(state: context.state)
                .padding(16)
                .background(
                    BeatBreathingHalo(bpm: context.state.bpm, isActive: context.state.isPlaying)
                )
                .activityBackgroundTint(Color(hex: 0x15151C).opacity(0.92))
                .activitySystemActionForegroundColor(.cadenzaTextPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    artwork(state: context.state, size: 56)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    bpmReadout(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    titleStack(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progressLine(state: context.state)
                }
            } compactLeading: {
                artwork(state: context.state, size: 22)
            } compactTrailing: {
                Text("\(context.state.bpm)")
                    .font(.cadenzaMonoPill)
                    .foregroundColor(.cadenzaAccent)
            } minimal: {
                artwork(state: context.state, size: 18)
            }
        }
    }

    @ViewBuilder
    private func artwork(state: CadenzaActivityState, size: CGFloat) -> some View {
        if let data = state.artworkData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(Color(hex: 0x2A2A35))
                Image(systemName: "music.note")
                    .foregroundColor(Color(hex: 0x5A5A65))
                    .font(.system(size: size * 0.5))
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func bpmReadout(state: CadenzaActivityState) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(state.bpm)")
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundColor(.cadenzaTextPrimary)
            Text("SPM")
                .font(.cadenzaMonoLabel)
                .tracking(1.5)
                .foregroundColor(.cadenzaTextSecondary)
        }
    }

    @ViewBuilder
    private func titleStack(state: CadenzaActivityState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.cadenzaTextPrimary)
                .lineLimit(1)
            if let artist = state.artist {
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundColor(.cadenzaTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func progressLine(state: CadenzaActivityState) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: progressFraction(state: state))
                .tint(.cadenzaAccent)
            HStack {
                Text(formatted(state.elapsed))
                Spacer()
                Text(formatted(state.duration))
            }
            .font(.cadenzaMonoTimecode)
            .foregroundColor(.cadenzaTextTertiary)
        }
    }

    private func progressFraction(state: CadenzaActivityState) -> Double {
        guard state.duration > 0 else { return 0 }
        return min(max(state.elapsed / state.duration, 0), 1)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LiveActivityExpandedView: View {
    let state: CadenzaActivityState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.cadenzaTextPrimary)
                            .lineLimit(1)
                        if let artist = state.artist {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundColor(.cadenzaTextSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(state.bpm)")
                            .font(.system(size: 24, weight: .medium, design: .monospaced))
                            .foregroundColor(.cadenzaTextPrimary)
                        Text("SPM")
                            .font(.cadenzaMonoLabel)
                            .tracking(1.5)
                            .foregroundColor(.cadenzaTextSecondary)
                    }
                }

                ProgressView(value: progressFraction)
                    .tint(.cadenzaAccent)

                HStack {
                    Text(formatted(state.elapsed))
                    Spacer()
                    Text("TGT \(state.targetBPM)")
                    Spacer()
                    Text(formatted(state.duration))
                }
                .font(.cadenzaMonoTimecode)
                .foregroundColor(.cadenzaTextTertiary)
            }
        }
    }

    private var artwork: some View {
        Group {
            if let data = state.artworkData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: 0x2A2A35)
                    Image(systemName: "music.note")
                        .foregroundColor(Color(hex: 0x5A5A65))
                        .font(.system(size: 22))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var progressFraction: Double {
        guard state.duration > 0 else { return 0 }
        return min(max(state.elapsed / state.duration, 0), 1)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 카드 외곽에 BPM에 맞춰 시안 글로우가 펄싱하는 호흡 레이어.
/// 정지 시 0으로 고정. Reduce Motion이면 정적 약한 글로우만.
private struct BeatBreathingHalo: View {
    let bpm: Int
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let beatInterval = bpm > 0 ? 60.0 / Double(bpm) : 1.0
        return Group {
            if !isActive {
                Color.clear
            } else if reduceMotion {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.cadenzaAccent.opacity(0.05), lineWidth: 4)
                    .blur(radius: 6)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let phase = elapsed.truncatingRemainder(dividingBy: beatInterval) / beatInterval
                    let opacity = max(0, 0.08 * sin(.pi * phase))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.cadenzaAccent.opacity(opacity), lineWidth: 4)
                        .blur(radius: 6)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
