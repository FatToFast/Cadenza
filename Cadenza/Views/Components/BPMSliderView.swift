import SwiftUI

/// 기준 케이던스 슬라이더와 빠른 조절 버튼.
struct BPMSliderView: View {
    @Binding var targetBPM: Double
    let onDecrease: () -> Void
    let onReset: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: $targetBPM,
                in: BPMRange.targetMin...BPMRange.targetMax,
                step: 1
            )
            .tint(.cadenzaAccent)
            .accessibilityLabel("기준 케이던스")
            .accessibilityValue("\(Int(targetBPM.rounded())) SPM")
            .accessibilityHint("위아래로 쓸어 1 SPM씩 조절합니다")

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
                quickControlButton(
                    title: "-5",
                    accessibilityLabel: "기준 케이던스 5 낮추기",
                    accessibilityHint: "최저 140 SPM까지 낮춥니다",
                    action: onDecrease
                )
                quickControlButton(
                    title: "↺ \(Int(BPMRange.targetDefault))",
                    accessibilityLabel: "기준 케이던스 기본값 복원",
                    accessibilityHint: "기준 케이던스를 180 SPM으로 되돌립니다",
                    isEmphasized: Int(targetBPM) == Int(BPMRange.targetDefault),
                    action: onReset
                )
                quickControlButton(
                    title: "+5",
                    accessibilityLabel: "기준 케이던스 5 높이기",
                    accessibilityHint: "최대 200 SPM까지 높입니다",
                    action: onIncrease
                )

                Spacer()
            }
        }
    }

    private func quickControlButton(
        title: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        isEmphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.cadenzaCaption)
                .foregroundColor(isEmphasized ? .cadenzaBackground : .cadenzaTextPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(isEmphasized ? Color.cadenzaAccent : Color.cadenzaBackgroundSecondary)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}
