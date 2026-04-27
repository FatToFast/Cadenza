import SwiftUI

/// 큰 BPM 숫자 표시 영역 (DESIGN.md 2.1: 화면 중앙 30%)
/// 목표 BPM, 원곡 BPM, 재생속도 비율을 보여준다.
struct BPMDisplayView: View {
    let targetBPM: Double
    let originalBPM: Double
    let playbackRate: Double
    let originalBPMSource: OriginalBPMSource
    var cadenceFit: RunningCadenceFit? = nil

    var body: some View {
        VStack(spacing: 4) {
            // 목표 BPM (가장 큰 숫자)
            Text("\(Int(targetBPM))")
                .font(.bpmDisplay)
                .foregroundColor(.cadenzaAccent)
                .contentTransition(.numericText())

            Text("spm")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)

            if let cadenceFit, cadenceFit.status != .unknown {
                cadenceFitBadge(cadenceFit)
                    .padding(.top, 6)
            }

            Spacer().frame(height: 12)

            // 원곡 BPM → 목표 BPM + 비율
            HStack(spacing: 8) {
                Text("원곡 \(Int(originalBPM))")
                    .font(.cadenzaNumeric)
                    .foregroundColor(.cadenzaTextTertiary)

                Text(originalBPMSource.badgeText)
                    .font(.cadenzaCaption)
                    .foregroundColor(sourceColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(sourceColor.opacity(0.12))
                    .clipShape(Capsule())

                Image(systemName: "arrow.right")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)

                Text("\(Int(targetBPM))")
                    .font(.cadenzaNumeric)
                    .foregroundColor(.cadenzaTextSecondary)
            }

            Text(originalBPMSource.helperText)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text("재생속도 \(String(format: "%.2fx", playbackRate))")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
        }
    }

    private func cadenceFitBadge(_ fit: RunningCadenceFit) -> some View {
        let color = fitColor(for: fit)
        return Text(fit.badgeText)
            .font(.cadenzaCaption)
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
            .accessibilityLabel("러닝 적합도: \(fit.badgeText)")
    }

    private func fitColor(for fit: RunningCadenceFit) -> Color {
        if fit.riskReason != nil {
            return .cadenzaWarning
        }
        switch fit.status {
        case .excellent:
            return .cadenzaAccent
        case .usable:
            return Color.cadenzaAccent.opacity(0.8)
        case .awkward:
            return .cadenzaWarning
        case .unsuitable:
            return .cadenzaWarning
        case .unknown:
            return .cadenzaTextTertiary
        }
    }

    private var sourceColor: Color {
        switch originalBPMSource {
        case .metadata:
            return .cadenzaAccent
        case .analysis:
            return Color.cadenzaAccent.opacity(0.84)
        case .assumedDefault:
            return .cadenzaWarning
        case .preset:
            return Color.cadenzaAccent.opacity(0.72)
        case .manual:
            return .cadenzaTextSecondary
        }
    }
}
