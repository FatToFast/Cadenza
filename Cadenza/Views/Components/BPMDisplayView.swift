import SwiftUI

/// 현재 곡의 케이던스 계획과 원곡 BPM을 한 흐름으로 보여준다.
struct BPMDisplayView: View {
    let tempoPlan: BPMRange.TempoPlan
    let originalBPM: Double
    let originalBPMSource: OriginalBPMSource
    var cadenceFit: RunningCadenceFit? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(roundedText(tempoPlan.effectiveCadence))
                .font(.bpmDisplay)
                .foregroundColor(.cadenzaAccent)
                .contentTransition(.numericText())

            Text("SPM")
                .font(.cadenzaMonoLabel)
                .tracking(2)
                .foregroundColor(.cadenzaTextSecondary)

            Text(cadenceWindowText)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .padding(.top, 4)

            if let meaningfulCadenceFit {
                cadenceFitBadge(meaningfulCadenceFit)
                    .padding(.top, 6)
            }

            Spacer().frame(height: 12)

            HStack(spacing: 8) {
                Text(originalTempoText)
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

            Text(originalBPMSource.helperText)
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text(modeText)
                .font(.cadenzaMonoValue)
                .foregroundColor(tempoPlan.mode == .rejected ? .cadenzaWarning : .cadenzaTextTertiary)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("케이던스 정보")
        .accessibilityValue(accessibilitySummary)
    }

    private var cadenceWindowText: String {
        "기준 \(roundedText(tempoPlan.baseCadence)) · 허용 \(roundedText(tempoPlan.allowedCadence.lowerBound))~\(roundedText(tempoPlan.allowedCadence.upperBound))"
    }

    private var meaningfulCadenceFit: RunningCadenceFit? {
        guard let cadenceFit, cadenceFit.status != .unknown else { return nil }
        return cadenceFit
    }

    private var modeText: String {
        guard originalBPMSource != .assumedDefault else {
            return "원곡 BPM 확인 필요"
        }

        switch tempoPlan.mode {
        case .originalSpeed:
            return "원곡 속도"
        case .adjustedSpeed:
            guard isValidRate(tempoPlan.requiredPlaybackRate) else {
                return "재생속도 확인 불가"
            }
            return "재생속도 \(rateText(tempoPlan.requiredPlaybackRate))배"
        case .rejected:
            return "BPM 확인 필요"
        }
    }

    private var accessibilitySummary: String {
        let baseAndRange = "기준 \(roundedText(tempoPlan.baseCadence)) SPM, 허용 \(roundedText(tempoPlan.allowedCadence.lowerBound))에서 \(roundedText(tempoPlan.allowedCadence.upperBound)) SPM"
        let fit = meaningfulCadenceFit.map { ", 러닝 적합도 \($0.badgeText)" } ?? ""

        guard originalBPMSource != .assumedDefault else {
            return "\(baseAndRange). 원곡 BPM 확인 필요\(fit)"
        }

        let original = "원곡 \(roundedText(originalBPM)) BPM, \(originalBPMSource.badgeText)"
        if tempoPlan.mode == .rejected {
            return "BPM 확인 필요. \(baseAndRange). \(original)\(fit)"
        }
        return "실제 케이던스 \(roundedText(tempoPlan.effectiveCadence)) SPM. \(baseAndRange). \(original). \(modeText)\(fit)"
    }

    private var originalTempoText: String {
        guard originalBPMSource != .assumedDefault else {
            return "원곡 BPM 미확인"
        }
        return "원곡 \(roundedText(originalBPM)) BPM"
    }

    private func roundedText(_ value: Double) -> String {
        guard value.isFinite,
              let roundedValue = Int(exactly: value.rounded()) else {
            return "확인 불가"
        }
        return String(roundedValue)
    }

    private func isValidRate(_ rate: Double) -> Bool {
        rate.isFinite && rate > 0
    }

    private func rateText(_ rate: Double) -> String {
        guard isValidRate(rate) else { return "확인 불가" }
        return String(format: "%.2f", rate)
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
        case .awkward, .unsuitable:
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
