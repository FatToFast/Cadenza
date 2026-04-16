import SwiftUI

/// BPM 슬라이더 + 범위 표시 (DESIGN.md 2.1)
struct BPMSliderView: View {
    @Binding var targetBPM: Double

    var body: some View {
        VStack(spacing: 8) {
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
        }
    }
}
