import SwiftUI

/// BPM 슬라이더 + 범위 표시 (DESIGN.md 2.1)
struct BPMSliderView: View {
    @Binding var targetBPM: Double
    let playbackRate: Double
    let onDecrease: () -> Void
    let onReset: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("목표 케이던스")
                    .font(.cadenzaBody)
                    .foregroundColor(.cadenzaTextPrimary)
                Spacer()
                Text("\(Int(targetBPM)) SPM")
                    .font(.cadenzaMonoValue)
                    .foregroundColor(.cadenzaAccent)
                    .contentTransition(.numericText())
            }

            Slider(
                value: $targetBPM,
                in: BPMRange.targetMin...BPMRange.targetMax,
                step: 1
            )
            .tint(.cadenzaAccent)

            HStack {
                Text("\(Int(BPMRange.targetMin))")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
                Spacer()
                Text("\(Int(BPMRange.targetMax))")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)
            }

            HStack(spacing: 10) {
                quickControlButton(title: "-1", action: onDecrease)
                quickControlButton(
                    title: "\(Int(BPMRange.targetDefault))",
                    isEmphasized: Int(targetBPM) == Int(BPMRange.targetDefault),
                    action: onReset
                )
                quickControlButton(title: "+1", action: onIncrease)

                Spacer()

                Text("현재 \(String(format: "%.2fx", playbackRate))")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextSecondary)
            }
        }
    }

    private func quickControlButton(
        title: String,
        isEmphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.cadenzaCaption)
                .foregroundColor(isEmphasized ? .cadenzaBackground : .cadenzaTextPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isEmphasized ? Color.cadenzaAccent : Color.cadenzaBackgroundSecondary)
                .clipShape(Capsule())
        }
        .accessibilityLabel(title == "-1" ? "목표 케이던스 1 낮추기" : title == "+1" ? "목표 케이던스 1 높이기" : "목표 케이던스 \(title)로 초기화")
    }
}
