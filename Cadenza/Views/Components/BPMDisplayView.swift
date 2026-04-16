import SwiftUI

/// 큰 BPM 숫자 표시 영역 (DESIGN.md 2.1: 화면 중앙 30%)
/// 목표 BPM, 원곡 BPM, 재생속도 비율을 보여준다.
struct BPMDisplayView: View {
    let targetBPM: Double
    let originalBPM: Double
    let playbackRate: Double
    let hasBPMFromMetadata: Bool

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

            Spacer().frame(height: 12)

            // 원곡 BPM → 목표 BPM + 비율
            HStack(spacing: 6) {
                Text("원곡 \(Int(originalBPM))")
                    .font(.cadenzaNumeric)
                    .foregroundColor(.cadenzaTextTertiary)

                if hasBPMFromMetadata {
                    Text("(자동)")
                        .font(.cadenzaCaption)
                        .foregroundColor(.cadenzaTextTertiary)
                }

                Image(systemName: "arrow.right")
                    .font(.cadenzaCaption)
                    .foregroundColor(.cadenzaTextTertiary)

                Text("\(Int(targetBPM))")
                    .font(.cadenzaNumeric)
                    .foregroundColor(.cadenzaTextSecondary)
            }

            Text("재생속도 \(String(format: "%.2fx", playbackRate))")
                .font(.cadenzaCaption)
                .foregroundColor(.cadenzaTextTertiary)
        }
    }
}
