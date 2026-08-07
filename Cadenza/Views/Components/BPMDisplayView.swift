import SwiftUI

/// 큰 BPM 숫자 표시 영역 (DESIGN.md 2.1: 화면 중앙 30%)
/// 목표 케이던스, 원곡 BPM, 재생속도 비율을 보여준다.
struct BPMDisplayView: View {
    let targetBPM: Double
    let originalBPM: Double
    let playbackRate: Double
    let originalBPMSource: OriginalBPMSource
    /// 드리프트가 반영된 실제 케이던스. 미지정 시 targetBPM(사용자 설정)을 그대로 쓴다.
    var effectiveCadence: Double? = nil
    var cadenceFit: RunningCadenceFit? = nil

    /// 대형 숫자로 표시할 케이던스. 드리프트가 있으면 effectiveCadence, 없으면 targetBPM.
    private var displayCadence: Double { effectiveCadence ?? targetBPM }

    /// 드리프트로 실제 케이던스가 사용자 설정과 달라졌는지.
    private var isDrifted: Bool {
        guard let effectiveCadence else { return false }
        return abs(effectiveCadence - targetBPM) > 0.5
    }

    private var originalCadenceEquivalent: Double? {
        BPMRange.runningCadenceEquivalent(
            forSongBPM: originalBPM,
            near: targetBPM
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            // 실제 케이던스 (가장 큰 숫자)
            Text("\(Int(displayCadence))")
                .font(.bpmDisplay)
                .foregroundColor(.cadenzaAccent)
                .contentTransition(.numericText())

            Text("SPM")
                .font(.cadenzaMonoLabel)
                .tracking(2)
                .foregroundColor(.cadenzaTextSecondary)

            if isDrifted {
                Text("설정 \(Int(targetBPM))")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
                    .padding(.top, 2)
            }

            if let cadenceFit, cadenceFit.status != .unknown {
                cadenceFitBadge(cadenceFit)
                    .padding(.top, 6)
            }

            Spacer().frame(height: 12)

            // 원곡 BPM과 러닝 케이던스를 서로 다른 단위로 명확히 표시한다.
            HStack(spacing: 8) {
                Text("원곡 \(Int(originalBPM)) BPM")
                    .font(.cadenzaMonoValue)
                    .foregroundColor(.cadenzaTextTertiary)

                Text(originalBPMSource.badgeText)
                    .font(.cadenzaMonoPill)
                    .tracking(1.2)
                    .foregroundColor(sourceColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(sourceColor.opacity(0.12))
                    .clipShape(Capsule())

            }

            if let originalCadenceEquivalent,
               abs(originalCadenceEquivalent - originalBPM) > 0.5 {
                HStack(spacing: 8) {
                    Text("러닝 환산 \(Int(originalCadenceEquivalent)) SPM")
                        .font(.cadenzaMonoValue)
                        .foregroundColor(.cadenzaTextSecondary)
                }
            }

            HStack(spacing: 8) {
                Text("목표 \(Int(targetBPM)) SPM")
                    .font(.cadenzaMonoValue)
                    .foregroundColor(.cadenzaTextSecondary)
            }

            Text(originalBPMSource.helperText)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text("재생속도 ×\(String(format: "%.2f", playbackRate))")
                .font(.cadenzaMonoValue)
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
